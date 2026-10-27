#!/usr/bin/env bash

set -euo pipefail

# The arguments as given, for a run that records itself (lib/records.sh).
records_arguments=("$@")

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/review-data.sh"
source "$script_dir/lib/fingerprint.sh"
source "$script_dir/lib/planning.sh"
source "$script_dir/lib/guardrails.sh"
source "$script_dir/lib/risk.sh"
source "$script_dir/lib/completion.sh"
source "$script_dir/lib/records.sh"
source "$script_dir/lib/attribution.sh"

usage() {
  echo "Usage: $0 <issue-number> \"<commit summary>\" [--no-review \"<reason>\"] [--unattended] [--partial]"
  echo
  echo "Run in the feature worktree. Checks that the feature is complete, that"
  echo "verification passes, and that the latest independent review is current,"
  echo "resolved, and covers the complete feature, then commits the feature with an"
  echo "editable, structured message. It never pushes or merges."
  echo
  echo "Complete means: the implementer's completion record (.agents/completion/"
  echo "<issue>.json) says complete, or awaiting_evidence when only evidence of a"
  echo "later gate is pending, with evidence for every acceptance criterion that can"
  echo "have it now, and the handoff note lists no remaining work. --partial commits work that"
  echo "is not complete, as your explicit choice: the commit message says what"
  echo "remains, and publish-feature.sh then opens a draft pull request that does"
  echo "not close the Issue."
  echo
  echo "--no-review is only for changes that .agents/policies/autonomy.md classifies"
  echo "as low risk; the reason is recorded in the commit message. Without it, a"
  echo "feature without a review is committed only when it is low risk and the risk"
  echo "policy of the base (.agents/policies/risk.conf) says 'low: review: none'; the"
  echo "commit message then says 'not reviewed: Low risk by project policy'."
  echo
  echo "The list of changes in the message comes from .agents/summaries/<issue>.md,"
  echo "which the implementer writes. --unattended commits that message as it is,"
  echo "without opening an editor, and refuses when that summary is missing."
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

unattended=0
partial=0
arguments=()
for argument in "$@"; do
  case "$argument" in
    --unattended) unattended=1 ;;
    --partial) partial=1 ;;
    *) arguments+=("$argument") ;;
  esac
done
set -- ${arguments[@]+"${arguments[@]}"}

[[ $# -eq 2 || ( $# -eq 4 && "$3" == "--no-review" ) ]] || usage
issue="$1"
summary="$2"
records_wrap feature "$issue" "$0" ${records_arguments[@]+"${records_arguments[@]}"}
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

# The completion gate: a feature is committed as done only when the
# implementer's completion record says so and nothing contradicts it. The
# record is a claim; the review of the complete feature, checked below, is
# what confirms it against the code.
completion_file="$(completion_record "$root" "$issue")"
if [[ -f "$completion_file" ]]; then
  git -C "$root" check-ignore -q "$COMPLETION_DIR/$issue.json" ||
    fail "Git does not ignore $COMPLETION_DIR/$issue.json, so it would be committed. Add '$COMPLETION_DIR/' to .gitignore, or take over the template's .gitignore with ./scripts/sync-template.sh."
fi
gate="$(completion_gate "$root" "$issue")"
gate_status="$(printf '%s\n' "$gate" | sed -n 1p)"
gate_reasons="$(printf '%s\n' "$gate" | sed 1d)"
refuse_incomplete() {
  echo "Error: $1" >&2
  [[ -z "$gate_reasons" ]] || printf '%s\n' "$gate_reasons" | sed 's/^/  - /' >&2
  echo "$2" >&2
  echo "Nothing was committed." >&2
  exit 1
}
case "$gate_status" in
  complete | awaiting_evidence)
    [[ "$partial" -eq 0 ]] ||
      fail "--partial was given, but the completion gate passes: the feature is $gate_status. Run without --partial."
    ;;
  partial | blocked)
    [[ "$partial" -eq 1 ]] ||
      refuse_incomplete "the feature is not complete ($gate_status):" \
        "Continue the work with ./scripts/start-feature.sh $issue --resume. To commit the work as it is, as your own choice, add --partial: the pull request then stays a draft and does not close Issue #$issue."
    # The commit message is made from the record. A record that says complete
    # or awaiting_evidence while the handoff note lists remaining work would
    # be committed as such, without what remains, so the record has to say
    # what is left first.
    ! completion_ready "$(jq -r '.status' "$completion_file")" ||
      refuse_incomplete "the completion record says $(jq -r '.status' "$completion_file"), so the work cannot be committed as partial:" \
        "Correct $COMPLETION_DIR/$issue.json first: the status partial or blocked, the criteria that are not met, and what remains. Then run again with --partial."
    ;;
  missing)
    refuse_incomplete "the completion gate does not pass:" \
      "The implementer writes the completion record (.agents/prompts/implementer.md, 'Completion'); resume it with ./scripts/start-feature.sh $issue --resume, or write the record yourself."
    ;;
  *)
    refuse_incomplete "the completion record cannot be used:" \
      "Correct $COMPLETION_DIR/$issue.json (.agents/prompts/implementer.md, 'Completion'), or resume the implementer with ./scripts/start-feature.sh $issue --resume."
    ;;
