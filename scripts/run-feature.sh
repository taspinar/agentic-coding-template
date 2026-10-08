#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/review-data.sh"

MAX_ROUNDS=5

usage() {
  echo "Usage: $0 <issue-number> [slug] [base-branch] [--implemented]"
  echo
  echo "Runs a feature from its Issue to an open pull request, without questions:"
  echo "start-feature.sh, then review-feature.sh, triage-review.sh, and"
  echo "apply-triage.sh until a review leaves nothing to fix, then finish-feature.sh"
  echo "and publish-feature.sh. Agents run unattended and the triage is approved"
  echo "without you; at most $MAX_ROUNDS review rounds are used, of which the later ones"
  echo "review only the changes since the round before. It never merges and never"
  echo "removes a worktree."
  echo
  echo "The run stops with a non-zero status when a step fails or needs you, and"
  echo "says which command continues. Status 3 means that an agent needs a decision"
  echo "of yours. Running the same command again continues where the feature"
  echo "stands: every step that is already done is skipped."
  echo
  echo "--implemented says that the implementation in the feature worktree is"
  echo "complete, for example after you finished it in a session of your own, so"
  echo "the run continues with the review."
  echo
  echo "Examples:"
  echo "  $0 3"
  echo "  $0 3 site-skeleton develop"
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

implemented=0
arguments=()
for argument in "$@"; do
  case "$argument" in
    --implemented) implemented=1 ;;
    --*) usage ;;
    *) arguments+=("$argument") ;;
  esac
done
[[ "${#arguments[@]}" -ge 1 && "${#arguments[@]}" -le 3 ]] || usage
issue="${arguments[0]}"
[[ "$issue" =~ ^[0-9]+$ ]] || fail "issue number must be numeric: $issue"

review_data_require_jq
command -v gh >/dev/null 2>&1 || fail "GitHub CLI 'gh' is not installed."
repo_root="$(git rev-parse --show-toplevel)"

# find_worktree: prints the worktrees whose branch belongs to the Issue.
find_worktree() {
  git -C "$repo_root" worktree list --porcelain |
    awk -v prefix="refs/heads/feature/${issue}-" '
      /^worktree / { path = substr($0, 10) }
      /^branch / { if (index($2, prefix) == 1) print path }'
}

