#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/review-data.sh"
source "$script_dir/lib/fingerprint.sh"
source "$script_dir/lib/planning.sh"

usage() {
  echo "Usage:"
  echo "  $0                     Check the planning and record your approval (planning worktree)."
  echo "  $0 --check             Report whether the recorded approval still matches the documents."
  echo "  $0 --amend \"<reason>\"  Approve a small technical amendment without a review round."
  echo
  echo "--check exits 0 when the approval is current, 1 when it is missing or stale,"
  echo "and 2 on an error."
  echo
  echo "--amend is for a change to an approved planning that touches only"
  echo "docs/architecture.md and the ADRs in docs/decisions/, such as amending one"
  echo "decision. It shows the change, asks for your approval, and adds the amendment"
  echo "to the existing approval. Anything else needs a change cycle:"
  echo "  ./scripts/start-planning.sh <name> --change <file>"
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

amend_reason=""
case "$#:${1:-}" in
  0:) ;;
  2:--amend)
    [[ "$2" =~ [^[:space:]] ]] || fail "--amend requires a reason."
    [[ "$2" != *$'\n'* ]] || fail "the reason of an amendment must be a single line."
    amend_reason="$2"
    ;;
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

# An amendment: a change to an approved planning that touches only the
# architecture and the ADRs, approved by the human without a review round.
amend() {
  local base_ref
  local base
  local base_approval
  local recorded
  local base_tree
  local changed
  local path
  local status
  local outside=""
  local files=""
  local fingerprint
  local answer=""
  local approval="$root/$PLANNING_APPROVAL_FILE"
  local entry

  if git -C "$root" rev-parse --verify --quiet "origin/main^{commit}" >/dev/null; then
    base_ref="origin/main"
  elif git -C "$root" rev-parse --verify --quiet "main^{commit}" >/dev/null; then
    base_ref="main"
  else
    fail "neither origin/main nor main exists."
  fi
  # The amendment is judged against the base branch as it is now, so fetch it
  # when there is a remote; a failed fetch leaves the local state in use.
  [[ "$base_ref" != "origin/main" ]] || git -C "$root" fetch -q origin main 2>/dev/null || true
  base="$(git -C "$root" merge-base HEAD "$base_ref")" ||
    fail "could not determine the merge base of HEAD and $base_ref."
  [[ "$base" == "$(git -C "$root" rev-parse "$base_ref^{commit}")" ]] ||
    fail "$branch does not contain the latest $base_ref. Bring it up to date first (git merge $base_ref), so the amendment is shown and approved against the current planning."

  # The planning that is amended must have been approved as it is on the base
  # branch; an amendment does not repair a missing or stale approval.
  base_approval="$(git -C "$root" show "$base:$PLANNING_APPROVAL_FILE" 2>/dev/null || true)"
  recorded="$(printf '%s\n' "$base_approval" | sed -n 's/^Planning fingerprint: \([0-9a-f]\{40,64\}\)$/\1/p')"
  [[ "$(printf '%s' "$recorded" | grep -c . || true)" -eq 1 ]] ||
    fail "$base_ref has no planning approval to amend. Approve the planning with a review first."
  [[ $'\n'"$base_approval"$'\n' == *$'\n'"Status: Approved"$'\n'* ]] ||
    fail "$PLANNING_APPROVAL_FILE on $base_ref does not record an approval."
  GIT_INDEX_FILE="$tmp_work/base.index" git -C "$root" read-tree --empty
  git -C "$root" ls-tree -r "$base" -- "${PLANNING_SCOPE[@]}" |
    GIT_INDEX_FILE="$tmp_work/base.index" git -C "$root" update-index --index-info
  base_tree="$(GIT_INDEX_FILE="$tmp_work/base.index" git -C "$root" write-tree)"
  [[ "$base_tree" == "$recorded" ]] ||
    fail "the planning on $base_ref changed after its approval, so there is no current approval to amend. Approve it with a review first."

  [[ -f "$approval" && ! -L "$approval" ]] && git -C "$root" diff --quiet "$base" -- "$PLANNING_APPROVAL_FILE" ||
    fail "$PLANNING_APPROVAL_FILE differs from $base_ref. The script updates it; restore it first."

  # What changed in the planning documents, including uncommitted and
  # untracked files.
  fingerprint="$(fingerprint_files "$root" "$tmp_work" "${PLANNING_SCOPE[@]}")" ||
    fail "could not compute the fingerprint of the planning documents."
  changed="$(GIT_INDEX_FILE="$tmp_work/fingerprint-files.index" git -C "$root" diff --cached --no-renames --name-status "$base" -- "${PLANNING_SCOPE[@]}")"
  [[ -n "$changed" ]] || fail "no planning document differs from $base_ref; there is nothing to amend."

  while IFS=$'\t' read -r status path; do
    case "$path" in
      docs/architecture.md) ;;
      docs/decisions/*.md)
        [[ "${path#docs/decisions/}" != */* && "$status" != "D" ]] || outside+="  $status $path"$'\n'
        ;;
      *) outside+="  $status $path"$'\n' ;;
    esac
    files+="${files:+, }$path"
  done <<<"$changed"
  if [[ -n "$outside" ]]; then
    echo "Error: an amendment may change only docs/architecture.md and add or edit ADRs in docs/decisions/." >&2
    echo "These changes need a review:" >&2
    printf '%s' "$outside" >&2
    echo "Start a change cycle instead: ./scripts/start-planning.sh <name> --change <file>" >&2
    exit 1
  fi
  echo "Amendment to the approved planning on $branch:"
  echo
  GIT_INDEX_FILE="$tmp_work/fingerprint-files.index" git -C "$root" --no-pager diff --cached --no-color "$base" -- "${PLANNING_SCOPE[@]}"
  echo
  echo "Reason: $amend_reason"
  echo "Changed: $files"
  echo
  echo "No agent reviews an amendment; your approval is the only check."
  printf "Approve this amendment? [y/N] "
  read -r answer || true
  case "$answer" in
    y | Y | yes | YES) ;;
    *)
      echo "Declined; the planning approval was not changed."
      exit 0
      ;;
  esac

  [[ "$(fingerprint_files "$root" "$tmp_work" "${PLANNING_SCOPE[@]}")" == "$fingerprint" ]] ||
    fail "a planning document changed while you were deciding; the amendment was not recorded."

  entry="- $(date -u +'%Y-%m-%dT%H:%M:%SZ'), $branch: $amend_reason (changed: $files). Approved by the project owner with \`finish-planning.sh --amend\`, without an independent planning review."
  {
    sed "s/^Planning fingerprint: .*/Planning fingerprint: $fingerprint/" "$approval"
    if ! grep -Fqx "## Amendments after the approval" "$approval"; then
      echo
      echo "## Amendments after the approval"
      echo
      echo "The review rounds above cover the planning as it was first approved. Each"
      echo "amendment below changed only the architecture or the ADRs."
      echo
    fi
    printf '%s\n' "$entry"
  } >"$tmp_work/approval"
  cp "$tmp_work/approval" "$approval"

  echo
  echo "Recorded the amendment in $PLANNING_APPROVAL_FILE."
  echo
  echo "Next steps:"
  echo "  ./scripts/verify.sh"
  echo "  git add ${files//, / } $PLANNING_APPROVAL_FILE"
  echo "  git commit -m \"Amend planning: $name\""
  echo "  git push -u origin \"$branch\""
  echo
  echo "Open the planning PR and merge it; then, from the primary checkout:"
  echo "  ./scripts/cleanup-worktree.sh $branch"
}

# 1. The planning documents exist and the requirements are approved.
for required in docs/PROJECT_REQUIREMENTS.md docs/architecture.md docs/roadmap.md; do
  [[ -f "$root/$required" && ! -L "$root/$required" && -s "$root/$required" ]] ||
    fail "required planning document is missing or empty: $required"
done
grep -Fqx "Status: Approved" "$root/docs/PROJECT_REQUIREMENTS.md" ||
  fail "the project requirements are not approved."

# An amendment replaces the review of steps 2 to 4 by its own checks.
if [[ -n "$amend_reason" ]]; then
  amend
  exit 0
fi

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
