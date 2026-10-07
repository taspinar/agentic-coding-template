#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/review-data.sh"
source "$script_dir/lib/fingerprint.sh"
source "$script_dir/lib/planning.sh"

usage() {
  echo "Usage:"
  echo "  $0           Check the planning and record your approval (planning worktree)."
  echo "  $0 --check   Report whether the recorded approval still matches the documents."
  echo
  echo "--check exits 0 when the approval is current, 1 when it is missing or stale,"
  echo "and 2 on an error."
  exit 2
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

root="$(git rev-parse --show-toplevel)"
review_data_require_jq
tmp_work="$(mktemp -d "${TMPDIR:-/tmp}/finish-planning.XXXXXX")"
trap 'rm -rf "$tmp_work"' EXIT

case "$#:${1:-}" in
  0:) ;;
  1:--check)
    status=0
    reason="$(planning_approval_status "$root" "$tmp_work")" || status=$?
    case "$status" in
      0) echo "Current: $PLANNING_APPROVAL_FILE matches the planning documents." ;;
      1) echo "Not approved: $reason"; echo "Finish the planning again with ./scripts/finish-planning.sh in a planning worktree." ;;
      *) echo "Error: $reason" >&2 ;;
    esac
    exit "$status"
    ;;
  *) usage ;;
esac

