#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/review-data.sh"
source "$script_dir/lib/fingerprint.sh"
source "$script_dir/lib/completion.sh"

MAX_ROUNDS=5
# A session of the implementer that ends without an error has not completed
# the feature by that alone: the completion gate decides. While it does not
# pass, the implementer is resumed, for at most this many sessions in a run.
MAX_SESSIONS="${RUN_FEATURE_SESSIONS:-4}"
# A step whose agent or connection fails is tried again, with a wait that
# doubles. A verification that fails is repeated once; when it fails again,
# the implementer repairs it, a limited number of times (AGENTS.md).
RETRIES="${RUN_FEATURE_RETRIES:-3}"
RETRY_WAIT="${RUN_FEATURE_RETRY_WAIT:-120}"
MAX_REPAIRS="${RUN_FEATURE_REPAIRS:-3}"
MAX_UNSTABLE=3
repairs=0
unstable=0

usage() {
  echo "Usage: $0 <issue-number> [slug] [base-branch] [--implemented]"
  echo
  echo "Runs a feature from its Issue to an open pull request, without questions:"
  echo "start-feature.sh, then review-feature.sh, triage-review.sh, and"
  echo "apply-triage.sh until a review leaves nothing to fix, then finish-feature.sh"
  echo "and publish-feature.sh. Agents run unattended and the triage is approved"
  echo "without you; at most $MAX_ROUNDS review rounds are used, of which the later ones"
  echo "review only the changes since the round before, and the last one reviews the"
  echo "complete feature again. It never merges and never removes a worktree."
  echo
  echo "The review starts only when the completion gate passes: the implementer's"
  echo "completion record says complete, its handoff note lists no remaining work,"
  echo "and it wrote the summary of the changes. Until then the implementer is"
  echo "resumed, for at most $MAX_SESSIONS sessions in a run."
  echo
  echo "The run stops with a non-zero status when a step fails or needs you, and"
  echo "says which command continues. Status 3 means that an agent needs a decision"
  echo "of yours. Running the same command again continues where the feature"
  echo "stands: every step that is already done is skipped."
  echo
  echo "--implemented says that the implementation in the feature worktree is"
  echo "complete, for example after you finished it in a session of your own, so"
  echo "the run continues with the review without a session of the implementer."
  echo "The completion gate has to pass for that too."
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

# note <step> <outcome> <reason> <action>
# Adds one line to the log of the feature, .agents/run/<issue>-log, and shows
# it. The outcome is decided here, from exit statuses and check results.
note() {
  local line

  line="$(date -u +'%Y-%m-%dT%H:%M:%SZ') | $1 | $2 | $3 | $4"
  echo "run-feature.sh: $2 in '$1': $3. $4"
  if [[ -n "${worktree:-}" && -d "$worktree/.agents" ]]; then
    mkdir -p "$worktree/.agents/run"
    printf '%s\n' "$line" >>"$worktree/.agents/run/$issue-log"
  fi
}

# open_question
# Succeeds when the handoff note of the feature holds a question under
# 'Open questions'. An agent that ends with BLOCKED has to record its
# question there; without one there is nothing for the human to answer.
open_question() {
  local note_file="$worktree/.agents/handoffs/$issue.md"

  [[ -f "$note_file" ]] || return 1
  awk '
    tolower($0) ~ /open questions?/ {
      found = 1
      line = $0
      sub(/.*[Oo]pen [Qq]uestions?[*: ]*/, "", line)
      text = line
      next
    }
    found && /^[[:space:]]*$/ { if (text != "") exit; next }
    found && /^#/ { exit }
    found { text = text " " $0 }
    END {
      gsub(/^[[:space:]*:-]+|[[:space:].]+$/, "", text)
      if (text == "" || tolower(text) ~ /^(none|no |n\/a|nothing)/) exit 1
      exit 0
    }' "$note_file"
}

# failing_checks <verification-output>
# Prints the names of the checks that a verification run reports as failed.
failing_checks() {
  [[ -f "$1" ]] || return 0
  awk '$1 == "FAIL" { print $2 }' "$1" | sort -u
}

# retrying <title> <command>...
# Runs a command in the feature worktree and keeps its output in
# .agents/run/<issue>-step.log. A failure that is not a blocked session and
# not a failed verification counts as temporary: an agent or a connection
# failed. It is tried again RETRIES times, with a wait that doubles. Sets
# step_status to the status of the last attempt.
#
# When STEP_CONTINUE is set and the content changed since the review in
# STEP_REVIEW, the command is repeated with --continue: the fix session had
# started from that review, which is stale now, and apply-triage.sh takes up
# an interrupted session of the same triage only when it is told to.
retrying() {
  local title="$1"
  local attempt=0
  local wait="$RETRY_WAIT"
  local log

  shift
  while true; do
    echo
    echo "=== run-feature.sh: $title ==="
    echo
    log="$worktree/.agents/run/$issue-step.log"
    mkdir -p "$(dirname "$log")"
    step_status=0
    (cd "$worktree" && "$@" </dev/null) 2>&1 | tee "$log" || step_status=$?
    case "$step_status" in
      0 | 3 | 4) return 0 ;;
      5)
        # An agent changed the review or the triage it works from: not a
        # failure that a retry may pass over.
        note "$title" "failed" "an agent changed the review or the approved triage" "Stopping; nothing is tried again"
        return 0
        ;;
    esac
    if [[ "$attempt" -ge "$RETRIES" ]]; then
      note "$title" "failed" "the step exited with status $step_status, also after $attempt retries" "Stopping"
      return 0
    fi
    attempt=$((attempt + 1))
    if [[ -n "${STEP_REVIEW:-}" ]] && ! (cd "$worktree" && ./scripts/check-review.sh "$STEP_REVIEW" >/dev/null 2>&1); then
      note "$title" "temporary" "the step exited with status $step_status after it had changed the content" "Continuing the interrupted session with the same scope, retry $attempt of $RETRIES in $wait seconds"
      STEP_REVIEW=""
      title="$title, continued"
      set -- "$@" --continue
    else
      note "$title" "temporary" "the step exited with status $step_status" "Retry $attempt of $RETRIES in $wait seconds"
    fi
    sleep "$wait"
    wait=$((wait * 2))
  done
}