esac
completion_lines="$(completion_commit_lines "$root" "$issue")"
[[ "$partial" -eq 0 ]] || records_intervention "committed partial work with --partial"

# A feature keeps the architecture and the ADRs up to date, but it does not
# change what the product is or which features it gets, nor the approval
# itself: that makes the planning approval stale and needs a planning cycle.
# Checked in a project with an approved planning, on the feature's base or
# in the working tree.
feature_merge_base=""
feature_base_ref=""
latest=""
feature_base_branch="$(git -C "$root" config --get "branch.$branch.workflow-base" || true)"
if feature_base_lines="$(feature_base "$root" "${feature_base_branch:-main}")"; then
  feature_merge_base="$(printf '%s\n' "$feature_base_lines" | sed -n 2p)"
  feature_base_ref="$(guardrails_rules_refs "$root" "${feature_base_branch:-main}")"
  if [[ -f "$root/$PLANNING_APPROVAL_FILE" ]] ||
    git -C "$root" cat-file -e "$feature_merge_base:$PLANNING_APPROVAL_FILE" 2>/dev/null; then
    planning_changes="$(
      git -C "$root" diff --name-only "$feature_merge_base" -- "${PLANNING_PRODUCT_SCOPE[@]}" "$PLANNING_APPROVAL_FILE"
      git -C "$root" ls-files --others --exclude-standard -- "${PLANNING_PRODUCT_SCOPE[@]}" "$PLANNING_APPROVAL_FILE"
    )"
    if [[ -n "$planning_changes" ]]; then
      echo "Error: this feature changes planning documents that only a planning cycle may change:" >&2
      printf '%s\n' "$planning_changes" | sort -u | sed 's/^/  /' >&2
      echo "Take these changes out of the feature, and make them through a change cycle:" >&2
      echo "  ./scripts/start-planning.sh <name> --change <file>" >&2
      echo "The architecture and the ADRs may be updated in a feature. Nothing was committed." >&2
      exit 1
    fi
  fi
elif [[ -f "$root/$PLANNING_APPROVAL_FILE" ]] || git -C "$root" cat-file -e "HEAD:$PLANNING_APPROVAL_FILE" 2>/dev/null; then
  fail "could not determine the base of $branch, so it cannot be checked that the feature leaves the approved planning as it is. Nothing was committed."
fi

# The risk level of the feature (lib/risk.sh), computed from the diff by the
# rules of the base. The implementer's record can raise it, never lower it:
# a record that claims less is refused here, before the checks run. The
# effective level, with the reviewer's classification, is decided below.
if [[ -n "$feature_merge_base" ]]; then
  risk_computed_lines="$(risk_computed "$root" "$feature_base_ref" "$feature_merge_base")"
