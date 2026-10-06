#!/usr/bin/env bash

set -euo pipefail

# Creates the GitHub Issue for one roadmap feature from its block in
# docs/roadmap.md, or an Issue from an explicit title and body file.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/fingerprint.sh"
source "$script_dir/lib/planning.sh"

usage() {
  echo "Usage:"
  echo "  $0 <feature-id>"
  echo "  $0 \"Issue title\" path/to/body.md [label]"
  echo
  echo "With a feature ID such as F03, the Issue is created from the block under the"
  echo "roadmap heading that starts with that ID, after your approval."
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

require_gh() {
  command -v gh >/dev/null 2>&1 || fail "GitHub CLI 'gh' is not installed."
  gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated. Run: gh auth login"
}

# Explicit title and body file.
create_from_file() {
  local title="$1"
  local body_file="$2"
  local label="${3:-}"
  local args=(issue create --title "$title" --body-file "$body_file")
  local issue_url

  [[ -f "$body_file" ]] || fail "body file not found: $body_file"
  require_gh

  if [[ -n "$label" ]]; then
    if gh label list --limit 100 --json name --jq '.[].name' | grep -Fxq "$label"; then
      args+=(--label "$label")
    else
      echo "Warning: label '$label' does not exist."
      echo "Creating issue without label."
    fi
  fi

  echo "Creating GitHub issue:"
  echo "  Title: $title"
  echo "  Body:  $body_file"

  issue_url="$(gh "${args[@]}")"

  echo
  echo "Issue created:"
  echo "$issue_url"
  echo
  echo "Next: start the work in its own worktree:"
  echo "  ./scripts/start-feature.sh ${issue_url##*/}"
}

# Prints the Issues whose title names the feature ID as "<number>\t<state>\t<title>".
issues_for_feature() {
  local feature="$1"

  gh issue list --state all --limit 200 --search "$feature in:title" --json number,state,title </dev/null |
    jq -r --arg feature "$feature" '
      .[] | select(.title | test("(^|[^A-Za-z0-9])" + $feature + "([^A-Za-z0-9]|$)"))
      | "\(.number)\t\(.state)\t\(.title)"'
}

# roadmap_section <roadmap> <feature-id> <count|title|block>
# Reads Markdown headings, ignoring lines inside fenced code blocks. Prints the
# number of headings that start with the feature ID, the first such heading
# without its markers, or the lines below it up to the next heading of the
# same or a higher level.
roadmap_section() {
  awk -v id="$2" -v mode="$3" '
    function starts_with_id(text) {
      return index(text, id) == 1 && substr(text, length(id) + 1, 1) !~ /[A-Za-z0-9]/
    }
    /^[[:space:]]*(```|~~~)/ {
      fenced = !fenced
      if (inside) { print }
      next
    }
    !fenced && /^#+[[:space:]]/ {
      level = match($0, /[^#]/) - 1
      text = $0
      sub(/^#+[[:space:]]+/, "", text)
      sub(/[[:space:]]+$/, "", text)
      if (inside && level <= block_level) {
        exit
      }
      if (starts_with_id(text)) {
        count++
        if (mode == "title" && count == 1) {
          print text
          exit
        }
        if (mode == "block" && !inside) {
          inside = 1
          block_level = level
          next
        }
      }
    }
    inside { print }
    END {
      if (mode == "count") {
        print count + 0
      }
    }
  ' "$1"
}

create_from_roadmap() {
  local feature="$1"
  local root
  local roadmap
  local heading_count
  local title
  local block
  local existing
  local reference
  local open_issue
  local approval=""
  local issue_url

  root="$(git rev-parse --show-toplevel)"
  roadmap="$root/docs/roadmap.md"
  [[ -f "$roadmap" ]] || fail "roadmap not found: docs/roadmap.md"
  command -v jq >/dev/null 2>&1 || fail "jq is required."

  # The heading ID is the only machine-readable part of the roadmap.
  heading_count="$(roadmap_section "$roadmap" "$feature" count)"
  [[ "$heading_count" -ne 0 ]] || fail "no roadmap heading starts with $feature in docs/roadmap.md."
  [[ "$heading_count" -eq 1 ]] || fail "$heading_count roadmap headings start with $feature; feature IDs must be unique."

  title="$(roadmap_section "$roadmap" "$feature" title)"
  block="$(roadmap_section "$roadmap" "$feature" block)"
  [[ "$block" =~ [^[:space:]] ]] || fail "the roadmap block of $feature is empty."

  # Features start only from a roadmap whose planning is approved as it is now.
  tmp_work="$(mktemp -d "${TMPDIR:-/tmp}/create-feature-issue.XXXXXX")"
  trap 'rm -rf "$tmp_work"' EXIT
  local approval_status=0
  local approval_reason
  approval_reason="$(planning_approval_status "$root" "$tmp_work")" || approval_status=$?
  [[ "$approval_status" -eq 0 ]] ||
    fail "$approval_reason Approve the planning with ./scripts/finish-planning.sh before creating feature Issues."

  require_gh

  existing="$(issues_for_feature "$feature")" ||
    fail "could not list the existing Issues for $feature; no Issue was created."
  if [[ -n "$existing" ]]; then
    echo "Error: $feature already has an Issue; no new Issue was created:" >&2
    printf '%s\n' "$existing" | awk -F '\t' '{ printf "  #%s (%s) %s\n", $1, tolower($2), $3 }' >&2
    exit 1
  fi

  {
    printf '%s\n' "$block" | awk 'NF { found = 1 } found' | awk '{ lines[NR] = $0 } END { last = NR; while (last > 0 && lines[last] !~ /[^[:space:]]/) last--; for (i = 1; i <= last; i++) print lines[i] }'
    echo
    echo "---"
    echo
    echo "Source: \`docs/roadmap.md\`, $feature."
  } >"$tmp_work/body.md"

  echo "Proposed Issue for roadmap feature $feature:"
  echo
  echo "Title: $title"
  echo
  cat "$tmp_work/body.md"
  echo

  # Features this block refers to that are not done yet.
  while IFS= read -r reference; do
    [[ "$reference" != "$feature" ]] || continue
    if ! reference_issues="$(issues_for_feature "$reference")"; then
      echo "Warning: could not check whether $reference, which $feature refers to, is done."
      open_issue=1
      continue
    fi
    while IFS=$'\t' read -r number state issue_title; do
      [[ -n "$number" ]] || continue
      if [[ "$state" == "OPEN" ]]; then
        echo "Warning: $feature refers to $reference, whose Issue #$number is still open: $issue_title"
        open_issue=1
      fi
    done <<<"$reference_issues"
  done < <(printf '%s\n' "$block" | grep -oE '(^|[^A-Za-z0-9])F[0-9]+' | grep -oE 'F[0-9]+' | sort -u)
  [[ -z "${open_issue:-}" ]] || echo

  printf "Create this Issue? [y/N] "
  read -r approval || true
  case "$approval" in
    y | Y | yes | YES) ;;
    *)
      echo "Declined; no Issue was created."
      exit 0
      ;;
  esac

  issue_url="$(gh issue create --title "$title" --body-file "$tmp_work/body.md" </dev/null | tail -n 1)"
  echo
  echo "Issue created for $feature:"
  echo "$issue_url"
  echo
  echo "Next: start the feature in its own worktree:"
  echo "  ./scripts/start-feature.sh ${issue_url##*/}"
}

case "$#" in
  1)
    [[ "$1" =~ ^F[0-9]+$ ]] || fail "feature ID must look like F03: $1"
    create_from_roadmap "$1"
    ;;
  2 | 3)
    create_from_file "$@"
    ;;
  *)
    usage
    ;;
esac
