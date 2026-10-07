#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/agent.sh"
source "$script_dir/lib/review-data.sh"
source "$script_dir/lib/fingerprint.sh"

usage() {
  echo "Usage: $0 <triage-json> [--agent <agent>] [--model <model>]"
  echo
  echo "The agent and model come from role 'triage-implementer' in"
  echo ".agents/agents.conf unless --agent and --model are given."
  echo
  echo "Examples:"
  echo "  $0 .agents/triage/feature-5-rendering-review-01-triage.json"
  echo "  $0 .agents/triage/feature-5-rendering-review-01-triage.json --agent claude --model opus"
  exit 1
}

report_errors() {
  echo "Error: $1" >&2
  printf '%s\n' "$2" | sed 's/^/  - /' >&2
  exit 1
}

agent_parse_args "$@"
if [[ "${#AGENT_POSITIONAL[@]}" -ne 1 ]]; then
  usage
fi

triage_input="${AGENT_POSITIONAL[0]}"

root="$(git rev-parse --show-toplevel)"
prompt_file="$root/.agents/prompts/triage-implementer.md"

if [[ ! -f "$triage_input" ]]; then
  echo "Error: triage artifact not found: $triage_input"
  exit 1
fi

triage_dir="$(cd "$(dirname "$triage_input")" && pwd -P)"
triage_path="$triage_dir/$(basename "$triage_input")"

if [[ "$triage_path" != "$root/.agents/triage/"*.json ]]; then
  echo "Error: triage artifact must match .agents/triage/*.json (the generated .md report is not an input)."
  echo "Received: $triage_path"
  exit 1
fi

if [[ ! -f "$prompt_file" ]]; then
  echo "Error: triage implementer prompt not found: $prompt_file"
  exit 1
fi

review_data_require_jq

agent_resolve "$root" triage-implementer "$AGENT_CLI_PROVIDER" "$AGENT_CLI_MODEL"
agent="$AGENT_PROVIDER"
model="$AGENT_MODEL"

source_review_relative="$(triage_source_review "$triage_path")"
if [[ -z "$source_review_relative" ]]; then
  echo "Error: the file is not a triage/v1 artifact with a source review: $triage_input"
  exit 1
fi
if [[ ! "$source_review_relative" =~ ^\.agents/reviews/[^/]+\.json$ ]]; then
  echo "Error: source review must match .agents/reviews/*.json: $source_review_relative"
  exit 1
fi
source_review_path="$root/$source_review_relative"
if [[ ! -f "$source_review_path" ]]; then
  echo "Error: source review artifact not found: $source_review_relative"
  exit 1
fi

# Both stored artifacts are checked with the same rules as agent output, so an
# edited artifact cannot weaken a decision.
review_errors="$(review_artifact_errors "$source_review_path")"
[[ -z "$review_errors" ]] || report_errors "invalid source review artifact:" "$review_errors"

triage_errors="$(triage_artifact_errors "$triage_path" "$source_review_path")"
[[ -z "$triage_errors" ]] || report_errors "invalid or unapproved triage artifact:" "$triage_errors"

tmp_work="$(mktemp -d "${TMPDIR:-/tmp}/apply-triage.XXXXXX")"
trap 'rm -rf "$tmp_work"' EXIT
review_path="$source_review_path"
review_relative="$source_review_relative"
fail() {
  echo "Error: $*" >&2
  exit 1
}

# Triage and fixes apply only to the content that was reviewed.
stale_status=0
review_is_current "$root" "$tmp_work" "$review_path" || stale_status=$?
case "$stale_status" in
  0) ;;
  1)
    review_stale_notice "$root" "$tmp_work" "$review_path"
    fail "the review is stale: the reviewed content changed after $review_relative was written. Run a new review."
    ;;
  *) fail "could not compute the current fingerprint of the working tree." ;;
esac

source_issue="$(jq -r '.issue' "$triage_path")"