else
  risk_computed_lines="$(risk_undetermined "the base of the feature could not be determined")"
fi
if risk_claim_below "$risk_computed_lines" "$completion_file"; then
  echo "Error: the completion record claims risk: $(risk_recorded "$completion_file"), but the feature is $(printf '%s\n' "$risk_computed_lines" | sed -n 1p) by the rules of its base:" >&2
  printf '%s\n' "$risk_computed_lines" | sed '1d; s/^/  - /' >&2
  echo "A recorded level can raise the computed one, never lower it. Correct or remove 'risk' in $COMPLETION_DIR/$issue.json. Nothing was committed." >&2
  exit 1
fi

# Agent attribution. When the project disables it (.agents/attribution.conf),
# no commit of the feature may name an agent as a co-author. Only the commits
# of the feature are checked, from where it left its base, never the history
# of the base; a co-author who is a person passes.
attribution="$(attribution_preference "$root")" || exit 1
if [[ "$attribution" == "disabled" ]]; then
  if [[ -n "$feature_merge_base" ]]; then
    attributed="$(attribution_commit_trailers "$root" "$feature_merge_base..HEAD")"
  else
    attributed="$(attribution_commit_trailers "$root" -1 HEAD)"
  fi
  if [[ -n "$attributed" ]]; then
    echo "Error: agent attribution is disabled ($ATTRIBUTION_CONFIG), but a commit of this feature names an agent as a co-author:" >&2
    printf '%s\n' "$attributed" | attribution_format_commits >&2
    echo "Remove the trailer from the commit (git commit --amend for the last one, an interactive rebase of the feature branch for an earlier one); co-authors who are people stay. Nothing was committed." >&2
    exit 1
  fi
fi

# 1. Verification passes. A pass that was already recorded for exactly this
# content, by apply-triage.sh or review-feature.sh, is not repeated.
echo "Checking repository verification..."
(cd "$root" && ./scripts/verify.sh --reuse) || fail "verification failed; nothing was committed."
echo

# 2. The latest review is current and resolved, unless explicitly skipped.
slug="${branch//\//-}"
shopt -s nullglob
reviews=("$root/.agents/reviews/${slug}-review-"[0-9][0-9].json)
shopt -u nullglob
if [[ -n "$no_review_reason" ]]; then
  review_line="Review: no independent review (low risk: $no_review_reason)"
elif [[ "${#reviews[@]}" -eq 0 ]]; then
  # Without a review, a feature is committed only when the risk policy of
  # the base says 'low: review: none' and the feature is low: by the diff
  # and the implementer's record, since no reviewer classified it. The merge
  # approval gate then has no classification of the impact, so the owner
  # must approve the merge, as for any feature without one.
  unreviewed_level="$(risk_decision "$risk_computed_lines" "$completion_file" "" | sed -n 1p)"
  review_requirement="$(risk_requirement "$root" "$feature_base_ref" "$unreviewed_level" review)"
  if [[ "$unreviewed_level" == "low" && "$(printf '%s\n' "$review_requirement" | sed -n 1p)" == "none" ]]; then
    echo "No review of this feature exists; it is low risk, and $RISK_CONFIG of the base says 'low: review: none'."
    echo
    review_line="Review: not reviewed: Low risk by project policy ($RISK_CONFIG of the base: low: review: none)"
  else
    {
      echo "Error: no review of this feature exists, and it is $unreviewed_level risk:"
      printf '%s\n' "$risk_computed_lines" | sed '1d; s/^/  - /'
      printf '%s\n' "$review_requirement" | sed '1d; s/^/  - /'
      if [[ "$unreviewed_level" == "low" ]]; then
        echo "Only a low-risk feature in a project whose $RISK_CONFIG says 'low: review: none' is committed without a review."
      else
        echo "Only a low-risk feature may be committed without a review, in a project whose $RISK_CONFIG says 'low: review: none'."
      fi
      echo "Run ./scripts/review-feature.sh $issue, or use --no-review for a low-risk change. Nothing was committed."
    } >&2
    exit 1
  fi