# blocked_or_ignored <title>
# Called when a session ended with status 3. A blocked session counts only
# with a question in the handoff note; otherwise step_status becomes 0.
blocked_or_ignored() {
  if open_question; then
    note "$1" "blocked" "an agent needs a decision; its question is in the handoff note" "Stopping"
  else
    note "$1" "completed" "the agent ended with BLOCKED, but the handoff note holds no open question" "Going on"
    step_status=0
  fi
}

# repair_verification <step-title>
# Called when the verification failed in a step. Repeats it once and compares
# the checks that failed in both runs. A check that failed only once is
# unstable: it is recorded, and the run goes on. For the checks that failed
# twice the implementer is resumed with their names in the handoff note, at
# most MAX_REPAIRS times. Sets step_status to 0 when the run can go on, to 4
# when the verification cannot be repaired here, and to the status of the
# repair session when that failed or is blocked.
repair_verification() {
  local title="$1"
  local first_log="$worktree/.agents/run/$issue-step.log"
  local log="$worktree/.agents/run/$issue-verify.log"
  local first
  local second
  local twice
  local once
  local repeat_status=0

  first="$(failing_checks "$first_log")"
  mkdir -p "$(dirname "$log")"
  (cd "$worktree" && ./scripts/verify.sh) >"$log" 2>&1 || repeat_status=$?
  second="$(failing_checks "$log")"
  twice="$(comm -12 <(printf '%s\n' "$first") <(printf '%s\n' "$second") | grep . || true)"
  once="$(comm -3 <(printf '%s\n' "$first") <(printf '%s\n' "$second") | tr -d '\t' | grep . | tr '\n' ' ' || true)"

  if [[ "$repeat_status" -eq 0 || ( -z "$twice" && -n "$second" && -n "$first" ) ]]; then
    unstable=$((unstable + 1))
    if [[ "$unstable" -gt "$MAX_UNSTABLE" ]]; then
      note "$title" "failed" "checks failed in one verification run and not in the next, for the $unstable. time: $once" "Stopping: the checks are too unstable to rely on"
      step_status=4
      return 0
    fi
    note "$title" "temporary" "unstable checks, failed in one of two verification runs: ${once:-unknown}" "Going on; the step is done again"
    step_status=0
    return 0
  fi
  # Without names from the first run, every check of the second counts.
  [[ -n "$twice" ]] || twice="$second"
  if [[ "$repairs" -ge "$MAX_REPAIRS" ]]; then
    note "$title" "failed" "the verification fails after $repairs repair attempts: $(printf '%s' "$twice" | tr '\n' ' ')" "Stopping"
    step_status=4
    return 0
  fi
  repairs=$((repairs + 1))
  note "$title" "failed" "checks failed in two verification runs: $(printf '%s' "$twice" | tr '\n' ' ')${once:+; unstable, failed once: $once}" "Repair attempt $repairs of $MAX_REPAIRS by the implementer"
  mkdir -p "$worktree/.agents/handoffs"
  {
    echo
    echo "## Verification failed ($(date -u +'%Y-%m-%dT%H:%M:%SZ'), recorded by run-feature.sh)"
    echo
    echo "./scripts/verify.sh fails on the content as it is. These checks failed in two"
    echo "runs; repair them. The complete output is in .agents/run/$issue-verify.log."
    echo "Repair attempt $repairs of $MAX_REPAIRS."
    echo
    printf '%s\n' "${twice:-(no check named; read the log)}" | sed 's/^/- FAIL /'
    [[ -z "$once" ]] || echo "Failed in one run only, so probably unstable and not yours to repair: $once"
  } >>"$worktree/.agents/handoffs/$issue.md"
  retrying "repair of the verification, attempt $repairs of $MAX_REPAIRS" \
    ./scripts/start-feature.sh "$issue" --resume --unattended
  case "$step_status" in
    0) ;;
    3) blocked_or_ignored "repair of the verification" ;;
    4) step_status=1 ;;
  esac
}