branch="$(git branch --show-current)"
if [[ "$branch" != feature/* ]]; then
  echo "Error: apply-triage.sh must run in an existing feature worktree."
  echo "Current branch: $branch"
  exit 1
fi

if [[ "$branch" != feature/${source_issue}-* ]]; then
  echo "Error: current branch does not match source Issue #$source_issue."
  echo "Current branch: $branch"
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: GitHub CLI 'gh' is not installed."
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "Error: GitHub CLI is not authenticated."
  echo "Run: gh auth login"
  exit 1
fi
resolved_issue="$(gh issue view "$source_issue" --json number --template '{{.number}}')"
if [[ "$resolved_issue" != "$source_issue" ]]; then
  echo "Error: could not validate source Issue #$source_issue."
  exit 1
fi

fix_count="$(jq '[.decisions[] | select(.decision == "FIX_NOW")] | length' "$triage_path")"
if [[ "$fix_count" -eq 0 ]]; then
  echo "No FIX_NOW findings found; no implementation agent was started."
  echo "Next: finish the feature:"
  echo "  ./scripts/finish-feature.sh $source_issue \"<commit summary>\""
  exit 0
fi

triage_relative="${triage_path#"$root"/}"
fix_scope="$(jq -r --slurpfile review "$source_review_path" '
  .decisions[] | select(.decision == "FIX_NOW") | . as $d
  | ($review[0].findings[] | select(.id == $d.finding_id)) as $f
  | "### \($f.id). \($f.title)\n\n" +
    "- Severity: \($f.severity)\n" +
    "- Evidence: \($f.evidence)\n" +
    "- Impact: \($f.impact)\n" +
    "- Recommended action: \($f.recommendation)\n" +
    "- Triage rationale: \($d.rationale)\n"
' "$triage_path")"

echo "Approved FIX_NOW scope from $triage_relative:"
echo
printf '%s\n' "$fix_scope"
echo "Findings to resolve: $fix_count"
echo
printf "Start a write-capable $agent agent for this scope? [y/N] "
read -r approval
case "$approval" in
  y | Y | yes | YES) ;;
  *)
    echo "Apply triage declined; no implementation agent was started."
    exit 0
    ;;
esac

start_prompt="Read and follow .agents/prompts/triage-implementer.md.

Source feature Issue: ${source_issue:-unknown}
Source review artifact: ${source_review_relative}
Approved triage artifact: ${triage_relative}

Resolve exactly these approved FIX_NOW findings:

${fix_scope}

Do not implement any DEFER or ACCEPT finding.
Do not commit, push, merge, deploy, or create/close Issues."

file_signature() {
  local path="$1"
  local mode
  local content_hash
  if [[ ! -e "$path" ]]; then
    echo "MISSING"
    return
  fi
  if [[ "$(uname -s)" == "Darwin" ]]; then
    if ! mode="$(stat -f '%Lp' "$path" 2>/dev/null)"; then
      mode="UNREADABLE"
    fi
  else
    if ! mode="$(stat -c '%a' "$path" 2>/dev/null)"; then
      mode="UNREADABLE"
    fi
  fi
  if ! content_hash="$(git hash-object "$path" 2>/dev/null)"; then
    content_hash="UNREADABLE"
  fi
  printf '%s:%s\n' "$content_hash" "$mode"
}

review_signature_before="$(file_signature "$source_review_path")"
triage_signature_before="$(file_signature "$triage_path")"

echo
echo "Starting $agent implementation agent..."
echo

set +e
agent_run write "$agent" "$model" "$root" "$start_prompt"
agent_status=$?
set -e

review_signature_after="$(file_signature "$source_review_path")"
triage_signature_after="$(file_signature "$triage_path")"

protected_artifact_changed=0
if [[ "$review_signature_before" != "$review_signature_after" ]]; then
  echo "Error: implementation agent modified the source review artifact."
  protected_artifact_changed=1
fi

if [[ "$triage_signature_before" != "$triage_signature_after" ]]; then
  echo "Error: implementation agent modified the approved triage artifact."
  protected_artifact_changed=1
fi

echo
echo "Running repository verification..."
set +e
(
  cd "$root"
  ./scripts/verify.sh
)
verification_status=$?
set -e

if [[ "$protected_artifact_changed" -ne 0 ]]; then
  exit 1
fi

if [[ "$agent_status" -ne 0 ]]; then
  echo "Error: implementation agent exited with status $agent_status."
  if [[ "$verification_status" -ne 0 ]]; then
    echo "Repository verification also failed with status $verification_status."
  fi
  exit "$agent_status"
fi

if [[ "$verification_status" -ne 0 ]]; then
  echo "Error: repository verification failed with status $verification_status."
  exit "$verification_status"
fi

echo
echo "FIX_NOW implementation completed and verification passed."
echo "The code changed, so the review is stale. Next: review again to confirm the fixes:"
echo "  ./scripts/review-feature.sh $source_issue"