else
  latest="${reviews[${#reviews[@]}-1]}"
  latest_relative="${latest#"$root"/}"

  errors="$(review_artifact_errors "$latest")"
  [[ -z "$errors" ]] || fail "the latest review is invalid: ${errors//$'\n'/; }"
  [[ "$(jq -r '.kind // "feature"' "$latest")" == "feature" && "$(jq -r '.issue' "$latest")" == "$issue" ]] ||
    fail "$latest_relative is not a review of Issue #$issue."
  # The review compared the feature against its base. That base is checked:
  # the merge base the review names must be the one the feature has now, or
  # the review judged another diff (the base was merged or rebased since).
  [[ -z "$feature_merge_base" || "$(jq -r '.merge_base' "$latest")" == "$feature_merge_base" ]] ||
    fail "the latest review ($latest_relative) compared the feature against $(jq -r '.merge_base' "$latest" | cut -c1-12), but the feature left its base at $(cut -c1-12 <<<"$feature_merge_base") now: the base of the branch changed since the review. Run ./scripts/review-feature.sh $issue again."

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

  # The review that a commit rests on covers the complete feature. A round
  # that reviewed only changes confirms fixes; whether the Issue is done is
  # judged on the whole diff against the Issue.
  [[ "$(jq -r '.scope.kind // "full"' "$latest")" != "changes" ]] ||
    fail "the latest review (round $(jq -r '.round' "$latest")) covers only the changes since round $(jq -r '.scope.since_round' "$latest"). A feature is committed on a review of the complete feature: run ./scripts/review-feature.sh $issue (without --changes)."
  # And on content that passed the full verification: a round on a partial
  # check (review-feature.sh --checks) is an intermediate round, whatever
  # the risk policy allows for it.
  [[ "$(jq -r '.verification.status // "passed"' "$latest")" != "partial" ]] ||
    fail "the latest review (round $(jq -r '.round' "$latest")) was made on partially checked content: only the groups $(jq -r '.verification.groups | join(", ")' "$latest") of the verification ran before it. A feature is committed on a review of content that passed the full verification: run ./scripts/review-feature.sh $issue (without --checks)."

  round="$(jq -r '.round' "$latest")"
  verdict="$(jq -r '.verdict | gsub("_"; " ")' "$latest")"
  blocking="$(jq '[.findings[] | select(.severity == "critical" or .severity == "major")] | length' "$latest")"
  [[ "$blocking" -eq 0 ]] ||
    fail "the latest review (round $round) has $blocking critical or major finding(s). Triage, fix, and review again."
  # The level the commit is decided on, for the triage mode: a light triage
  # is for a low- or medium-risk feature only.
  committed_level="$(risk_decision "$risk_computed_lines" "$completion_file" "$latest" | sed -n 1p)"

  # Every round with findings needs an approved triage that was published on
  # the Issue; only the latest round may not have FIX_NOW findings left, since
  # a newer, current review confirms the fixes of earlier rounds.
  triage_note=""
  for review in "${reviews[@]}"; do
    [[ "$(jq '.findings | length' "$review")" -gt 0 ]] || continue
    review_round="$(jq -r '.round' "$review")"
    triage="$(review_latest_triage "$root" "$review")"
    [[ -n "$triage" ]] ||
      fail "the findings of round $review_round are not triaged. Run ./scripts/triage-review.sh ${review#"$root"/}. $([[ "$review" == "$latest" ]] && echo "(Triage before you fix.)" || echo "That round is older than the latest: if its findings were fixed since, it is triaged as a historical review against what it reviewed.")"
    triage_relative="${triage#"$root"/}"
    errors="$(triage_artifact_errors "$triage" "$review")"
    [[ -z "$errors" ]] || fail "the triage of round $review_round is invalid: ${errors//$'\n'/; }"
    [[ "$(jq -r '.published_at // empty' "$triage")" != "" ]] ||
      fail "the triage of round $review_round was not published on Issue #$issue. Run ./scripts/triage-review.sh --publish $triage_relative."
    if [[ "$review" == "$latest" ]]; then
      [[ "$(jq '[.decisions[] | select(.decision == "FIX_NOW")] | length' "$triage")" -eq 0 ]] ||
        fail "round $review_round has FIX_NOW findings. Apply them with ./scripts/apply-triage.sh $triage_relative and review again."
      # 'triage: light' is refused for high, whatever the policy or the
      # artifact says: the level is decided here from the diff, the record,
      # and the review, and a light triage of a feature that is high now is
      # not the triage the commit may rest on.
      [[ "$(jq -r '.triage.mode // "full"' "$triage")" != "light" || "$committed_level" != "high" ]] ||
        fail "the triage of round $review_round is a light triage, but the feature is high risk: 'triage: light' is refused for a high-risk feature, which keeps the full triage. Triage the round again: ./scripts/triage-review.sh ${review#"$root"/}. Nothing was committed."
    fi
    triage_note="; triage published on #$issue"
  done
  review_line="Review: round $round, $verdict, by $(jq -r '"\(.reviewer.agent) (\(.reviewer.model))"' "$latest")$triage_note"
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

