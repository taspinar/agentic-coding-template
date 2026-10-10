#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/agent.sh"
source "$script_dir/lib/review-data.sh"
source "$script_dir/lib/fingerprint.sh"
source "$script_dir/lib/verification.sh"
source "$script_dir/lib/review-run.sh"

fail() {
  echo "Error: $*" >&2
  exit 1
}

# --unverified "<reason>" reviews although verification fails. --changes
# reviews only what changed since the previous round.
unverified_reason=""
changes_only=0
arguments=()
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--unverified" ]]; then
    [[ $# -ge 2 && "$2" =~ [^[:space:]] ]] || fail "--unverified requires a reason."
    unverified_reason="$2"
    shift 2
  elif [[ "$1" == "--changes" ]]; then
    changes_only=1
    shift
  else
    arguments+=("$1")
    shift
  fi
done

agent_parse_args ${arguments[@]+"${arguments[@]}"}
if [[ "${#AGENT_POSITIONAL[@]}" -lt 1 || "${#AGENT_POSITIONAL[@]}" -gt 2 ]]; then
  echo "Usage: $0 <issue-number> [base-branch] [--agent <agent>] [--model <model>] [--changes] [--unverified \"<reason>\"]"
  echo
  echo "The agent and model come from role 'reviewer' in .agents/agents.conf"
  echo "unless --agent and --model are given."
  echo
  echo "The review starts only when ./scripts/verify.sh passes for the current"
  echo "content; a pass that was already recorded for it is reused. --unverified"
  echo "reviews anyway, for a review that must help diagnose a failure; the reason"
  echo "is recorded in the review."
  echo
  echo "Every round reviews the complete feature. --changes makes a later round"
  echo "review only what changed since the previous round, with that round's"
  echo "findings and their triage: cheaper after a small fix, but it does not look"
  echo "at the rest of the feature again."
  echo
  echo "Examples:"
  echo "  $0 2"
  echo "  $0 2 --changes"
  echo "  $0 2 develop"
  echo "  $0 2 --agent codex --model gpt-6-astra"
  exit 1
fi

issue="${AGENT_POSITIONAL[0]}"
base="${AGENT_POSITIONAL[1]:-main}"

[[ "$issue" =~ ^[0-9]+$ ]] || fail "issue number must be numeric: $issue"

root="$(git rev-parse --show-toplevel)"
branch="$(git branch --show-current)"
slug="${branch//\//-}"

reviews_dir="$root/.agents/reviews"
prompt_file="$root/.agents/prompts/reviewer.md"
schema_file="$root/.agents/schemas/review.schema.json"

# Ensure we're reviewing the expected feature branch.
if [[ "$branch" != feature/${issue}-* ]]; then
  echo "Error: current branch does not look like feature/${issue}-*" >&2
  echo "Current branch: $branch" >&2
  exit 1
fi

agent_resolve "$root" reviewer "$AGENT_CLI_PROVIDER" "$AGENT_CLI_MODEL"
agent="$AGENT_PROVIDER"
model="$AGENT_MODEL"

[[ -f "$prompt_file" ]] || fail "reviewer prompt not found: $prompt_file"
[[ -f "$schema_file" ]] || fail "review schema not found: $schema_file"
review_data_require_jq

command -v gh >/dev/null 2>&1 || fail "GitHub CLI 'gh' is not installed."
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated. Run: gh auth login"

# The local base branch or origin/<base>, whichever knows where the feature
# left its base; see feature_base.
git -C "$root" rev-parse --verify --quiet "$base^{commit}" >/dev/null ||
  git -C "$root" rev-parse --verify --quiet "origin/$base^{commit}" >/dev/null ||
  fail "base branch not found locally or on origin: $base"
feature_base_lines="$(feature_base "$root" "$base")" ||
  fail "could not determine the merge base of HEAD and $base."
base_ref="$(printf '%s\n' "$feature_base_lines" | sed -n 1p)"
merge_base="$(printf '%s\n' "$feature_base_lines" | sed -n 2p)"

# Determine next review number.
review_number=1
previous_review=""
while true; do
  candidate="$reviews_dir/${slug}-review-$(printf "%02d" "$review_number")"
  if [[ ! -e "$candidate.json" && ! -e "$candidate.md" ]]; then
    out="$candidate"
    break
  fi
  # A round without JSON, such as a review from before JSON artifacts, is not
  # an input for the re-review.
  if [[ -f "$candidate.json" ]]; then
    previous_review="$candidate.json"
  fi
  review_number=$((review_number + 1))
done
review_relative=".agents/reviews/$(basename "$out")"

# --changes builds on the previous round. What can be refused without the
# content is refused here, before the verification runs.
if [[ "$changes_only" -eq 1 ]]; then
  [[ -n "$previous_review" ]] ||
    fail "--changes needs a previous round, and this is round 1. Run a complete review first."
  previous_errors="$(review_artifact_errors "$previous_review")"
  [[ -z "$previous_errors" ]] ||
    fail "the previous review is invalid, so --changes cannot build on it: ${previous_errors//$'\n'/; }"
  previous_round="$(jq -r '.round' "$previous_review")"
  previous_tree="$(jq -r '.reviewed_tree' "$previous_review")"
  git -C "$root" cat-file -e "$previous_tree^{tree}" 2>/dev/null ||
    fail "the content that round $previous_round reviewed is no longer available, so the changes since then cannot be determined. Run a complete review, without --changes."
  [[ "$(jq -r '.merge_base' "$previous_review")" == "$merge_base" ]] ||
    fail "the base of the branch changed since round $previous_round, so the feature differs in more than your changes. Run a complete review, without --changes."
fi

# A reviewer cannot run the checks, so the review starts only on content that
# passes them. A pass recorded for exactly this content is reused.
tmp_work="$(mktemp -d "${TMPDIR:-/tmp}/review-feature.XXXXXX")"
trap 'rm -rf "$tmp_work"' EXIT

verified_tree=""
if [[ -n "$unverified_reason" ]]; then
  echo "Reviewing without verification: $unverified_reason"
  verification="$(jq -n --arg reason "$unverified_reason" '{status: "not-verified", reason: $reason}')"
else
  echo "Checking that verification passes for the content under review..."
  # The content as it is before the checks run. The review below must cover
  # exactly this content, so a check that changes a file is detected.
  verified_tree="$(fingerprint_worktree "$root" "$tmp_work")" ||
    fail "could not compute the fingerprint of the working tree."
  (cd "$root" && ./scripts/verify.sh --reuse) ||
    fail "verification failed; the review was not started. Fix the failing check, or review anyway with --unverified \"<reason>\"."
  verification="$(jq -n --arg at "$(verification_field "$root" verified-at)" \
    '{status: "passed", verified_at: (if $at == "" then (now | todate) else $at end)}')"
fi
echo

# The reviewer is read-only and has no network access, so the script supplies
# the Issue and the complete diff.
issue_context="$(gh issue view "$issue" \
  --json title,body \
  --template 'Title: {{.title}}{{"\n\n"}}{{.body}}')" ||
  fail "could not read GitHub Issue #$issue."

head_before="$(git -C "$root" rev-parse HEAD)"
# The fingerprint of the reviewed content, including uncommitted and untracked
# files; the diff below is built from the same snapshot.
tree_before="$(fingerprint_worktree "$root" "$tmp_work")" ||
  fail "could not compute the fingerprint of the working tree."
cp "$tmp_work/fingerprint.index" "$tmp_work/index.before"
[[ -z "$verified_tree" || "$tree_before" == "$verified_tree" ]] ||
  fail "the content changed while verification ran, so the pass does not cover what would be reviewed. A check may modify a file; the review was not started."

review_paths=(. ":(exclude).agents/reviews" ":(exclude).agents/triage")
context_file="$tmp_work/context.md"
report_file="$tmp_work/result.json"

if GIT_INDEX_FILE="$tmp_work/index.before" git -C "$root" diff --cached --quiet "$merge_base" -- "${review_paths[@]}"; then
  fail "no changes to review between $base_ref and the working tree."
fi

# A review of changes only builds on the previous round: it needs that round's
# reviewed content and the same base, and something must have changed.
scope='{"kind": "full"}'
if [[ "$changes_only" -eq 1 ]]; then
  ! git -C "$root" diff --quiet "$previous_tree" "$tree_before" ||
    fail "nothing changed since round $previous_round; there is nothing for --changes to review."
  scope="$(jq -n --argjson round "$previous_round" --arg tree "$previous_tree" \
    '{kind: "changes", since_round: $round, base_tree: $tree}')"
fi

if [[ "$changes_only" -eq 1 ]]; then
  # Only an approved triage that belongs to the previous review may tell the
  # reviewer that a finding was deferred or accepted. With any other triage
  # every finding counts as to be fixed.
  previous_triage="$(review_latest_triage "$root" "$previous_review")"
  if [[ -n "$previous_triage" && -n "$(triage_artifact_errors "$previous_triage" "$previous_review")" ]]; then
    echo "Note: ${previous_triage#"$root"/} is not a valid, approved triage of round $previous_round; its decisions are not used."
    previous_triage=""
  fi
  {
    echo "# Review context for Issue #$issue: changes since round $previous_round"
    echo
    echo "## GitHub Issue #$issue"
    echo
    printf '%s\n' "$issue_context"
    echo
    echo "## Findings of round $previous_round and what was decided about them"
    echo
    if [[ "$(jq '.findings | length' "$previous_review")" -eq 0 ]]; then
      echo "Round $previous_round had no findings."
    elif [[ -n "$previous_triage" ]]; then
      jq -r --slurpfile triage "$previous_triage" '
        ($triage[0].decisions | map({(.finding_id): .}) | add // {}) as $decisions
        | .findings[]
        | "### \(.id) [\(.severity)] \(.title)\n\n" +
          "Decision: \($decisions[.id].decision // "none recorded")" +
          (if $decisions[.id].rationale then " (\($decisions[.id].rationale))" else "" end) + "\n\n" +
          "Evidence: \(.evidence)\n\nRecommended action: \(.recommendation)\n"' "$previous_review"
    else
      echo "The findings were not triaged; treat each one as to be fixed."
      echo
      jq -r '.findings[] | "### \(.id) [\(.severity)] \(.title)\n\nEvidence: \(.evidence)\n\nRecommended action: \(.recommendation)\n"' "$previous_review"
    fi
    echo
    echo "## Files changed since round $previous_round"
    echo
    git -C "$root" diff --stat --no-color "$previous_tree" "$tree_before"
    echo
    echo "## Diff since round $previous_round: from the content that round reviewed to the current content"
    echo
    git -C "$root" diff --no-color "$previous_tree" "$tree_before"
  } >"$context_file"
else
  {
    echo "# Review context for Issue #$issue"
    echo
    echo "## GitHub Issue #$issue"
    echo
    printf '%s\n' "$issue_context"
    echo
    echo "## Changed files"
    echo
    GIT_INDEX_FILE="$tmp_work/index.before" git -C "$root" diff --cached --stat --no-color "$merge_base" -- "${review_paths[@]}"
    echo
    echo "## Complete diff against $base_ref, including uncommitted and untracked changes"
    echo
    GIT_INDEX_FILE="$tmp_work/index.before" git -C "$root" diff --cached --no-color "$merge_base" -- "${review_paths[@]}"
  } >"$context_file"
fi

echo "Preparing independent review:"
echo "  Issue:    #$issue"
echo "  Branch:   $branch"
echo "  Base:     $base_ref"
echo "  Agent:    $agent"
echo "  Model:    $model"
echo "  Output:   $review_relative.json"
if [[ -n "$previous_review" ]]; then
  echo "  Previous: .agents/reviews/$(basename "$previous_review")"
fi
if [[ "$changes_only" -eq 1 ]]; then
  echo "  Scope:    only the changes since round $previous_round"
fi
echo

if [[ "$changes_only" -eq 1 ]]; then
  START_PROMPT="Read and follow .agents/prompts/reviewer.md.

Your assigned work item is GitHub Issue #${issue}.

This is a review of changes only: follow the \"Review of changes only\"
section of your contract. Round ${previous_round} reviewed the feature as it
was then. Standard input contains the Issue, the findings of round
${previous_round} with what was decided about each, and the diff from the
content that round reviewed to the current content. Read the files in the
repository for surrounding context.

Read the matching .agents/plans/${issue}-*.md if one exists."
else
  START_PROMPT="Read and follow .agents/prompts/reviewer.md.

Your assigned work item is GitHub Issue #${issue}.

Standard input contains the Issue title and body, the list of changed files,
and the complete diff of the current implementation against ${base_ref},
including uncommitted and untracked changes. Review that complete diff. Read
the files in the repository for surrounding context.

Read the matching .agents/plans/${issue}-*.md if one exists."

  if [[ -n "$previous_review" ]]; then
    START_PROMPT+="

This is a re-review.

Read the previous review (JSON):
.agents/reviews/$(basename "$previous_review")

Check whether its findings have been resolved, but perform an independent review of the complete current implementation. Do not limit the review to the previous findings."
  fi
fi

START_PROMPT+="

You have read-only access. Do not modify, create, or delete any file.
Return the review as JSON that matches the supplied schema. The calling
script validates and stores it."

echo "Starting $agent reviewer ($model) with read-only permissions..."
echo

review_run_reviewer "$agent" "$model" "$root" "$START_PROMPT" "$context_file" "$schema_file" "$report_file" "$tmp_work"

metadata="$(jq -n \
  --argjson issue "$issue" \
  --argjson round "$review_number" \
  --arg branch "$branch" \
  --arg base "$base_ref" \
  --arg merge_base "$merge_base" \
  --arg head "$head_before" \
  --arg tree "$tree_before" \
  --arg agent "$agent" \
  --arg model "$model" \
  --arg created_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --argjson verification "$verification" \
  --argjson scope "$scope" \
  '{
    schema: "review/v1",
    kind: "feature",
    verification: $verification,
    scope: $scope,
    issue: $issue,
    round: $round,
    branch: $branch,
    base: $base,
    merge_base: $merge_base,
    head: $head,
    reviewed_tree: $tree,
    reviewed_paths: null,
    reviewer: {agent: $agent, model: $model},
    created_at: $created_at
  }')"
review_store "$report_file" "$out" "$metadata"
echo "  $review_relative.json  (source of truth)"
echo "  $review_relative.md    (generated report)"
echo
if [[ "$(jq '.findings | length' "$out.json")" -gt 0 ]]; then
  echo "Next: triage the findings:"
  echo "  ./scripts/triage-review.sh $review_relative.json"
else
  echo "Next: the review has no findings; finish the feature:"
  echo "  ./scripts/finish-feature.sh $issue \"<commit summary>\""
fi
