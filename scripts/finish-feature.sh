#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/review-data.sh"
source "$script_dir/lib/fingerprint.sh"

usage() {
  echo "Usage: $0 <issue-number> \"<commit summary>\" [--no-review \"<reason>\"]"
  echo
  echo "Run in the feature worktree. Checks that verification passes and that the"
  echo "latest independent review is current and resolved, then commits the feature"
  echo "with an editable, structured message. It never pushes or merges."
  echo
  echo "--no-review is only for changes that .agents/policies/autonomy.md classifies"
  echo "as low risk; the reason is recorded in the commit message."
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

[[ $# -eq 2 || ( $# -eq 4 && "$3" == "--no-review" ) ]] || usage
issue="$1"
summary="$2"
no_review_reason="${4:-}"

[[ "$issue" =~ ^[0-9]+$ ]] || fail "issue number must be numeric: $issue"
[[ "$summary" =~ [^[:space:]] ]] || fail "the commit summary is empty."
[[ $# -eq 2 || "$no_review_reason" =~ [^[:space:]] ]] || fail "--no-review requires a reason."

root="$(git rev-parse --show-toplevel)"
branch="$(git branch --show-current)"
[[ "$branch" == feature/${issue}-* ]] ||
  fail "finish-feature.sh must run on feature/${issue}-*. Current branch: $branch"

[[ -n "$(git -C "$root" status --porcelain)" ]] || fail "there are no changes to commit."
review_data_require_jq

# 1. Verification passes. A pass that was already recorded for exactly this
# content, by apply-triage.sh or review-feature.sh, is not repeated.
echo "Checking repository verification..."
(cd "$root" && ./scripts/verify.sh --reuse) || fail "verification failed; nothing was committed."
echo

# 2. The latest review is current and resolved, unless explicitly skipped.
if [[ -n "$no_review_reason" ]]; then
  review_line="Review: no independent review (low risk: $no_review_reason)"
else
  slug="${branch//\//-}"
  shopt -s nullglob
  reviews=("$root/.agents/reviews/${slug}-review-"[0-9][0-9].json)
  shopt -u nullglob
  [[ "${#reviews[@]}" -gt 0 ]] ||
    fail "no review of this feature exists. Run ./scripts/review-feature.sh $issue, or use --no-review for a low-risk change."
  latest="${reviews[${#reviews[@]}-1]}"
  latest_relative="${latest#"$root"/}"

  errors="$(review_artifact_errors "$latest")"
  [[ -z "$errors" ]] || fail "the latest review is invalid: ${errors//$'\n'/; }"
  [[ "$(jq -r '.kind // "feature"' "$latest")" == "feature" && "$(jq -r '.issue' "$latest")" == "$issue" ]] ||
    fail "$latest_relative is not a review of Issue #$issue."

  tmp_work="$(mktemp -d "${TMPDIR:-/tmp}/finish-feature.XXXXXX")"
  trap 'rm -rf "$tmp_work"' EXIT
  current=0
  review_is_current "$root" "$tmp_work" "$latest" || current=$?
  case "$current" in
    0) ;;
    1)
      review_stale_notice "$root" "$tmp_work" "$latest"
      fail "the latest review ($latest_relative) is stale: the code changed after it. Run ./scripts/review-feature.sh $issue again."
      ;;
    *) fail "could not compute the fingerprint of the working tree." ;;
  esac

  # A review of changes only covers what changed since an earlier round. It
  # counts when that round reviewed exactly the content it builds on, and so
  # on back to a review of the complete feature.
  cursor="$latest"
  while [[ "$(jq -r '.scope.kind // "full"' "$cursor")" == "changes" ]]; do
    since="$(jq -r '.scope.since_round' "$cursor")"
    earlier="$root/.agents/reviews/${slug}-review-$(printf '%02d' "$since").json"
    [[ -f "$earlier" ]] ||
      fail "round $(jq -r '.round' "$cursor") reviewed only the changes since round $since, whose review is missing. Run a complete review: ./scripts/review-feature.sh $issue"
    errors="$(review_artifact_errors "$earlier")"
    [[ -z "$errors" ]] || fail "the review of round $since is invalid: ${errors//$'\n'/; }"
    [[ "$(jq -r '.reviewed_tree' "$earlier")" == "$(jq -r '.scope.base_tree' "$cursor")" ]] ||
      fail "round $(jq -r '.round' "$cursor") reviewed only the changes since round $since, but not from the content that round $since reviewed. Run a complete review: ./scripts/review-feature.sh $issue"
    cursor="$earlier"
  done

  round="$(jq -r '.round' "$latest")"
  verdict="$(jq -r '.verdict | gsub("_"; " ")' "$latest")"
  blocking="$(jq '[.findings[] | select(.severity == "critical" or .severity == "major")] | length' "$latest")"
  [[ "$blocking" -eq 0 ]] ||
    fail "the latest review (round $round) has $blocking critical or major finding(s). Triage, fix, and review again."

  # Every round with findings needs an approved triage that was published on
  # the Issue; only the latest round may not have FIX_NOW findings left, since
  # a newer, current review confirms the fixes of earlier rounds.
  triage_note=""
  for review in "${reviews[@]}"; do
    [[ "$(jq '.findings | length' "$review")" -gt 0 ]] || continue
    review_round="$(jq -r '.round' "$review")"
    triage="$(review_latest_triage "$root" "$review")"
    [[ -n "$triage" ]] ||
      fail "the findings of round $review_round are not triaged. Run ./scripts/triage-review.sh ${review#"$root"/}."
    triage_relative="${triage#"$root"/}"
    errors="$(triage_artifact_errors "$triage" "$review")"
    [[ -z "$errors" ]] || fail "the triage of round $review_round is invalid: ${errors//$'\n'/; }"
    [[ "$(jq -r '.published_at // empty' "$triage")" != "" ]] ||
      fail "the triage of round $review_round was not published on Issue #$issue. Run ./scripts/triage-review.sh --publish $triage_relative."
    if [[ "$review" == "$latest" ]]; then
      [[ "$(jq '[.decisions[] | select(.decision == "FIX_NOW")] | length' "$triage")" -eq 0 ]] ||
        fail "round $review_round has FIX_NOW findings. Apply them with ./scripts/apply-triage.sh $triage_relative and review again."
    fi
    triage_note="; triage published on #$issue"
  done
  scope_note=""
  [[ "$(jq -r '.scope.kind // "full"' "$latest")" != "changes" ]] ||
    scope_note=" (changes since round $(jq -r '.scope.since_round' "$latest") only)"
  review_line="Review: round $round$scope_note, $verdict, by $(jq -r '"\(.reviewer.agent) (\(.reviewer.model))"' "$latest")$triage_note"
fi

# 3. Show the manual steps the implementer recorded for this feature.
manual_steps="- none"
manual_file="$root/.agents/manual-steps/$issue.md"
if [[ -f "$manual_file" ]] && grep -q '[^[:space:]]' "$manual_file"; then
  manual_steps="$(grep '[^[:space:]]' "$manual_file")"
  echo "This feature needs these manual steps from you:"
  printf '%s\n' "$manual_steps" | sed 's/^/  /'
  echo
fi

# 4. Stage everything and commit with an editable, structured message.
git -C "$root" add -A
echo "Changes to commit:"
git -C "$root" status --short
echo

message_file="$(mktemp "${TMPDIR:-/tmp}/finish-feature-message.XXXXXX")"
trap 'rm -f "$message_file"; [[ -z "${tmp_work:-}" ]] || rm -rf "$tmp_work"' EXIT
cat >"$message_file" <<EOF
$summary

Issue: #$issue

Changes:
- TODO: summarize the main changes

Verification:
- ./scripts/verify.sh passed

Manual steps:
$manual_steps

$review_line

Refs #$issue
EOF

if ! git -C "$root" commit --edit -F "$message_file"; then
  echo "Error: the commit was not created. The changes remain staged." >&2
  exit 1
fi

echo
echo "Committed $(git -C "$root" rev-parse --short HEAD) on $branch."
echo
echo "Next: push the branch, open the pull request, and wait for CI:"
echo "  ./scripts/publish-feature.sh $issue"
echo "After the merge, from the primary checkout: ./scripts/cleanup-worktree.sh $issue"