# The implementer's summary of the changes. Lines that are not list items are
# left out, so the message keeps its shape.
changes="- TODO: summarize the main changes"
summary_file="$root/.agents/summaries/$issue.md"
if [[ -f "$summary_file" ]]; then
  git -C "$root" check-ignore -q ".agents/summaries/$issue.md" ||
    fail "Git does not ignore .agents/summaries/$issue.md, so it would be committed. Add '.agents/summaries/' to .gitignore, or take over the template's .gitignore with ./scripts/sync-template.sh."
fi
if [[ -f "$summary_file" ]] && grep -q '^[[:space:]]*- [^[:space:]]' "$summary_file"; then
  changes="$(grep '^[[:space:]]*- [^[:space:]]' "$summary_file" | sed 's/^[[:space:]]*//')"
elif [[ "$unattended" -eq 1 ]]; then
  # Nobody edits the message of an unattended commit, so it would go out
  # without saying what changed.
  fail "the implementer supplied no summary of the changes (.agents/summaries/$issue.md), and an unattended commit is not edited. Resume the implementer with ./scripts/start-feature.sh $issue --resume, or write the summary. Nothing was committed."
fi

# The merge approval gate: whether the owner must approve the merge of this
# feature. The rules are checked on the diff, by the rules of the base; the
# independent reviewer classified the impact. The heaviest of the two decides,
# and a missing classification gives no permission.
if [[ -n "$feature_merge_base" ]]; then
  approval_lines="$(guardrails_decision "$root" "$feature_base_ref" "$feature_merge_base" "$latest")"
else
  approval_lines="owner"$'\n'"the base of the feature could not be determined, so the gate could not check the diff"
fi
# A criterion of the owner_approval gate that the record leaves pending asks
# for the owner's approval too. The record can only require it, never grant
# it: the decision stays with the heaviest of the rules, the review, and the
# Issue's own criteria.
owner_pending="$(jq -r '.criteria[] | select(.status == "pending" and .gate == "owner_approval") | .criterion' "$completion_file")"
if [[ -n "$owner_pending" ]]; then
  if [[ "$(printf '%s\n' "$approval_lines" | sed -n 1p)" != "owner" ]]; then
    approval_lines="owner"
  fi
  approval_lines+=$'\n'"$(printf '%s\n' "$owner_pending" | sed 's/^/the completion record leaves a criterion of the owner_approval gate pending: /')"
fi
if [[ "$(printf '%s\n' "$approval_lines" | sed -n 1p)" == "owner" ]]; then
  merge_approval="- required from the project owner, for exactly this commit"
  echo "This feature needs the owner's approval before it is merged:"
  printf '%s\n' "$approval_lines" | sed '1d; s/^/  - /'
  echo "The pull request can be opened; no script or agent may merge it."
  echo