branch="$(git branch --show-current)"
[[ "$branch" == planning/* ]] ||
  fail "finish-planning.sh must run in a planning worktree (branch planning/<name>). Current branch: $branch"
name="${branch#planning/}"

# 1. The planning documents exist and the requirements are approved.
for required in docs/PROJECT_REQUIREMENTS.md docs/architecture.md docs/roadmap.md; do
  [[ -f "$root/$required" && ! -L "$root/$required" && -s "$root/$required" ]] ||
    fail "required planning document is missing or empty: $required"
done
grep -Fqx "Status: Approved" "$root/docs/PROJECT_REQUIREMENTS.md" ||
  fail "the project requirements are not approved."

# 2. The latest planning review exists, is valid, and is current.
shopt -s nullglob
reviews=("$root/.agents/reviews/planning-${name}-review-"[0-9][0-9].json)
shopt -u nullglob
[[ "${#reviews[@]}" -gt 0 ]] || fail "no planning review exists. Run ./scripts/review-planning.sh first."
latest="${reviews[${#reviews[@]}-1]}"
latest_relative="${latest#"$root"/}"
review_errors="$(review_artifact_errors "$latest")"
[[ -z "$review_errors" ]] || fail "the latest planning review is invalid: ${review_errors//$'\n'/; }"
[[ "$(jq -r '.kind' "$latest")" == "planning" && "$(jq -r '.branch' "$latest")" == "$branch" ]] ||
  fail "$latest_relative is not a planning review of $branch."

current=0
review_is_current "$root" "$tmp_work" "$latest" || current=$?
case "$current" in
  0) ;;
  1)
    review_stale_notice "$root" "$tmp_work" "$latest"
    fail "the latest planning review ($latest_relative) is stale: a planning document changed after it. Run ./scripts/review-planning.sh again."
    ;;
  *) fail "could not compute the fingerprint of the planning documents." ;;
esac

# Every rejected, deferred, or escalated decision of every round, oldest first.
shopt -s nullglob
revisions=("$root/.agents/reviews/planning-${name}-review-"[0-9][0-9]-revision.json)
shopt -u nullglob
decisions_file="$tmp_work/decisions.json"
if [[ "${#revisions[@]}" -gt 0 ]]; then
  jq -s '[.[] | .review_round as $round | .decisions[]
          | select(.decision != "ADOPT") | . + {round: $round}]' "${revisions[@]}" >"$decisions_file"
else
  echo '[]' >"$decisions_file"
fi

round="$(jq -r '.round' "$latest")"
verdict="$(jq -r '.verdict' "$latest")"

# Show every finding that was not adopted before any refusal, so the reasons
# are visible.
if [[ "$(jq 'length' "$decisions_file")" -gt 0 ]]; then
  echo "Findings that were not adopted:"
  jq -r '.[] | "- Round \(.round), \(.decision): \(.finding_id) [\(.severity)] \(.title)\n  Rationale: \(.rationale)"' "$decisions_file"
  echo
fi

# 3. The latest round is resolved: no critical or major finding, every finding
#    decided, nothing adopted but not yet applied, and nothing escalated.
blocking="$(jq '[.findings[] | select(.severity == "critical" or .severity == "major")] | length' "$latest")"
[[ "$blocking" -eq 0 ]] ||
  fail "the latest planning review (round $round) has $blocking critical or major finding(s). Revise with ./scripts/revise-planning.sh and review again."

revision="${latest%.json}-revision.json"
if [[ "$(jq '.findings | length' "$latest")" -gt 0 ]]; then
  [[ -f "$revision" ]] ||
    fail "the findings of round $round have no revision decisions. Run ./scripts/revise-planning.sh --review $latest_relative."
  revision_errors="$(revision_artifact_errors "$revision" "$latest")"
  [[ -z "$revision_errors" ]] || fail "the revision of round $round is invalid: ${revision_errors//$'\n'/; }"
  [[ "$(jq '[.decisions[] | select(.decision == "ADOPT")] | length' "$revision")" -eq 0 ]] ||
    fail "round $round has adopted findings that are not applied yet. Run ./scripts/revise-planning.sh --review $latest_relative and review again."
fi

escalated_now="$(jq --argjson round "$round" '[.[] | select(.round == $round and .decision == "ESCALATE")] | length' "$decisions_file")"
[[ "$escalated_now" -eq 0 ]] ||
  fail "round $round has $escalated_now escalated finding(s). Resolve them through Project Grill and a new review round, or decide that they do not apply."

# 4. Escalations of earlier rounds need an explicit resolution by the human;
#    a newer review alone does not resolve them.
earlier_escalations="$(jq -r --argjson round "$round" '
  .[] | select(.round < $round and .decision == "ESCALATE") | "- Round \(.round): \(.finding_id) \(.title)"
' "$decisions_file")"
if [[ -n "$earlier_escalations" ]]; then
  echo "Escalated in earlier rounds:"
  printf '%s\n' "$earlier_escalations"
  printf "Was each of these resolved, by changing the requirements through Project Grill or by deciding that it does not apply? [y/N] "
  resolved=""
  read -r resolved || true
  case "$resolved" in
    y | Y | yes | YES) ;;
    *) fail "the escalated findings of earlier rounds are not resolved." ;;
  esac
  echo
fi

# 5. Ask for approval of exactly the reviewed planning.
reviewed_fingerprint="$(jq -r '.reviewed_tree' "$latest")"
echo "Planning ready for approval:"
echo "  Branch:        $branch"
echo "  Final review:  $latest_relative (round $round, ${verdict//_/ })"
echo

printf "Approve this planning? [y/N] "
approval=""
read -r approval || true
case "$approval" in
  y | Y | yes | YES) ;;
  *)
    echo "Declined; the planning approval was not recorded."
    exit 0
    ;;
esac

# 6. Record the approval for the reviewed planning, and only if it did not
#    change while you were deciding.
fingerprint="$(fingerprint_files "$root" "$tmp_work" "${PLANNING_SCOPE[@]}")" ||
  fail "could not compute the fingerprint of the planning documents."
[[ "$fingerprint" == "$reviewed_fingerprint" ]] ||
  fail "a planning document changed after the final review; the approval was not recorded. Run ./scripts/review-planning.sh again."
{
  echo "# Planning Approval"
  echo
  echo "Status: Approved"
  echo "Approved at: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo "Planning branch: $branch"
  [[ ! -f "$root/docs/changes/$name.md" ]] || echo "Change request: docs/changes/$name.md"
  echo "Final review: round $round, ${verdict//_/ }, by $(jq -r '"\(.reviewer.agent) (\(.reviewer.model))"' "$latest")"
  echo "Planning fingerprint: $fingerprint"
  echo
  echo "Recorded by \`scripts/finish-planning.sh\`. The approval covers these planning"
  echo "documents; any change to them invalidates it (\`./scripts/finish-planning.sh --check\`):"
  echo
  for path in "${PLANNING_SCOPE[@]}"; do
    echo "- \`$path\`"
  done
  echo
  echo "## Review rounds"
  echo
  for review in "${reviews[@]}"; do
    jq -r '"- Round \(.round): \(.verdict | gsub("_"; " ")), \(.findings | length) finding(s), by \(.reviewer.agent) (\(.reviewer.model))"' "$review"
  done
  echo
  if [[ -n "$earlier_escalations" ]]; then
    echo "## Escalations confirmed as resolved"
    echo
    printf '%s\n' "$earlier_escalations"
    echo
  fi
  echo "## Findings that were not adopted"
  echo
  if [[ "$(jq 'length' "$decisions_file")" -eq 0 ]]; then
    echo "None."
  else
    jq -r '.[] | "- Round \(.round), \(.decision): \(.finding_id) [\(.severity)] \(.title). \(.rationale)"' "$decisions_file"
  fi
} >"$root/$PLANNING_APPROVAL_FILE"

echo
echo "Recorded the approval in $PLANNING_APPROVAL_FILE."
echo
echo "Next steps:"
echo "  ./scripts/verify.sh"
to_add=()
for path in "${PLANNING_SCOPE[@]}"; do
  [[ ! -e "$root/$path" ]] || to_add+=("$path")
done
echo "  git add ${to_add[*]} $PLANNING_APPROVAL_FILE"
if [[ -f "$root/docs/changes/$name.md" ]]; then
  echo "  git commit -m \"Plan change: $name\""
else
  echo "  git commit -m \"Plan project bootstrap\""
fi
echo "  git push -u origin \"$branch\""
echo
echo "Open the planning PR; $PLANNING_APPROVAL_FILE summarizes the review rounds and the"
echo "findings that were not adopted for its description. After the merge, from the"
echo "primary checkout:"
echo "  ./scripts/cleanup-worktree.sh $branch    # removes this worktree and updates main"
echo "  ./scripts/create-feature-issue.sh <feature-id>    # for example F01"