# stop <status> <reason> <next-command>...
# Ends the run: where it stopped, why, and what continues it.
stop() {
  local status="$1"
  local reason="$2"

  shift 2
  {
    echo
    echo "run-feature.sh stopped: $reason"
    if [[ -n "${worktree:-}" ]]; then
      echo "The feature worktree is kept at: $worktree"
    fi
    if [[ $# -gt 0 ]]; then
      echo "To continue:"
      printf '  %s\n' "$@"
    fi
    echo "Then run again: $0 $issue"
  } >&2
  exit "$status"
}

# step <title> <command>...
# Runs one step of the workflow in the feature worktree and sets step_status.
step() {
  local title="$1"

  shift
  echo
  echo "=== run-feature.sh: $title ==="
  echo
  step_status=0
  (cd "$worktree" && "$@" </dev/null) || step_status=$?
}

# ---------------------------------------------------------------- implement
worktree="$(find_worktree)"
[[ "$(printf '%s\n' "$worktree" | grep -c .)" -le 1 ]] ||
  fail "more than one worktree is on a branch feature/${issue}-*: $(printf '%s' "$worktree" | tr '\n' ' ')"

if [[ -z "$worktree" ]]; then
  [[ "$implemented" -eq 0 ]] || fail "no worktree is on a branch feature/${issue}-*, so nothing is implemented yet."
  echo
  echo "=== run-feature.sh: implementation ==="
  echo
  step_status=0
  (cd "$repo_root" && ./scripts/start-feature.sh "${arguments[@]}" --unattended </dev/null) || step_status=$?
  worktree="$(find_worktree)"
  if [[ "$step_status" -eq 3 ]]; then
    stop 3 "the implementer needs a decision of yours; its question is in the handoff note (.agents/handoffs/$issue.md)." \
      "answer the question in the handoff note, or change the Issue"
  elif [[ "$step_status" -ne 0 ]]; then
    stop 1 "the implementation failed (start-feature.sh exited with status $step_status)." \
      "resolve what the output above reports"
  fi
  first_session=1
else
  [[ "${#arguments[@]}" -eq 1 ]] ||
    fail "the feature already has a worktree ($worktree); run without a slug or base branch to continue it."
  first_session=0
fi

branch="$(git -C "$worktree" branch --show-current)"
base="$(git -C "$worktree" config --get "branch.$branch.workflow-base" || true)"
base="${base:-main}"
state_file="$worktree/.agents/run/$issue-state"

git -C "$worktree" check-ignore -q ".agents/run/$issue-state" ||
  fail "Git does not ignore .agents/run/ in $worktree. Add '.agents/run/' to .gitignore, or take over the template's .gitignore with ./scripts/sync-template.sh."
mkdir -p "$(dirname "$state_file")"

if [[ "$first_session" -eq 1 || "$implemented" -eq 1 ]]; then
  echo "implemented" >"$state_file"
fi

if [[ ! -f "$state_file" ]]; then
  # An earlier run stopped during the implementation, or the worktree was
  # made by hand: the implementer establishes where the work stands.
  step "implementation, resumed" ./scripts/start-feature.sh "$issue" --resume --unattended
  if [[ "$step_status" -eq 3 ]]; then
    stop 3 "the implementer needs a decision of yours; its question is in the handoff note (.agents/handoffs/$issue.md)." \
      "answer the question in the handoff note, or change the Issue"
  elif [[ "$step_status" -ne 0 ]]; then
    stop 1 "the implementation failed (start-feature.sh exited with status $step_status)." \
      "resolve what the output above reports"
  fi
  echo "implemented" >"$state_file"
fi

# ------------------------------------------------------ review, triage, fix
slug="${branch//\//-}"

# latest_review: prints the newest review of the branch, or nothing.
latest_review() {
  local candidate
  local best=""

  for candidate in "$worktree/.agents/reviews/$slug-review-"[0-9][0-9].json; do
    [[ -f "$candidate" ]] || continue
    best="$candidate"
  done
  printf '%s' "$best"
}

# changes_reviewable <review>
# Succeeds when a review of only the changes can build on <review>: the
# branch has the same base as then, and the content it reviewed is known.
changes_reviewable() {
  local base_ref="$base"
  local merge_base

  git -C "$worktree" rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null || base_ref="origin/$base"
  merge_base="$(git -C "$worktree" merge-base HEAD "$base_ref" 2>/dev/null)" || return 1
  [[ "$(jq -r '.merge_base' "$1")" == "$merge_base" ]] || return 1
  git -C "$worktree" cat-file -e "$(jq -r '.reviewed_tree' "$1")^{tree}" 2>/dev/null
}

uncommitted() {
  [[ -n "$(git -C "$worktree" status --porcelain)" ]]
}

if uncommitted; then
  while true; do
    review="$(latest_review)"
    round=0
    current=1
    if [[ -n "$review" ]]; then
      round="$(jq -r '.round' "$review")"
      current=0
      (cd "$worktree" && ./scripts/check-review.sh "$review" >/dev/null 2>&1) || current=$?
      [[ "$current" -ne 2 ]] ||
        stop 1 "the latest review cannot be read: ${review#"$worktree"/}." \
          "cd \"$worktree\" && ./scripts/check-review.sh ${review#"$worktree"/}"
    fi

    if [[ "$current" -ne 0 ]]; then
      # No review yet, or the content changed since the latest one.
      if [[ "$round" -ge "$MAX_ROUNDS" ]]; then
        stop 1 "$MAX_ROUNDS review rounds are used, and the content changed after round $round, so it is not confirmed by a review." \
          "cd \"$worktree\"" \
          "./scripts/review-feature.sh $issue $base    # and continue by hand: triage-review.sh, apply-triage.sh, finish-feature.sh, publish-feature.sh"
      fi
      # A later round reviews the changes since the round before it. That
      # review is given the decisions of that round, so a finding that was
      # deferred or accepted is not reported, triaged, and deferred again.
      # When the base of the branch changed in between, for example by a
      # merge of main, the round reviews the complete feature instead.
      review_options=()
      if [[ -n "$review" ]] && changes_reviewable "$review"; then
        review_options=(--changes)
      fi
      step "review, round $((round + 1)) of at most $MAX_ROUNDS" \
        ./scripts/review-feature.sh "$issue" "$base" ${review_options[@]+"${review_options[@]}"}
      [[ "$step_status" -eq 0 ]] ||
        stop 1 "the review did not complete (review-feature.sh exited with status $step_status): the verification fails, the reviewer failed, or the review was refused." \
          "resolve what the output above reports; when the verification fails, for example with ./scripts/start-feature.sh $issue --resume"
      continue
    fi

    review_relative="${review#"$worktree"/}"
    [[ "$(jq '.findings | length' "$review")" -gt 0 ]] || break

    triage="$(review_latest_triage "$worktree" "$review")"
    if [[ -z "$triage" ]]; then
      step "triage of round $round" ./scripts/triage-review.sh "$review_relative" --unattended
      [[ "$step_status" -eq 0 ]] ||
        stop 1 "the triage of round $round failed (triage-review.sh exited with status $step_status)." \
          "resolve what the output above reports"
      continue
    fi
    triage_relative="${triage#"$worktree"/}"
    if [[ "$(jq 'has("published_at")' "$triage")" != "true" ]]; then
      step "publication of the triage of round $round" ./scripts/triage-review.sh --publish "$triage_relative"
      [[ "$step_status" -eq 0 ]] ||
        stop 1 "the triage of round $round could not be published on the Issue." \
          "cd \"$worktree\"" \
          "./scripts/triage-review.sh --publish $triage_relative"
      continue
    fi

    [[ "$(jq '[.decisions[] | select(.decision == "FIX_NOW")] | length' "$triage")" -gt 0 ]] || break

    if [[ "$round" -ge "$MAX_ROUNDS" ]]; then
      stop 1 "$MAX_ROUNDS review rounds are used and round $round still has findings that must be fixed; see $review_relative." \
        "cd \"$worktree\"" \
        "./scripts/apply-triage.sh $triage_relative    # and continue by hand: review-feature.sh, finish-feature.sh, publish-feature.sh"
    fi
    step "fixes for round $round" ./scripts/apply-triage.sh "$triage_relative" --unattended
    if [[ "$step_status" -eq 3 ]]; then
      # The next run resumes the implementer, which reads the handoff note
      # with the answer before it continues; a review follows.
      rm -f "$state_file"
      stop 3 "the agent that applies the fixes needs a decision of yours; its question is in the handoff note (.agents/handoffs/$issue.md)." \
        "answer the question in the handoff note"
    elif [[ "$step_status" -ne 0 ]]; then
      stop 1 "the fixes for round $round failed (apply-triage.sh exited with status $step_status): the agent failed, or the verification fails after the fixes." \
        "cd \"$worktree\"" \
        "./scripts/verify.sh    # when it fails: fix it, for example with ./scripts/start-feature.sh $issue --resume"
    fi
    if (cd "$worktree" && ./scripts/check-review.sh "$review" >/dev/null 2>&1); then
      stop 1 "the fixes for round $round changed nothing, although the triage has findings to fix." \
        "cd \"$worktree\"" \
        "./scripts/apply-triage.sh $triage_relative"
    fi
  done

  # ---------------------------------------------------------------- finish
  title="$(gh issue view "$issue" --json title --jq '.title' </dev/null)" ||
    stop 1 "could not read the title of Issue #$issue for the commit message." \
      "cd \"$worktree\"" "./scripts/finish-feature.sh $issue \"<commit summary>\""
  step "commit" ./scripts/finish-feature.sh "$issue" "$title" --unattended
  [[ "$step_status" -eq 0 ]] ||
    stop 1 "the feature could not be committed (finish-feature.sh exited with status $step_status)." \
      "cd \"$worktree\"" "./scripts/finish-feature.sh $issue \"$title\""
else
  base_ref="$base"
  git -C "$worktree" rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null || base_ref="origin/$base"
  [[ "$(git -C "$worktree" rev-list --count "$base_ref..HEAD" 2>/dev/null || echo 0)" -gt 0 ]] ||
    stop 1 "the feature worktree has no changes and no commits: nothing was implemented." \
      "./scripts/start-feature.sh $issue --resume"
  echo
  echo "The feature is already committed; continuing with the pull request."
fi

# ------------------------------------------------------------------ publish
step "pull request" ./scripts/publish-feature.sh "$issue"
[[ "$step_status" -eq 0 ]] ||
  stop 1 "the pull request could not be opened (publish-feature.sh exited with status $step_status)." \
    "cd \"$worktree\"" "./scripts/publish-feature.sh $issue"

echo
echo "run-feature.sh is done: the pull request of Issue #$issue is open."
echo "Read it, also the triage decisions that were approved without you, follow its"
echo "checks, and merge it. Then clean up with: ./scripts/cleanup-worktree.sh $issue"
