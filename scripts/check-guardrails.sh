#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/fingerprint.sh"
source "$script_dir/lib/guardrails.sh"

usage() {
  echo "Usage: $0 [<base-branch>] [--fail-on-protected]"
  echo "       $0 --commits <base-commit> <head-commit> [--fail-on-protected]"
  echo
  echo "Reports which changes of a feature need the owner's approval before a merge:"
  echo "changes to ADRs, to the files of the workflow and its gate, and to the paths"
  echo "that .agents/policies/guardrails.conf lists. The rules are read from the base"
  echo "branch as it is now, not from the feature."
  echo
  echo "Without --commits it checks the current worktree against the point where it"
  echo "left its base branch (default: main), with uncommitted and untracked files."
  echo "With --commits it compares two commits, as CI does for a pull request."
  echo
  echo "An approval request that the diff adds or changes (.agents/approval-requests/"
  echo "<issue>.json, written by finish-feature.sh) is checked independently: its"
  echo "content tree is recomputed from the commit, with the exclusion list of"
  echo "scripts/lib/fingerprint.sh of the base, and printed as 'content tree:'. A"
  echo "request whose content_tree differs, that has a field its schema does not"
  echo "name, or that is not named <issue>.json is refused: 'refused: <path>'. The"
  echo "request changes nothing else here: it is read for this refusal only."
  echo
  echo "The first line of the output is 'level: none', 'level: sensitive', or"
  echo "'level: protected'. It exits 0, or 3 with --fail-on-protected when the level"
  echo "is protected, or 4 when an approval request is refused."
  exit 2
}

fail() {
  echo "Error: $*" >&2
  exit 2
}

fail_on_protected=0
arguments=()
for argument in "$@"; do
  case "$argument" in
    --fail-on-protected) fail_on_protected=1 ;;
    *) arguments+=("$argument") ;;
  esac
done
set -- ${arguments[@]+"${arguments[@]}"}

root="$(git rev-parse --show-toplevel)"
if [[ "${1:-}" == "--commits" ]]; then
  [[ $# -eq 3 ]] || usage
  git -C "$root" rev-parse --verify --quiet "$2^{commit}" >/dev/null || fail "unknown commit: $2"
  git -C "$root" rev-parse --verify --quiet "$3^{commit}" >/dev/null || fail "unknown commit: $3"
  from="$(git -C "$root" merge-base "$2" "$3")" || fail "the commits $2 and $3 share no history."
  to="$3"
  rules="$2"
  excludes_ref="$2"
  # The content a request names is the finish commit: the head, or the commit
  # before the merges of the base that brought the feature up to date.
  checked_commit="$(guardrails_finish_commit "$root" "$3" "$2")"
else
  [[ $# -le 1 ]] || usage
  [[ "${1:-}" != --* ]] || usage
  lines="$(feature_base "$root" "${1:-main}")" || fail "could not determine the base of this worktree: ${1:-main}"
  from="$(printf '%s\n' "$lines" | sed -n 2p)"
  to=""
  rules="$(guardrails_rules_refs "$root" "${1:-main}")"
  excludes_ref="$(printf '%s\n' "$lines" | sed -n 1p)"
  checked_commit=""
fi

# The rules of the base as it is now; the diff from where the feature left it.
findings="$(guardrails_classify "$root" "$rules" "$from" "$to")"
level="$(printf '%s\n' "$findings" | guardrails_level)"
echo "level: $level"
if [[ -n "$findings" ]]; then
  printf '%s\n' "$findings" | sort -u | awk -F '\t' '{ printf "%s: %s (%s)\n", $1, $2, $3 }'
fi
case "$level" in
  protected) echo "The owner's approval is needed before this is merged." ;;
  sensitive) echo "No approval is needed for these paths; the independent review looks at them." ;;
esac

# The approval requests the diff adds or changes. Each must be named
# <issue>.json, follow its schema, and name the content tree of the content
# it is checked with: recomputed here, with the exclusion list of the base,
# so that a feature cannot exclude a path for itself. Nothing in a request
# changes the level above or anything else: a request can only be refused.
refused=0
requests=()
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  requests+=("$path")
done < <(guardrails_requests_changed "$root" "$from" "$to")
if [[ "${#requests[@]}" -gt 0 ]]; then
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/check-guardrails.XXXXXX")"
  trap 'rm -rf "$scratch"' EXIT
  excludes=()
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    excludes+=("$path")
  done < <(fingerprint_excludes_at "$root" "$excludes_ref")
  [[ "${#excludes[@]}" -gt 0 ]] || fail "could not read the exclusion list of scripts/lib/fingerprint.sh from $excludes_ref."
  # The schema of the base too; before the base has one, the working tree's.
  if git -C "$root" show "$excludes_ref:$GUARDRAILS_REQUEST_SCHEMA" >"$scratch/schema.json" 2>/dev/null; then
    schema="$scratch/schema.json"
  else
    schema="$root/$GUARDRAILS_REQUEST_SCHEMA"
    echo "note: $excludes_ref has no $GUARDRAILS_REQUEST_SCHEMA; the requests are checked against the one in the working tree"
  fi
  if [[ -n "$checked_commit" ]]; then
    content_tree="$(fingerprint_commit "$root" "$scratch" "$checked_commit" "${excludes[@]}")" ||
      fail "could not compute the content tree of $checked_commit."
    if [[ "$checked_commit" == "$(git -C "$root" rev-parse "$to")" ]]; then
      echo "content tree: $content_tree (of commit $checked_commit, without ${excludes[*]})"
    else
      echo "content tree: $content_tree (of the finish commit $checked_commit, before the merges of the base; without ${excludes[*]})"
    fi
  else
    content_tree="$(FINGERPRINT_EXCLUDES=("${excludes[@]}") && fingerprint_worktree "$root" "$scratch")" ||
      fail "could not compute the content tree of the working tree."
    echo "content tree: $content_tree (of the working tree, without ${excludes[*]})"
  fi
  for path in "${requests[@]}"; do
    if [[ -n "$to" ]]; then
      git -C "$root" show "$to:$path" >"$scratch/request.json" 2>/dev/null || fail "could not read $path from $to."
      request="$scratch/request.json"
    else
      request="$root/$path"
    fi
    errors="$(guardrails_request_name_errors "$path")"
    [[ -n "$errors" ]] || errors="$(guardrails_request_errors "$request" "$schema")"
    if [[ -z "$errors" && "$(jq -r '.content_tree' "$request")" != "$content_tree" ]]; then
      errors="its content_tree $(jq -r '.content_tree' "$request") is not the content tree recomputed here"
    fi
    if [[ -n "$errors" ]]; then
      echo "refused: $path (${errors//$'\n'/; })"
      refused=1
    else
      echo "request: $path names the content tree recomputed here"
    fi
  done
fi
[[ "$refused" -eq 0 ]] || exit 4
[[ "$level" != "protected" || "$fail_on_protected" -eq 0 ]] || exit 3