else
  merge_approval="- not required"
fi
merge_approval+=$'\n'"$(printf '%s\n' "$approval_lines" | sed '1d; s/^/- /')"
if [[ -n "$latest" ]]; then
  merge_approval+=$'\n'"- decided for the reviewed content $(jq -r '.reviewed_tree' "$latest")"
fi

# The effective risk level: the computed one, raised by the implementer's
# record and by the reviewer's classification of the impact, never lowered.
risk_lines="$(risk_decision "$risk_computed_lines" "$completion_file" "$latest")"
risk_level="$(printf '%s\n' "$risk_lines" | sed -n 1p)"
risk_block="Risk: $risk_level"$'\n'"$(printf '%s\n' "$risk_lines" | sed '1d; s/^/- /')"
echo "Risk level: $risk_level"
printf '%s\n' "$risk_lines" | sed '1d; s/^/  - /'
# The triage mode of the policy for that level. It is not part of the
# commit message; publish-feature.sh names it in the pull request. A refused
# value ('high: triage: light') is reported here, and the full triage applies.
triage_mode_lines="$(risk_triage_mode "$root" "$feature_base_ref" "$risk_level")"
echo "Triage mode: $(printf '%s\n' "$triage_mode_lines" | sed -n 1p) ($(printf '%s\n' "$triage_mode_lines" | sed -n 2p))"
echo

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
$changes

$completion_lines

Verification:
- ./scripts/verify.sh passed

Manual steps:
$manual_steps

$review_line

Merge approval:
$merge_approval

$risk_block

Refs #$issue
EOF

commit_options=(--edit)
[[ "$unattended" -eq 0 ]] || commit_options=(--quiet)
if ! git -C "$root" commit "${commit_options[@]}" -F "$message_file"; then
  echo "Error: the commit was not created. The changes remain staged." >&2
  exit 1
fi

# The message as it was committed, after the editor and any hook: with agent
# attribution disabled it may neither name an agent as a co-author nor carry
# generated attribution text, which publish-feature.sh would copy into the
# pull request description. Such a commit is undone; the changes stay staged.
if [[ "$attribution" == "disabled" ]]; then
  attributed="$(
    git -C "$root" log -1 --format=%B | attribution_agent_trailers
    git -C "$root" log -1 --format=%B | attribution_generated_lines
  )"
  if [[ -n "$attributed" ]]; then
    git -C "$root" reset --soft --quiet HEAD^
    echo "Error: agent attribution is disabled ($ATTRIBUTION_CONFIG), but the commit message carries it:" >&2
    printf '%s\n' "$attributed" | sed 's/^/  /' >&2
    echo "The commit was undone; the changes remain staged. Run finish-feature.sh again with a message that leaves it out." >&2
    exit 1
  fi
fi

echo
echo "Committed $(git -C "$root" rev-parse --short HEAD) on $branch."
echo
if [[ "$gate_status" == "complete" ]]; then
  echo "Next: push the branch and open the pull request; follow its checks there:"
elif [[ "$gate_status" == "awaiting_evidence" ]]; then
  echo "The work is committed as $gate_status: evidence of a later gate is pending ($(completion_pending_gates "$root" "$issue" | paste -sd, - | sed 's/,/, /g'))."
  echo "Next: push the branch and open the pull request; follow its checks there:"
else
  echo "The work is committed as $gate_status. Next: push the branch; the pull request is"
  echo "opened as a draft and does not close Issue #$issue:"
fi
echo "  ./scripts/publish-feature.sh $issue"
echo "After the merge, from the primary checkout: ./scripts/cleanup-worktree.sh $issue"
if [[ "$gate_status" == "awaiting_evidence" ]] && completion_pending_gates "$root" "$issue" | grep -qx "post_merge"; then
  echo "The Issue stays open until the post_merge evidence is recorded after the merge:"
  echo "  ./scripts/record-post-merge.sh $issue \"<criterion>\" \"<evidence>\""
fi