# step <title> <command>...
# Runs one step of the workflow in the feature worktree and decides its
# outcome from its exit status. Sets step_status: 0 when the run can go on,
# 3 when an agent needs a decision of the human, 4 when the verification
# cannot be repaired, and another status when the step failed for good.
#
#   0      completed
#   3      blocked, when the handoff note holds an open question; otherwise
#          the BLOCKED line is ignored and the step counts as completed
#   4      the verification failed: repeated once, then repaired
#   other  temporary: tried again, RETRIES times, with a growing wait
step() {
  local title="$1"

  retrying "$@"
  case "$step_status" in
    3) blocked_or_ignored "$title" ;;
    4) repair_verification "$title" ;;
  esac
}

# step_once <title> <command>...
# Runs a step that is not tried again, because its failure is a refusal that
# a retry does not change. Sets step_status.
step_once() {
  local title="$1"

  shift
  echo
  echo "=== run-feature.sh: $title ==="
  echo
  step_status=0
  (cd "$worktree" && "$@" </dev/null) || step_status=$?
  [[ "$step_status" -eq 0 ]] || note "$title" "failed" "the step exited with status $step_status" "Stopping"
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
  first_session=1
  if [[ "$step_status" -eq 3 ]]; then
    if open_question; then
      note "implementation" "blocked" "the implementer needs a decision; its question is in the handoff note" "Stopping"
      stop 3 "the implementer needs a decision of yours; its question is in the handoff note (.agents/handoffs/$issue.md)." \
        "answer the question in the handoff note, or change the Issue"
    fi
    note "implementation" "completed" "the implementer ended with BLOCKED, but the handoff note holds no open question" "Going on"
  elif [[ "$step_status" -ne 0 ]]; then
    [[ -n "$worktree" ]] ||
      stop 1 "the implementation failed before a worktree existed (start-feature.sh exited with status $step_status)." \
        "resolve what the output above reports"
    # The session failed, for example on a usage limit: the resumed session
    # below is tried again, with a growing wait.
    note "implementation" "temporary" "start-feature.sh exited with status $step_status" "Resuming the implementer"
    first_session=0
  fi
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

# The completion gate. The state 'implemented' is written only when it
# passes; an implementer that stopped partway is resumed with the reasons in
# its handoff note. A missing state after an earlier run means that a session
# has to establish where the work stands before the gate is asked.
#
# await_completion <resume-first>
# Returns when the gate passes. Until then it resumes the implementer, for at
# most MAX_SESSIONS sessions in a run, and stops the run when the record says
# blocked or the sessions are used. With <resume-first> 1 a session runs
# before the gate is asked. It is called before the first review and again
# before every later one: a session that repairs the verification is a
# session of the implementer too, and may leave the work partial or blocked.
sessions="$first_session"
await_completion() {
  local resume_first="$1"
  local gate
  local gate_status
  local gate_reasons
  local gate_summary

  while true; do
    if [[ "$resume_first" -eq 0 ]]; then
      gate="$(completion_gate "$worktree" "$issue")"
      gate_status="$(printf '%s\n' "$gate" | sed -n 1p)"
      gate_reasons="$(printf '%s\n' "$gate" | sed 1d)"
      if [[ "$gate_status" == "complete" ]] && ! completion_summary_present "$worktree" "$issue"; then
        # Nobody edits the commit message of this run, so the summary of the
        # changes has to come from the implementer.
        gate_status="no summary"
        gate_reasons="the implementer wrote no summary of the changes (.agents/summaries/$issue.md)"
      fi
      gate_summary="$(printf '%s' "$gate_reasons" | tr '\n' ';' | sed 's/;/; /g')"
      case "$gate_status" in
        complete)
          echo "implemented" >"$state_file"
          return 0
          ;;
        blocked)
          rm -f "$state_file"
          note "implementation" "blocked" "the completion record says blocked: $gate_summary" "Stopping"
          stop 3 "the implementer reports that it cannot complete the Issue without you: $gate_summary" \
            "read the handoff note (.agents/handoffs/$issue.md) and the completion record ($COMPLETION_DIR/$issue.json); answer in the handoff note, or change the Issue"
          ;;
      esac
      rm -f "$state_file"
      if [[ "$implemented" -eq 1 ]]; then
        stop 1 "--implemented was given, but the completion gate does not pass ($gate_status): $gate_summary" \
          "write the completion record and the summary as .agents/prompts/implementer.md describes under 'Completion', or run without --implemented to let the implementer establish them"
      fi
      if [[ "$sessions" -ge "$MAX_SESSIONS" ]]; then
        note "implementation" "failed" "not complete after $sessions sessions of the implementer ($gate_status): $gate_summary" "Stopping"
        stop 1 "the implementer ended $sessions sessions without completing the Issue ($gate_status): $gate_summary" \
          "cd \"$worktree\"" \
          "./scripts/start-feature.sh $issue --resume    # or split the Issue; nothing was reviewed or committed"
      fi
      note "implementation" "not complete" "$gate_status: $gate_summary" "Resuming the implementer, session $((sessions + 1)) of at most $MAX_SESSIONS"
      mkdir -p "$worktree/.agents/handoffs"
      {
        echo
        echo "## Not complete ($(date -u +'%Y-%m-%dT%H:%M:%SZ'), recorded by run-feature.sh)"
        echo
        echo "The session ended, but the completion gate does not pass ($gate_status):"
        echo
        # Not as a list under a 'Remaining' label: the gate reads the note.
        printf '%s\n' "$gate_reasons" | sed 's/^/- gate: /'
        echo
        echo "Continue the work on the Issue. Nothing is reviewed or committed before"
        echo "$COMPLETION_DIR/$issue.json says complete with evidence for every acceptance"
        echo "criterion, the list of what is left in this note is empty, and"
        echo ".agents/summaries/$issue.md exists (.agents/prompts/implementer.md,"
        echo "'Completion'). When the Issue cannot be completed without a decision of the"
        echo "human, record the status 'blocked'."
      } >>"$worktree/.agents/handoffs/$issue.md"
    fi
    resume_first=0
    sessions=$((sessions + 1))
    step "implementation, session $sessions" ./scripts/start-feature.sh "$issue" --resume --unattended
    if [[ "$step_status" -eq 3 ]]; then
      stop 3 "the implementer needs a decision of yours; its question is in the handoff note (.agents/handoffs/$issue.md)." \
        "answer the question in the handoff note, or change the Issue"
    elif [[ "$step_status" -ne 0 ]]; then
      stop 1 "the implementation failed (start-feature.sh exited with status $step_status)." \
        "resolve what the output above reports"
    fi
  done
}

resume_first=0
[[ -f "$state_file" || "$first_session" -eq 1 || "$implemented" -eq 1 ]] || resume_first=1
await_completion "$resume_first"

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
  local merge_base

  # The same base as review-feature.sh uses.
  merge_base="$(feature_base "$worktree" "$base" | sed -n 2p)"
  [[ -n "$merge_base" ]] || return 1
  [[ "$(jq -r '.merge_base' "$1")" == "$merge_base" ]] || return 1
  git -C "$worktree" cat-file -e "$(jq -r '.reviewed_tree' "$1")^{tree}" 2>/dev/null
}

uncommitted() {
  [[ -n "$(git -C "$worktree" status --porcelain)" ]]
}

# changes_only <review>
# Succeeds when a review covered only the changes since an earlier round.
changes_only() {
  [[ "$(jq -r '.scope.kind // "full"' "$1")" == "changes" ]]
}

# The round that ends the run reviews the complete feature against the Issue,
# also when the rounds before it reviewed only changes: a review of changes
# confirms fixes, it does not establish that the Issue is done.
complete_review=0
if uncommitted; then
  while true; do
    # A repair session may have left the work partial or blocked.
    await_completion 0
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

    if [[ "$current" -ne 0 || "$complete_review" -eq 1 ]]; then
      # No review yet, the content changed since the latest one, or the
      # latest one covered only changes and nothing is left to fix.
      if [[ "$round" -ge "$MAX_ROUNDS" && "$complete_review" -eq 1 ]]; then
        stop 1 "$MAX_ROUNDS review rounds are used, and round $round reviewed only changes, so no review of the complete feature confirms that the Issue is done." \
          "cd \"$worktree\"" \
          "./scripts/review-feature.sh $issue $base    # and continue by hand: triage-review.sh, apply-triage.sh, finish-feature.sh, publish-feature.sh"
      fi
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
      review_title="review"
      if [[ "$complete_review" -eq 1 ]]; then
        review_title="review of the complete feature"
      elif [[ -n "$review" ]] && changes_reviewable "$review"; then
        review_options=(--changes)
      fi
      complete_review=0
      step "$review_title, round $((round + 1)) of at most $MAX_ROUNDS" \
        ./scripts/review-feature.sh "$issue" "$base" ${review_options[@]+"${review_options[@]}"}
      if [[ "$step_status" -eq 3 ]]; then
        rm -f "$state_file"
        stop 3 "the implementer, repairing the verification, needs a decision of yours; its question is in the handoff note (.agents/handoffs/$issue.md)." \
          "answer the question in the handoff note"
      elif [[ "$step_status" -eq 4 ]]; then
        stop 1 "the verification still fails; the failing checks are in .agents/run/$issue-verify.log and in the log of the run, .agents/run/$issue-log." \
          "cd \"$worktree\"" \
          "./scripts/verify.sh    # repair what fails, for example with ./scripts/start-feature.sh $issue --resume"
      elif [[ "$step_status" -ne 0 ]]; then
        stop 1 "the review did not complete (review-feature.sh exited with status $step_status, also after the retries): the reviewer failed, or the review was refused." \
          "resolve what the output above reports"
      fi
      continue
    fi

    review_relative="${review#"$worktree"/}"
    if [[ "$(jq '.findings | length' "$review")" -eq 0 ]]; then
      changes_only "$review" || break
      complete_review=1
      continue
    fi

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

    if [[ "$(jq '[.decisions[] | select(.decision == "FIX_NOW")] | length' "$triage")" -eq 0 ]]; then
      changes_only "$review" || break
      complete_review=1
      continue
    fi

    if [[ "$round" -ge "$MAX_ROUNDS" ]]; then
      stop 1 "$MAX_ROUNDS review rounds are used and round $round still has findings that must be fixed; see $review_relative." \
        "cd \"$worktree\"" \
        "./scripts/apply-triage.sh $triage_relative    # and continue by hand: review-feature.sh, finish-feature.sh, publish-feature.sh"
    fi
    # An interrupted fix session is continued with its scope, not started
    # again: apply-triage.sh refuses a review whose content changed.
    STEP_REVIEW="$review"
    step "fixes for round $round" ./scripts/apply-triage.sh "$triage_relative" --unattended
    STEP_REVIEW=""
    if [[ "$step_status" -eq 3 ]]; then
      # The next run resumes the implementer, which reads the handoff note
      # with the answer before it continues; a review follows.
      rm -f "$state_file"
      stop 3 "the agent that applies the fixes needs a decision of yours; its question is in the handoff note (.agents/handoffs/$issue.md)." \
        "answer the question in the handoff note"
    elif [[ "$step_status" -eq 4 ]]; then
      stop 1 "the verification still fails after the fixes for round $round; the failing checks are in .agents/run/$issue-verify.log and in the log of the run, .agents/run/$issue-log." \
        "cd \"$worktree\"" \
        "./scripts/verify.sh    # repair what fails, for example with ./scripts/start-feature.sh $issue --resume"
    elif [[ "$step_status" -eq 5 ]]; then
      stop 1 "the agent that applies the fixes changed the review or the approved triage of round $round, which it may only read. Nothing was tried again." \
        "cd \"$worktree\"" \
        "git status    # look at what the session changed; restore the review and the triage, or review again"
    elif [[ "$step_status" -ne 0 ]]; then
      stop 1 "the fixes for round $round failed (apply-triage.sh exited with status $step_status, also after the retries)." \
        "resolve what the output above reports"
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
  step_once "commit" ./scripts/finish-feature.sh "$issue" "$title" --unattended
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
if git -C "$worktree" log -1 --format=%b | grep -Fqx -- "- required from the project owner, for exactly this commit"; then
  echo
  echo "MERGE APPROVAL REQUIRED. This pull request changes what only the owner may"
  echo "approve; the reasons are in its description. Nothing may merge it for you:"
  echo "read it and merge it yourself. A queue that merges pull requests skips it."
  echo
fi
echo "Read it, also the triage decisions that were approved without you, follow its"
echo "checks, and merge it. Then clean up with: ./scripts/cleanup-worktree.sh $issue"
