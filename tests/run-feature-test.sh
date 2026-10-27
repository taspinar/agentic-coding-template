#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/run-feature-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "run-feature test failed: $*" >&2
  exit 1
}

source "$source_root/tests/lib-fakes.sh"
make_fake_agents "$tmp/bin"

# A fake agent that plays every role of a feature. The role follows from how
# the scripts start it. Per role, the control directory of a test may hold
# '<role>-<n>.sh' for the n-th session of that role, or '<role>.sh' for all
# of them: a script that runs in the agent's working directory and sets
# 'reply', the final message. Without one, the role does its work well.
cat >"$tmp/bin/codex" <<'AGENT'
#!/usr/bin/env bash
set -euo pipefail

out=""
schema=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --output-last-message) out="${args[$((i + 1))]}" ;;
    --output-schema) schema="${args[$((i + 1))]}" ;;
  esac
done

case "$schema:$out" in
  *review.schema.json:*) role=reviewer ;;
  *triage.schema.json:*) role=triage ;;
  :*-implementer.md) role=implementer ;;
  :*-fixes.md) role=fixes ;;
  *)
    echo "The fake agent does not know this session: $*" >&2
    exit 98
    ;;
esac

# completion <status> [remaining]: the implementer's completion record of the
# Issue, as the implementer contract describes it.
completion() {
  local remaining='[]'
  local met="met"

  if [[ "$1" != "complete" ]]; then
    remaining="[\"${2:-Plan steps 3 to 9}\"]"
    met="not_met"
  fi
  mkdir -p .agents/completion
  printf '{"schema": "completion/v1", "status": "%s", "criteria": [{"criterion": "The feature file exists", "status": "%s", "evidence": "feature.txt"}], "remaining": %s}\n' \
    "$1" "$met" "$remaining" >".agents/completion/$RUN_ISSUE.json"
}

count="$(($(cat "$RUN_CONTROL/$role.count" 2>/dev/null || echo 0) + 1))"
echo "$count" >"$RUN_CONTROL/$role.count"
printf '%s\n' "$*" >>"$RUN_CONTROL/$role.args"
# A read-only session gets its context on standard input.
[[ -z "$schema" ]] || cat >"$RUN_CONTROL/$role-$count.context"

case "$role" in
  implementer)
    default='printf "feature\n" >>feature.txt
mkdir -p .agents/summaries
printf -- "- Adds the feature file.\n" >".agents/summaries/$RUN_ISSUE.md"
completion complete
reply="The feature is implemented."'
    ;;
  reviewer) default='reply="{\"architecture_impact\": {\"level\": \"minor\", \"rationale\": \"Stays within the accepted architecture.\", \"checked_against\": []}, \"verdict\": \"PASS\", \"limitations\": \"\", \"findings\": []}"' ;;
  triage)
    default='reply="{\"decisions\": [
  {\"finding_id\": \"M1\", \"decision\": \"FIX_NOW\", \"rationale\": \"It is wrong.\", \"followup\": null},
  {\"finding_id\": \"MIN1\", \"decision\": \"DEFER\", \"rationale\": \"Later.\", \"followup\": {\"title\": \"Rename it\", \"recommended_action\": \"Rename.\", \"acceptance_criteria\": [\"Renamed.\"]}}
]}"'
    ;;
  fixes) default='printf "fixed\n" >>feature.txt
reply="The findings are fixed."' ;;
esac

reply=""
if [[ -f "$RUN_CONTROL/$role-$count.sh" ]]; then
  source "$RUN_CONTROL/$role-$count.sh"
elif [[ -f "$RUN_CONTROL/$role.sh" ]]; then
  source "$RUN_CONTROL/$role.sh"
else
  eval "$default"
fi
printf '%s\n' "$reply" >"$out"
AGENT
chmod +x "$tmp/bin/codex"

cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$RUN_CONTROL/gh.log"
case "${1:-} ${2:-}" in
  "auth status") ;;
  "issue view")
    [[ ! -e "$RUN_CONTROL/gh-fails" ]] || exit 1
    # gh-title-flaky holds how many reads of the title fail on the connection.
    if [[ "$*" == *"--json title"* && -s "$RUN_CONTROL/gh-title-flaky" ]]; then
      left="$(cat "$RUN_CONTROL/gh-title-flaky")"
      if [[ "$left" -gt 0 ]]; then
        echo $((left - 1)) >"$RUN_CONTROL/gh-title-flaky"
        echo "net/http: TLS handshake timeout" >&2
        exit 1
      fi
    fi
    case "$*" in
      *"--json number"*) echo "$3" ;;
      *"--json title"*) echo "F02 — Feature file" ;;
      *) printf 'Title: F02 — Feature file\n\nThe feature file exists.\n' ;;
    esac
    ;;
  "issue comment" | "issue list" | "pr edit") ;;
  "issue create") echo "https://github.com/example/project/issues/123" ;;
  "pr list") ;;
  "pr create")
    [[ ! -e "$RUN_CONTROL/pr-fails" ]] || exit 1
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
      if [[ "${args[$i]}" == "--body-file" ]]; then cp "${args[$((i + 1))]}" "$RUN_CONTROL/pr-body"; fi
    done
    echo "https://github.com/example/project/pull/7"
    ;;
  "pr view") echo "main" ;;
  "api repos/{owner}/{repo}/rules/branches/main") echo "1" ;;
  "api repos/"*"/comments") exec "$(dirname "$0")/gh-comments" "$@" ;;
  *)
    echo "Unexpected gh invocation: $*" >&2
    exit 97
    ;;
esac
GH
chmod +x "$tmp/bin/gh"

# Creates a project with a remote and prints the path of its clone. The
# control directory of its fake agents and GitHub is '<clone>.control'.
setup_repo() {
  local label="$1"
  local seed="$tmp/$label-seed"
  local remote="$tmp/$label-remote.git"
  local repo="$tmp/$label"

  mkdir -p "$seed" "$repo.control"
  copy_workflow "$seed"
  cp "$source_root/.gitignore" "$seed/.gitignore"
  printf 'implementer: codex model-i\nreviewer: codex model-r\ntriage: codex model-t\ntriage-implementer: codex model-f\n' \
    >"$seed/.agents/agents.conf"
  printf '%s\n' "${VERIFY_CONF:-sound: test ! -e broken.txt}" >"$seed/scripts/verify.conf"
  printf '# Agents\n' >"$seed/AGENTS.md"
  git -C "$seed" init -q -b main
  git -C "$seed" config user.name "Run Feature Test"
  git -C "$seed" config user.email "run-feature-test@example.com"
  git -C "$seed" add .
  git -C "$seed" commit -qm "Seed"
  git init -q --bare -b main "$remote"
  git -C "$seed" push -q "$remote" main
  git clone -q "$remote" "$repo"
  git -C "$repo" config user.name "Run Feature Test"
  git -C "$repo" config user.email "run-feature-test@example.com"
  printf '%s\n' "$repo"
}

# run_feature <repo> <argument...>: sets 'status' to the exit status.
run_feature() {
  local repo="$1"

  shift
  status=0
  (
    cd "$repo"
    PATH="$tmp/bin:/usr/bin:/bin" RUN_CONTROL="$repo.control" RUN_ISSUE="${1:-}" GIT_EDITOR=false \
      RUN_FEATURE_RETRY_WAIT=0 START_FEATURE_GH_WAIT=0 \
      ./scripts/run-feature.sh "$@" </dev/null
  ) >"$repo.out" 2>&1 || status=$?
}

# sessions <repo> <role>: how often a role was started.
sessions() {
  cat "$1.control/$2.count" 2>/dev/null || echo 0
}

expect_sessions() {
  local repo="$1"
  local role

  shift
  for role in implementer reviewer triage fixes; do
    [[ "$(sessions "$repo" "$role")" -eq "$1" ]] ||
      fail "$(basename "$repo"): $role ran $(sessions "$repo" "$role") time(s) instead of $1"
    shift
  done
}

pull_requests() {
  grep -c '^pr create' "$1.control/gh.log" 2>/dev/null || true
}

# A run that stopped left the feature for the human: nothing is committed,
# nothing is pushed, and the output says how to go on.
expect_stopped() {
  local repo="$1"
  local expected="$2"
  local reason="$3"

  [[ "$status" -eq "$expected" ]] || {
    cat "$repo.out" >&2
    fail "$(basename "$repo"): exited with $status instead of $expected"
  }
  grep -Fq "run-feature.sh stopped: " "$repo.out" || fail "$(basename "$repo"): the stop was not reported"
  grep -Fq "$reason" "$repo.out" || {
    cat "$repo.out" >&2
    fail "$(basename "$repo"): the reason was not given: $reason"
  }
  grep -Fq "Then run again: ./scripts/run-feature.sh 2" "$repo.out" ||
    fail "$(basename "$repo"): the command that continues was not given"
  [[ "$(pull_requests "$repo")" -eq 0 ]] || fail "$(basename "$repo"): a stopped run opened a pull request"
  [[ -d "$repo-2-thing" ]] || fail "$(basename "$repo"): the worktree of a stopped run is gone"
}

expect_published() {
  local repo="$1"

  [[ "$status" -eq 0 ]] || {
    cat "$repo.out" >&2
    fail "$(basename "$repo"): the run failed with status $status"
  }
  [[ "$(pull_requests "$repo")" -ge 1 ]] || fail "$(basename "$repo"): no pull request was opened"
  git -C "$repo" ls-remote --exit-code --heads origin feature/2-thing >/dev/null 2>&1 ||
    fail "$(basename "$repo"): the feature branch was not pushed"
  [[ -z "$(git -C "$repo-2-thing" status --porcelain)" ]] || fail "$(basename "$repo"): the feature is not committed"
  # It never merges, never pushes to main, and never removes the worktree.
  [[ "$(git -C "$repo" ls-remote origin main | cut -f1)" == "$(git -C "$repo" rev-parse origin/main)" ]] ||
    fail "$(basename "$repo"): main changed on the remote"
  if grep -Eq '^pr merge|--delete' "$repo.control/gh.log"; then fail "$(basename "$repo"): the run merged or deleted"; fi
  [[ -d "$repo-2-thing" ]] || fail "$(basename "$repo"): the worktree was removed"
}

major_and_minor='reply="{\"architecture_impact\": {\"level\": \"minor\", \"rationale\": \"Stays within the accepted architecture.\", \"checked_against\": []}, \"verdict\": \"CHANGES_REQUIRED\", \"limitations\": \"\", \"findings\": [
  {\"severity\": \"major\", \"title\": \"Wrong content\", \"evidence\": \"feature.txt:1\", \"impact\": \"Bug.\", \"recommendation\": \"Fix.\"},
  {\"severity\": \"minor\", \"title\": \"Vague name\", \"evidence\": \"feature.txt:1\", \"impact\": \"Unclear.\", \"recommendation\": \"Rename.\"}
]}"'

only_major='reply="{\"architecture_impact\": {\"level\": \"minor\", \"rationale\": \"Stays within the accepted architecture.\", \"checked_against\": []}, \"verdict\": \"CHANGES_REQUIRED\", \"limitations\": \"\", \"findings\": [
  {\"severity\": \"major\", \"title\": \"Still wrong\", \"evidence\": \"feature.txt:1\", \"impact\": \"Bug.\", \"recommendation\": \"Fix.\"}
]}"'
fix_major='if [[ "$count" -eq 1 ]]; then eval "$default"; else
  reply="{\"decisions\": [{\"finding_id\": \"M1\", \"decision\": \"FIX_NOW\", \"rationale\": \"It is wrong.\", \"followup\": null}]}"
fi'

# One command takes an Issue to an open pull request: a review without
# findings needs no triage and no fixes.
repo="$(setup_repo clean)"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 1 0 0
grep -Fq -- "--sandbox workspace-write" "$repo.control/implementer.args" || fail "the implementer did not run in the sandbox"
grep -Fqx "F02 — Feature file" <<<"$(git -C "$repo-2-thing" log -1 --format=%s)" || fail "the commit is not named after the Issue"
grep -Fqx -- "- Adds the feature file." <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" ||
  fail "the commit message lacks the implementer's summary"

# The pull request closes the Issue, because the completion gate passed: the
# commit carries the statement of the implementer's record.
grep -Fqx "Completion: complete" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" ||
  fail "the commit does not carry the completion statement"
grep -Fqx "Closes #2" "$repo.control/pr-body" || fail "the pull request of a complete feature does not close the Issue"
if grep -Fq -- "--draft" "$repo.control/gh.log"; then fail "the pull request of a complete feature is a draft"; fi
grep -Fq "## Completion record of the implementer" "$repo.control/reviewer-1.context" ||
  fail "the reviewer was not given the completion record"
grep -Fq '"status": "complete"' "$repo.control/reviewer-1.context" || fail "the reviewer was not shown what the record says"
grep -Fq "not evidence" "$repo.control/reviewer-1.context" || fail "the reviewer was not told that the record is a claim"

if grep -Fq "MERGE APPROVAL REQUIRED" "$repo.out"; then fail "ordinary work was reported as needing the owner's approval"; fi
grep -Fqx -- "- not required" <<<"$(git -C "$repo-2-thing" log -1 --format=%B | grep -A1 -Fx "Merge approval:")" ||
  fail "the commit does not record that no approval is needed"

# The risk level is printed when the feature starts and before the review,
# the reviewer is told, the commit records it, and the run record notes it.
grep -Fq "run-feature.sh: risk level at the start: medium" "$repo.out" || fail "the risk level was not printed when the feature started"
grep -Fq "run-feature.sh: risk level before round 1: medium" "$repo.out" || fail "the risk level was not printed before the review"
grep -Fq "## Risk level" "$repo.control/reviewer-1.context" || fail "the reviewer was not told the risk level"
grep -Fqx "Risk: medium" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" || fail "the commit does not record the risk level"
cat "$repo"/.agents/run/records/*.jsonl | jq -e -s 'any(.type == "risk" and .level == "medium" and (.reasons | length) >= 1)' >/dev/null ||
  fail "the risk level is not in the run records"

# A finished feature is not run again: a repeated command only publishes.
run_feature "$repo" 2
expect_published "$repo"
expect_sessions "$repo" 1 1 0 0

# The completion gate. A session of the implementer that ends without an
# error has not completed the feature by that alone: the run goes on to the
# review only when the completion record says complete, the handoff note
# lists nothing that remains, and the summary of the changes exists.
# Otherwise the implementer is resumed with the reason in its handoff note.
#
# The case of the bug this guards against: the implementer stopped after two
# of nine plan steps, said so in its handoff note, and ended normally.
repo="$(setup_repo stopped-partway)"
printf '%s\n' 'printf "steps 1 and 2\n" >>feature.txt
mkdir -p .agents/handoffs
printf "**Done:** steps 1 and 2.\n**Remaining:** steps 3 to 9.\n" >".agents/handoffs/$RUN_ISSUE.md"
completion partial "Plan steps 3 to 9"
reply="Steps 1 and 2 are done. I ran out of time."' >"$repo.control/implementer-1.sh"
printf '%s\n' 'eval "$default"; printf "Issue %s is complete.\n" "$RUN_ISSUE" >".agents/handoffs/$RUN_ISSUE.md"' \
  >"$repo.control/implementer-2.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 2 1 0 0
log_of() {
  cat "$1-2-thing/.agents/run/2-log" 2>/dev/null || true
}
grep -Fq "| implementation | not complete | partial: " <<<"$(log_of "$repo")" || fail "the session that stopped partway is not in the log of the feature"
grep -Fq "remaining: Plan steps 3 to 9" <<<"$(log_of "$repo")" || fail "what remained is not in the log of the feature"
grep -Fq "You are resuming interrupted work" "$repo.control/implementer.args" || fail "the implementer was not resumed after it stopped partway"
grep -Fqx "Closes #2" "$repo.control/pr-body" || fail "the completed feature does not close the Issue"

# The reason is put in the handoff note for the session that continues.
repo="$(setup_repo stopped-partway-note)"
printf '%s\n' 'completion partial "Plan steps 3 to 9"; reply="Stopped."' >"$repo.control/implementer-1.sh"
printf '%s\n' 'cp ".agents/handoffs/$RUN_ISSUE.md" "$RUN_CONTROL/note-seen"; eval "$default"' >"$repo.control/implementer-2.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
grep -Fq "## Not complete" "$repo.control/note-seen" || fail "the resumed implementer was not told that the gate did not pass"
grep -Fq -- "- gate: remaining: Plan steps 3 to 9" "$repo.control/note-seen" || fail "the resumed implementer was not told what remained"
# What the run records there does not itself count as remaining work.
[[ -n "$(git -C "$repo-2-thing" log -1 --format=%B | grep -Fx 'Completion: complete')" ]] ||
  fail "the note of the run kept the gate from passing"
# The run records one check of the gate per check, with the implementation
# sessions before it: partial after session 1, complete after session 2,
# and the check before the review after the same session 2 is check 3.
gates="$(cat "$repo"/.agents/run/records/*.jsonl | jq -r -s '[.[] | select(.type == "completion-gate") | "\(.check):\(.sessions):\(.status)"] | join(" ")')"
[[ "$gates" == "1:1:partial 2:2:complete"* ]] || fail "the gate checks of the run are not recorded per check and session: $gates"
if grep -Eq '(^| )[0-9]+:1:partial .*[0-9]+:1:partial' <<<"$gates"; then fail "one session gave two partial outcomes: $gates"; fi
cat "$repo"/.agents/run/records/*.jsonl | jq -e -s 'any(.type == "experience" and (.record.derived.completion_gates | map(.status) | index("partial")) != null)' >/dev/null ||
  fail "the experience record of the run lacks the gate checks"

# Without any completion record, the same: the end of a session says nothing.
repo="$(setup_repo no-record)"
printf '%s\n' 'printf "half\n" >>feature.txt; mkdir -p .agents/summaries
printf -- "- Adds half of the feature file.\n" >".agents/summaries/$RUN_ISSUE.md"; reply="Done."' >"$repo.control/implementer-1.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 2 1 0 0
grep -Fq "| not complete | missing: the implementer wrote no completion record" <<<"$(log_of "$repo")" ||
  fail "the missing completion record is not in the log of the feature"

# A record that says complete is not believed against the handoff note.
repo="$(setup_repo record-contradicted)"
printf '%s\n' 'eval "$default"; mkdir -p .agents/handoffs
printf "## Done\nsteps 1 and 2\n\n## Remaining\n- step 3\n- step 4\n" >".agents/handoffs/$RUN_ISSUE.md"' >"$repo.control/implementer-1.sh"
printf '%s\n' 'eval "$default"; printf "Issue %s is complete.\n" "$RUN_ISSUE" >".agents/handoffs/$RUN_ISSUE.md"' \
  >"$repo.control/implementer-2.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 2 1 0 0
grep -Fq "the completion record says complete, but the handoff note" <<<"$(log_of "$repo")" ||
  fail "the contradiction between the record and the handoff note is not in the log of the feature"

# A complete record without the summary of the changes: the commit message
# of an unattended run would say nothing, so the implementer is resumed.
repo="$(setup_repo no-summary)"
printf '%s\n' 'printf "feature\n" >>feature.txt; completion complete; reply="Done."' >"$repo.control/implementer-1.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 2 1 0 0
grep -Fq "| not complete | no summary: the implementer wrote no summary of the changes" <<<"$(log_of "$repo")" ||
  fail "the missing summary is not in the log of the feature"
grep -Fqx -- "- Adds the feature file." <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" ||
  fail "the commit message lacks the summary that the resumed implementer wrote"

# Evidence that cannot exist yet does not stop the run. An implementer that
# records awaiting_evidence, with the CI result of the pull request pending,
# goes on to the review in one session; the commit says so and the pull
# request closes the Issue, because that evidence exists before the merge.
awaiting() {
  # awaiting <gate>: the implementer's work, with a criterion pending at the gate
  printf '%s\n' 'printf "feature\n" >>feature.txt
mkdir -p .agents/summaries .agents/completion
printf -- "- Adds the feature file.\n" >".agents/summaries/$RUN_ISSUE.md"
printf "{\"schema\": \"completion/v1\", \"status\": \"awaiting_evidence\", \"criteria\": [{\"criterion\": \"The feature file exists\", \"status\": \"met\", \"evidence\": \"feature.txt\"}, {\"criterion\": \"Evidence later\", \"gate\": \"'"$1"'\", \"status\": \"pending\", \"evidence\": \"after the gate\"}], \"remaining\": []}\n" >".agents/completion/$RUN_ISSUE.json"
reply="Done."'
}

repo="$(setup_repo awaiting-pr-ci)"
awaiting pr_ci >"$repo.control/implementer-1.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 1 0 0
grep -Fqx "Completion: awaiting_evidence" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" ||
  fail "the commit does not say that the feature awaits evidence"
grep -Fqx -- "- pending at pr_ci: Evidence later (after the gate)" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" ||
  fail "the commit does not name the pending evidence"
grep -Fqx "Closes #2" "$repo.control/pr-body" || fail "a feature that awaits only pr_ci evidence does not close the Issue"
if grep -Fq -- "--draft" "$repo.control/gh.log"; then fail "a feature that awaits evidence was opened as a draft"; fi
grep -Fq '"status": "awaiting_evidence"' "$repo.control/reviewer-1.context" || fail "the reviewer was not shown the awaiting_evidence record"
cat "$repo"/.agents/run/records/*.jsonl | jq -e -s 'any(.type == "completion-gate" and .status == "awaiting_evidence")' >/dev/null ||
  fail "the completion gate outcome awaiting_evidence is not in the run records"

# Evidence of the post_merge gate keeps the Issue open, but the pull request
# is ready for review.
repo="$(setup_repo awaiting-post-merge)"
awaiting post_merge >"$repo.control/implementer-1.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 1 0 0
if grep -Eiq '(^|[^[:alnum:]])(close[sd]?|fix(e[sd])?|resolve[sd]?):? +#2([^0-9]|$)' "$repo.control/pr-body"; then
  fail "a feature that awaits post_merge evidence closes the Issue on the merge"
fi
grep -Fq "evidence of the post_merge gate is pending" "$repo.control/pr-body" || fail "the pull request does not say why the Issue stays open"
grep -Fq "./scripts/record-post-merge.sh 2" "$repo.out" || fail "the end of the run does not name record-post-merge.sh"
if grep -Fq -- "--draft" "$repo.control/gh.log"; then fail "a feature that awaits post_merge evidence was opened as a draft"; fi

# The sessions are bounded: an implementer that never completes the Issue
# stops the run before any review, commit, or pull request.
repo="$(setup_repo never-complete)"
printf '%s\n' 'printf "more\n" >>feature.txt; completion partial "Plan steps 3 to 9"; reply="Stopped again."' \
  >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "the implementer ended 4 sessions without completing the Issue (partial): not met: The feature file exists; remaining: Plan steps 3 to 9"
expect_sessions "$repo" 4 0 0 0
[[ -n "$(git -C "$repo-2-thing" status --porcelain)" ]] || fail "work that is not complete was committed"
[[ "$(git -C "$repo-2-thing" rev-list --count origin/main..HEAD)" -eq 0 ]] || fail "work that is not complete was committed"
if git -C "$repo" ls-remote --exit-code --heads origin feature/2-thing >/dev/null 2>&1; then
  fail "work that is not complete was pushed"
fi
# Running again gives the implementer the same number of sessions again.
run_feature "$repo" 2
expect_stopped "$repo" 1 "without completing the Issue"
expect_sessions "$repo" 8 0 0 0

# A record that says blocked stops the run for the human, with status 3,
# also without a BLOCKED line in the final message.
repo="$(setup_repo record-blocked)"
printf '%s\n' 'printf "part\n" >>feature.txt; completion blocked "The Issue contradicts ADR 002"; reply="I cannot go on."' \
  >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 3 "the implementer reports that it cannot complete the Issue without you: not met: The feature file exists; remaining: The Issue contradicts ADR 002"
expect_sessions "$repo" 1 0 0 0

# Findings are triaged without a question and fixed, a second round confirms
# the fixes on the changes, and a third reviews the complete feature again:
# the round a feature is committed on always covers the whole Issue.
repo="$(setup_repo fixed)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 3 1 1
[[ "$(grep -c "Review of changes only" "$repo.control/reviewer.args")" -eq 1 ]] ||
  fail "the round after the fixes did not review only the changes, or the last round did"
if grep -Fq "Review of changes only" <<<"$(sed -n 3p "$repo.control/reviewer.args")"; then
  fail "the last round reviewed only the changes"
fi
grep -Fq "## Complete diff against" "$repo.control/reviewer-3.context" || fail "the last round was not given the complete feature"
grep -Fq "## Completion record of the implementer" "$repo.control/reviewer-3.context" ||
  fail "the last round was not given the completion record"
if grep -Fq "## Completion record of the implementer" "$repo.control/reviewer-2.context"; then
  fail "a review of changes only was given the completion record to judge"
fi
log_of "$repo" >/dev/null
grep -Fq "review of the complete feature, round 3 of at most 5" "$repo.out" || fail "the closing review was not announced"
triage="$repo-2-thing/.agents/triage/feature-2-thing-review-01-triage.json"
[[ "$(jq -r '.unattended' "$triage")" == "true" ]] || fail "the triage does not record that no human approved it"
[[ "$(jq -r '[.decisions[].decision] | join(",")' "$triage")" == "FIX_NOW,DEFER" ]] || fail "the triage lost its decisions"
grep -q '^issue comment 2 ' "$repo.control/gh.log" || fail "the triage was not published on the Issue"
grep -q '^issue create ' "$repo.control/gh.log" || fail "the deferred finding got no follow-up Issue"
grep -q "^Review: round 3, PASS" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" || fail "the commit does not name the review of the complete feature"

# The run is recorded in the primary checkout: one run, its steps, the
# verifications, and an agent call per session with its role, and the runs of
# the feature together in .agents/records/ after the publication.
records="$(cat "$repo"/.agents/run/records/*.jsonl)"
[[ "$(jq -r -s '[.[] | select(.type == "run-start")] | length' <<<"$records")" -eq 1 ]] ||
  fail "the run of the feature is not one run: the commands it started made runs of their own"
[[ "$(jq -r -s '.[] | select(.type == "run-start") | "\(.kind) \(.subject) \(.command)"' <<<"$records")" == "feature 2 run-feature.sh" ]] ||
  fail "the run does not name the feature"
[[ "$(jq -r -s '[.[] | select(.type == "agent-call") | .role] | group_by(.) | map("\(.[0])=\(length)") | join(" ")' <<<"$records")" == "implementer=1 reviewer=3 triage=1 triage-implementer=1" ]] ||
  fail "the agent calls are not recorded per role: $(jq -r -s '[.[] | select(.type == "agent-call") | .role] | join(",")' <<<"$records")"
jq -e -s 'any(.type == "verification" and .status == 0)' <<<"$records" >/dev/null || fail "the verifications are not recorded"
jq -e -s 'any(.type == "step" and .name == "review, round 1 of at most 5")' <<<"$records" >/dev/null || fail "the steps are not recorded"
jq -e -s 'any(.type == "run-end" and .status == 0)' <<<"$records" >/dev/null || fail "the end of the run is not recorded"
[[ -s "$repo/.agents/records/feature-2.jsonl" ]] || fail "the runs of the feature were not copied to .agents/records/ by the publication"
# The copy holds the run to its end: the publication and the status.
jq -e -s 'any(.type == "step" and .name == "pull request" and .status == 0)' "$repo/.agents/records/feature-2.jsonl" >/dev/null ||
  fail "the copy lacks the publication"
[[ "$(jq -r -s '.[-1] | "\(.type) \(.status)"' "$repo/.agents/records/feature-2.jsonl")" == "run-end 0" ]] ||
  fail "the copy does not end with the end of the run"
jq -e -s '[.[] | select(.type == "agent-start") | .id] == [.[] | select(.type == "agent-call") | .id]' <<<"$records" >/dev/null ||
  fail "an agent call does not close its start"
[[ ! -d "$repo-2-thing/.agents/run/records" ]] || fail "the run wrote records into the feature worktree"

# A finding of the closing review is fixed like any other, and the run ends
# on a review of the complete feature again.
repo="$(setup_repo closing-review-finds)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
printf '%s\n' "$only_major" >"$repo.control/reviewer-3.sh"
printf '%s\n' "$fix_major" >"$repo.control/triage.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 5 2 2
grep -q "^Review: round 5, PASS" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" || fail "the run did not end on the fifth round"
if grep -Fq "Review of changes only" <<<"$(sed -n 5p "$repo.control/reviewer.args")"; then
  fail "the run ended on a review of changes only"
fi

# When the rounds are used and the last one reviewed only changes, nothing
# confirms that the Issue is done: the run stops before the commit.
repo="$(setup_repo rounds-end-on-changes)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
for n in 2 3 4; do printf '%s\n' "$only_major" >"$repo.control/reviewer-$n.sh"; done
printf '%s\n' "$fix_major" >"$repo.control/triage.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "5 review rounds are used, and round 5 reviewed only changes"
expect_sessions "$repo" 1 5 4 4
grep -Fqx "fixed" "$repo-2-thing/feature.txt" || fail "the fixes are not in the feature"

# A feature that adds an ADR still gets its pull request, and the run says
# that only the owner may merge it, although the reviewer calls it minor.
repo="$(setup_repo adr)"
printf '%s\n' 'eval "$default"; mkdir -p docs/decisions; printf "# ADR 002: Other\n\nStatus: Proposed\n" >docs/decisions/002-other.md' \
  >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
grep -Fq "MERGE APPROVAL REQUIRED" "$repo.out" || fail "the run did not say that the owner must approve the merge"
grep -Fq "docs/decisions/002-other.md: an ADR is added, changed, or removed" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" ||
  fail "the commit does not record why the owner's approval is needed"

# The same when the independent reviewer classifies the impact as major.
repo="$(setup_repo impact-major)"
printf '%s\n' 'reply="{\"architecture_impact\": {\"level\": \"major\", \"rationale\": \"Adds shared infrastructure.\", \"checked_against\": []}, \"verdict\": \"PASS\", \"limitations\": \"\", \"findings\": []}"' \
  >"$repo.control/reviewer.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
grep -Fq "MERGE APPROVAL REQUIRED" "$repo.out" || fail "a major impact did not need the owner's approval"

# An unattended triage cannot let a major finding pass: the run stops.
repo="$(setup_repo major-deferred)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer.sh"
printf '%s\n' 'reply="{\"decisions\": [
  {\"finding_id\": \"M1\", \"decision\": \"ACCEPT\", \"rationale\": \"Fine.\", \"followup\": null},
  {\"finding_id\": \"MIN1\", \"decision\": \"ACCEPT\", \"rationale\": \"Fine.\", \"followup\": null}
]}"' >"$repo.control/triage.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "the triage of round 1 failed"
if compgen -G "$repo-2-thing/.agents/triage/*.json" >/dev/null; then fail "a triage that accepts a major finding was stored"; fi

# At most five rounds: when the fifth still has a finding to fix, the run
# stops before another fix that no review would confirm.
repo="$(setup_repo rounds)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
printf '%s\n' "$only_major" >"$repo.control/reviewer.sh"
printf '%s\n' "$fix_major" >"$repo.control/triage.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "5 review rounds are used and round 5 still has findings that must be fixed"
expect_sessions "$repo" 1 5 5 4
# A later round reviews the changes with the decisions of the round before,
# so the finding that round 1 deferred got one follow-up Issue, not five.
[[ "$(grep -c "Review of changes only" "$repo.control/reviewer.args")" -eq 4 ]] ||
  fail "the rounds after the first did not review only the changes"
grep -Fq "Decision: DEFER" "$repo.control/reviewer-2.context" ||
  fail "the second round was not given the decisions of the first"
[[ "$(grep -c '^issue create ' "$repo.control/gh.log")" -eq 1 ]] ||
  fail "the deferred finding of round 1 got $(grep -c '^issue create ' "$repo.control/gh.log") follow-up Issues"
# Running again does not start a sixth round.
run_feature "$repo" 2
expect_stopped "$repo" 1 "5 review rounds are used"
expect_sessions "$repo" 1 5 5 4

# What a fake agent runs to record a question in the handoff note.
ask='mkdir -p .agents/handoffs; printf "**Done:** part.\n\n**Open questions:** %s\n" "$question" >".agents/handoffs/$RUN_ISSUE.md"'

# An implementer that needs a decision, with its question in the handoff
# note, stops the run with status 3. After the answer, the same command
# resumes the implementation and goes on.
repo="$(setup_repo blocked)"
printf '%s\n' "question='does the Issue override ADR 002?'; $ask; reply=\"BLOCKED: the Issue contradicts ADR 002\"" \
  >"$repo.control/implementer-1.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 3 "the implementer needs a decision of yours"
grep -Fq "the Issue contradicts ADR 002" "$repo.out" || fail "the question of the implementer was not shown"
expect_sessions "$repo" 1 0 0 0
grep -Fq "| blocked |" <<<"$(log_of "$repo")" || fail "the blocked session is not in the log of the feature"
# The run records what a script can see, without claiming that a person did
# it: the next run follows a run that stopped with status 3, and the handoff
# note changed after that stop. Neither is an intervention.
interventions() {
  cat "$1"/.agents/run/records/*.jsonl | jq -r -s '[.[] | select(.type == "intervention") | .what] | join("|")'
}
resumptions() {
  cat "$1"/.agents/run/records/*.jsonl | jq -r -s '[.[] | select(.type == "resumed") | "\(.previous_status) \(.handoff_changed)"] | join("|")'
}
[[ "$(resumptions "$repo")" == "" ]] || fail "a first run records a resumption"
sleep 1
printf '**Open questions:** none.\n\nAnswer: the Issue overrides it.\n' >"$repo-2-thing/.agents/handoffs/2.md"
run_feature "$repo" 2
expect_published "$repo"
expect_sessions "$repo" 2 1 0 0
[[ "$(resumptions "$repo")" == "3 true" ]] ||
  fail "the run after the stop and the changed handoff note are not recorded: $(resumptions "$repo")"
[[ "$(interventions "$repo")" == "" ]] ||
  fail "a run after a stop is recorded as a human intervention: $(interventions "$repo")"
if grep -q "the Issue overrides it" <<<"$(cat "$repo"/.agents/run/records/*.jsonl)"; then fail "the answer itself reached the record"; fi
grep -Fq "You are resuming interrupted work" "$repo.control/implementer.args" || fail "the second session did not resume the work"

# A run that starts again after the stop without a change to the handoff
# note, as a scheduler or a retry would, records that the note did not change.
repo="$(setup_repo blocked-restart)"
printf '%s\n' "question='which ADR applies?'; $ask; reply=\"BLOCKED: two ADRs disagree\"" \
  >"$repo.control/implementer-1.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 3 "the implementer needs a decision of yours"
sleep 1
run_feature "$repo" 2
[[ "$(resumptions "$repo" | cut -d'|' -f1)" == "3 false" ]] ||
  fail "a run after the stop without a changed note is not recorded as such: $(resumptions "$repo")"
[[ "$(interventions "$repo")" == "" ]] ||
  fail "a run after the stop without an answer is recorded as an intervention: $(interventions "$repo")"

# BLOCKED without a question in the handoff note leaves nothing to answer:
# the script goes by what is recorded, not by the line, and the run goes on.
for note in "" "**Open questions:** none blocking."; do
  repo="$(setup_repo "blocked-without-question-${#note}")"
  printf '%s\n' "eval \"\$default\"; mkdir -p .agents/handoffs; printf '%s\n' '$note' >.agents/handoffs/\$RUN_ISSUE.md; reply=\"BLOCKED: the verification did not finish\"" \
    >"$repo.control/implementer.sh"
  run_feature "$repo" 2 thing
  expect_published "$repo"
  expect_sessions "$repo" 1 1 0 0
  grep -Fq "holds no open question" <<<"$(log_of "$repo")" || fail "the ignored BLOCKED line is not in the log of the feature"
done

# Reading the Issue fails on the connection before a worktree exists, more
# often than start-feature.sh tries: the run tries the start again, and goes
# on.
repo="$(setup_repo issue-flaky)"
printf '4\n' >"$repo.control/gh-title-flaky"
run_feature "$repo" 2
[[ "$status" -eq 0 ]] || { cat "$repo.out" >&2; fail "issue-flaky: the run failed with status $status"; }
git -C "$repo" ls-remote --exit-code --heads origin feature/2-feature-file >/dev/null 2>&1 ||
  fail "issue-flaky: the feature was not published"
grep -Fq "start-feature.sh could not read the Issue (status 75)" "$repo.out" || fail "the retried start is not reported"

# A session that fails once, for example on a usage limit, is tried again by
# the run itself: the implementer is resumed, a reviewer is started again.
repo="$(setup_repo implementer-fails-once)"
printf '%s\n' 'exit 9' >"$repo.control/implementer-1.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 2 1 0 0
grep -Fq "| temporary |" <<<"$(log_of "$repo")" || fail "the failed session is not in the log of the feature"

repo="$(setup_repo reviewer-fails-once)"
printf '%s\n' 'exit 9' >"$repo.control/reviewer-1.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 2 0 0
grep -Eq "\| temporary \| the step exited with status [0-9]+ \| Retry 1 of 3" <<<"$(log_of "$repo")" ||
  fail "the retry of the review is not in the log of the feature"

# The retries are bounded: a session that keeps failing stops the run, and
# the next run starts where it stopped.
repo="$(setup_repo implementer-keeps-failing)"
printf '%s\n' 'exit 9' >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "the implementation failed"
expect_sessions "$repo" 5 0 0 0

repo="$(setup_repo reviewer-keeps-failing)"
printf '%s\n' 'exit 9' >"$repo.control/reviewer.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "the review did not complete"
expect_sessions "$repo" 1 4 0 0
grep -Fq "also after 3 retries" <<<"$(log_of "$repo")" || fail "the exhausted retries are not in the log of the feature"
rm "$repo.control/reviewer.sh"
run_feature "$repo" 2
expect_published "$repo"
expect_sessions "$repo" 1 5 0 0

# A verification that fails once and passes when it is repeated is an
# unstable check: the run records it and goes on.
repo="$(VERIFY_CONF="unstable: sh -c 'test -e .agents/run/seen || { mkdir -p .agents/run; touch .agents/run/seen; false; }'" setup_repo unstable)"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 1 0 0
grep -Fq "unstable checks, failed in one of two verification runs: unstable" <<<"$(log_of "$repo")" ||
  fail "the unstable check is not named in the log of the feature"

# Two checks that fail in turn, each in one run only, are unstable too: no
# check failed twice, so nothing is repaired.
alternating="first: sh -c 'n=\$(cat .agents/run/n 2>/dev/null || echo 0); mkdir -p .agents/run; echo \$((n + 1)) >.agents/run/n; test \$n -ne 0'
second: sh -c 'test \$(cat .agents/run/n) -ne 2'"
repo="$(VERIFY_CONF="$alternating" setup_repo alternating)"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 1 0 0
grep -Fq "unstable checks" <<<"$(log_of "$repo")" || fail "checks that failed in turn were not recorded as unstable"
if grep -Fq "Repair attempt" <<<"$(log_of "$repo")"; then fail "a repair was started although no check failed twice"; fi

# A verification that fails twice is repaired by the implementer, which is
# given the failing checks in the handoff note.
repo="$(setup_repo repaired)"
printf '%s\n' 'if [[ "$count" -eq 1 ]]; then eval "$default"; printf "x\n" >broken.txt
else grep -q "FAIL  *sound" ".agents/handoffs/$RUN_ISSUE.md" && rm -f broken.txt; reply="Repaired."; fi' \
  >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 2 1 0 0
grep -Fq "Repair attempt 1 of 3" <<<"$(log_of "$repo")" || fail "the repair is not in the log of the feature"
grep -Fq "## Verification failed" "$repo-2-thing/.agents/handoffs/2.md" || fail "the failing checks were not recorded for the implementer"

# A session that repairs the verification is a session of the implementer
# too: when it repairs the check but leaves the work partial, the gate is
# asked again before the review, and the implementer continues.
repo="$(setup_repo repair-leaves-partial)"
printf '%s\n' 'case "$count" in
  1) eval "$default"; printf "x\n" >broken.txt ;;
  2) rm -f broken.txt; completion partial "The documentation"; reply="Repaired; the documentation is left." ;;
  *) eval "$default"; reply="Finished." ;;
esac' >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 3 1 0 0
grep -Fq "Repair attempt 1 of 3" <<<"$(log_of "$repo")" || fail "the repair is not in the log of the feature"
grep -Fq "| not complete | partial: " <<<"$(log_of "$repo")" || fail "the repair session that left work is not in the log of the feature"
grep -Fqx "Closes #2" "$repo.control/pr-body" || fail "the feature completed after the repair does not close the Issue"
# The repair session counts in the gate history: the check after it names
# it, with one session more than the check before it.
gates="$(cat "$repo"/.agents/run/records/*.jsonl | jq -c -s '[.[] | select(.type == "completion-gate") | {sessions, session, status}]')"
jq -e 'map(select(.status == "partial")) | length == 1' <<<"$gates" >/dev/null || fail "the check after the repair is not the partial one: $gates"
jq -e '(map(.status) | index("partial")) as $i | $i > 0 and .[$i].sessions == .[$i - 1].sessions + 1 and .[$i].session != .[$i - 1].session' <<<"$gates" >/dev/null ||
  fail "the repair session does not count in the gate history: $gates"

# The same for a repair session that removes the record, or that leaves
# remaining work in the handoff note.
repo="$(setup_repo repair-removes-record)"
printf '%s\n' 'case "$count" in
  1) eval "$default"; printf "x\n" >broken.txt ;;
  2) rm -f broken.txt ".agents/completion/$RUN_ISSUE.json"; reply="Repaired." ;;
  *) eval "$default"; reply="Finished." ;;
esac' >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 3 1 0 0
grep -Fq "| not complete | missing: " <<<"$(log_of "$repo")" || fail "the repair session without a record is not in the log of the feature"

repo="$(setup_repo repair-leaves-note)"
printf '%s\n' 'case "$count" in
  1) eval "$default"; printf "x\n" >broken.txt ;;
  2) rm -f broken.txt; printf "**Remaining:** the documentation\n" >".agents/handoffs/$RUN_ISSUE.md"; reply="Repaired." ;;
  *) eval "$default"; printf "Issue %s is complete.\n" "$RUN_ISSUE" >".agents/handoffs/$RUN_ISSUE.md"; reply="Finished." ;;
esac' >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 3 1 0 0
grep -Fq "the completion record says complete, but the handoff note" <<<"$(log_of "$repo")" ||
  fail "the repair session that left remaining work in the note is not in the log of the feature"

# A repair session that records blocked stops the run for the human, with
# status 3, also without a BLOCKED line: nothing is reviewed.
repo="$(setup_repo repair-blocked)"
printf '%s\n' 'case "$count" in
  1) eval "$default"; printf "x\n" >broken.txt ;;
  *) rm -f broken.txt; completion blocked "The check contradicts the Issue"; reply="I cannot repair this without a decision." ;;
esac' >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 3 "the implementer reports that it cannot complete the Issue without you"
expect_sessions "$repo" 2 0 0 0

# A session that stops on a usage limit, which its provider names only on its
# error output, says so in the log of the feature.
repo="$(setup_repo usage-limit)"
printf '%s\n' 'echo "Error: 429 Too Many Requests: rate limit exceeded" >&2; exit 1' \
  >"$repo.control/implementer-1.sh"
cp "$repo.control/implementer-1.sh" "$repo.control/implementer-2.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
grep -Fq "start-feature.sh exited with status 1; a usage limit of codex, reported by the agent" <<<"$(log_of "$repo")" ||
  fail "the usage limit of the first session is not in the log of the feature: $(log_of "$repo" | grep temporary)"
grep -Fq "the step exited with status 1; a usage limit of codex, reported by the agent" <<<"$(log_of "$repo")" ||
  fail "the usage limit of a resumed session is not in the log of the feature: $(log_of "$repo" | grep temporary)"

# A repair session that fails once, for example on a usage limit, is tried
# again like any other session.
repo="$(setup_repo repair-fails-once)"
printf '%s\n' 'if [[ "$count" -eq 1 ]]; then eval "$default"; printf "x\n" >broken.txt
elif [[ "$count" -eq 2 ]]; then exit 9
else rm -f broken.txt; reply="Repaired."; fi' >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 3 1 0 0
grep -Eq "repair of the verification, attempt 1 of 3 \| temporary" <<<"$(log_of "$repo")" ||
  fail "the failed repair session is not in the log of the feature"

# An agent that exits with the status the scripts keep for a failed
# verification is a failed session, not a failed verification.
for code in 4 5; do
  repo="$(setup_repo "agent-exits-$code")"
  printf '%s\n' "exit $code" >"$repo.control/implementer-1.sh"
  run_feature "$repo" 2 thing
  expect_published "$repo"
  expect_sessions "$repo" 2 1 0 0
  if grep -Eq "Repair attempt|changed the review" <<<"$(log_of "$repo")"; then
    fail "an agent that exited with $code was taken for a failed verification or a changed review"
  fi
done

# The repairs are bounded: after three the run stops and names the checks.
repo="$(setup_repo unverified)"
printf '%s\n' 'eval "$default"; printf "x\n" >broken.txt; reply="Done. ./scripts/verify.sh did not finish in this session."' \
  >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "the verification still fails"
expect_sessions "$repo" 4 0 0 0
grep -Eq "FAIL +sound" "$repo-2-thing/.agents/run/2-verify.log" || fail "the failing check is not in the kept output of the verification"
grep -Fq "fails after 3 repair attempts" <<<"$(log_of "$repo")" || fail "the exhausted repairs are not in the log of the feature"

# An implementer whose own verification did not finish reports that without
# a BLOCKED line: the run goes on to the step that verifies, and passes when
# the content is sound.
repo="$(setup_repo verification-unfinished)"
printf '%s\n' 'eval "$default"; reply="Implemented. ./scripts/verify.sh did not finish in this session; the unit tests pass."' \
  >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 1 0 0
grep -Fq "do not write a BLOCKED line" "$repo.control/implementer.args" ||
  fail "the unattended implementer was not told that a verification is no reason to block"

# A verification that fails after the fixes is repaired too, and a review
# confirms the result.
repo="$(setup_repo fixes-break)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
printf '%s\n' 'printf "fixed\n" >>feature.txt; printf "x\n" >broken.txt; reply="Fixed."' >"$repo.control/fixes.sh"
printf '%s\n' 'if [[ "$count" -eq 1 ]]; then eval "$default"; else rm -f broken.txt; reply="Repaired."; fi' \
  >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 2 3 1 1

# A repair of the verification after the fixes that fails once, after it
# changed the content, is tried again as a repair: start-feature.sh does not
# take the --continue of an interrupted fix session.
repo="$(setup_repo fixes-break-repair-fails)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
printf '%s\n' 'printf "fixed\n" >>feature.txt; printf "x\n" >broken.txt; reply="Fixed."' >"$repo.control/fixes.sh"
printf '%s\n' 'case "$count" in
  1) eval "$default" ;;
  2) printf "half repaired\n" >>feature.txt; exit 9 ;;
  *) rm -f broken.txt; reply="Repaired." ;;
esac' >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 3 3 1 1
if grep -Fq -- "--continue" "$repo.out"; then fail "a retried repair was given --continue"; fi
grep -Eq "repair of the verification, attempt 1 of 3 \| temporary" <<<"$(log_of "$repo")" ||
  fail "the failed repair after the fixes is not in the log of the feature"

# A repair after the fixes that keeps failing stops the run, which names the
# script that failed, not apply-triage.sh.
repo="$(setup_repo fixes-break-repair-exhausted)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
printf '%s\n' 'printf "fixed\n" >>feature.txt; printf "x\n" >broken.txt; reply="Fixed."' >"$repo.control/fixes.sh"
printf '%s\n' 'if [[ "$count" -eq 1 ]]; then eval "$default"; else printf "tried\n" >>feature.txt; exit 9; fi' \
  >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "the fixes for round 1 failed (start-feature.sh exited with status 9, also after the retries)"
if grep -Fq -- "--continue" "$repo.out"; then fail "an exhausted repair was given --continue"; fi

# A fixing agent that changed a file and then failed is continued with the
# same triage and scope: apply-triage.sh would refuse a new session, because
# the content changed since the review. No other agent takes over.
repo="$(setup_repo fixes-interrupted)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
printf '%s\n' 'printf "half fixed\n" >>feature.txt; exit 9' >"$repo.control/fixes-1.sh"
printf '%s\n' 'printf "fixed\n" >>feature.txt; reply="Finished the fixes."' >"$repo.control/fixes.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 3 1 2
grep -Fq "Continuing the interrupted session with the same scope" <<<"$(log_of "$repo")" ||
  fail "the interrupted fix session is not in the log of the feature"
[[ "$(grep -c "Wrong content" "$repo.control/fixes.args")" -eq 2 ]] ||
  fail "the continued session was not given the FIX_NOW finding of the triage"
[[ "$(grep -c "You are continuing a fix session that was interrupted" "$repo.control/fixes.args")" -eq 1 ]] ||
  fail "only the continued session should be told that it continues"
if grep -Fq "Vague name" "$repo.control/fixes.args"; then fail "a deferred finding was given to the fixing agent"; fi
[[ ! -e "$repo-2-thing/.agents/run/2-fixes-started" ]] || fail "the mark of the unfinished session was kept after it finished"

# An agent that changes the review it works from, validly, is not tried
# again and not continued: the changed review must not become the baseline
# of a next session.
repo="$(setup_repo fixes-tamper)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
printf '%s\n' 'printf "half fixed\n" >>feature.txt
r=.agents/reviews/feature-2-thing-review-01.json
jq ".findings[0].recommendation = \"Nothing to do.\"" "$r" >"$r.tmp" && mv "$r.tmp" "$r"
reply="Done."' >"$repo.control/fixes.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "changed the review or the approved triage"
expect_sessions "$repo" 1 1 1 1
[[ ! -e "$repo-2-thing/.agents/run/2-fixes-started" ]] || fail "the mark of a rejected session was kept"
grep -Fq "nothing is tried again" <<<"$(log_of "$repo")" || fail "the rejected session is not in the log of the feature"

# A fixing agent that failed before it changed anything is started again.
for code in 4 5; do
  repo="$(setup_repo "fixes-fail-once-$code")"
  printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
  printf '%s\n' "exit $code" >"$repo.control/fixes-1.sh"
  run_feature "$repo" 2 thing
  expect_published "$repo"
  expect_sessions "$repo" 1 3 1 2
done

# A fixing agent that needs a decision stops the run with status 3, and one
# that changes nothing stops it too, instead of reviewing the same content.
repo="$(setup_repo fixes-blocked)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
printf '%s\n' "question='which format?'; $ask; reply=\"BLOCKED: which format?\"" >"$repo.control/fixes-1.sh"
# The implementer continues only with the answer from the handoff note.
printf '%s\n' 'if [[ "$count" -eq 1 ]]; then eval "$default"
elif grep -q "Answer: JSON" ".agents/handoffs/$RUN_ISSUE.md" 2>/dev/null && [[ "$*" == *"handoff note: .agents/handoffs/"* ]]; then
  printf "answered\n" >>feature.txt; reply="Continued with the answer."
else reply="BLOCKED: no answer"; fi' >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 3 "the agent that applies the fixes needs a decision of yours"
# The answer is given: the next run hands it to the implementer, which
# resumes, and round 2 confirms the result.
printf '**Open questions:** none.\n\nWhich format?\nAnswer: JSON\n' >"$repo-2-thing/.agents/handoffs/2.md"
run_feature "$repo" 2
expect_published "$repo"
expect_sessions "$repo" 2 3 1 1
grep -Fqx "answered" "$repo-2-thing/feature.txt" || fail "the answer in the handoff note did not reach an agent"

repo="$(setup_repo fixes-nothing)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
printf '%s\n' 'reply="Nothing to do."' >"$repo.control/fixes.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "the fixes for round 1 changed nothing"
expect_sessions "$repo" 1 1 1 1

# When the base of the branch changed between two rounds, the next round
# reviews the complete feature instead of being refused.
repo="$(setup_repo base-changed)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
printf '%s\n' "question='wait for main?'; $ask; reply=\"BLOCKED: wait\"" >"$repo.control/fixes-1.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 3 "needs a decision of yours"
printf 'other work\n' >"$repo/other.txt"
git -C "$repo" add other.txt
git -C "$repo" commit -qm "Other work on main"
git -C "$repo" push -q origin main
git -C "$repo-2-thing" stash -q --include-untracked
git -C "$repo-2-thing" merge -q origin/main >/dev/null
git -C "$repo-2-thing" stash pop -q >/dev/null
git -C "$repo-2-thing" merge-base --is-ancestor origin/main HEAD && [[ -f "$repo-2-thing/other.txt" ]] ||
  fail "the test did not merge main into the feature"
run_feature "$repo" 2
expect_published "$repo"
expect_sessions "$repo" 2 2 1 1
if grep -Fq "Review of changes only" "$repo.control/reviewer.args"; then
  fail "a round after a changed base reviewed only the changes"
fi

# A pull request that cannot be opened stops the run after the commit; the
# next run only publishes.
repo="$(setup_repo publish-fails)"
: >"$repo.control/pr-fails"
run_feature "$repo" 2 thing
[[ "$status" -eq 1 ]] || fail "a failed publication exited with $status"
grep -Fq "the pull request could not be opened" "$repo.out" || fail "the failed publication was not reported"
rm "$repo.control/pr-fails"
run_feature "$repo" 2
expect_published "$repo"
expect_sessions "$repo" 1 1 0 0

# --implemented continues a feature that you implemented in your own session,
# without a session of the implementer. Your word does not replace the
# completion gate: without the record the run stops and says what is missing.
repo="$(setup_repo by-hand)"
git -C "$repo" worktree add -q -b feature/2-thing "$repo-2-thing" origin/main
printf 'by hand\n' >"$repo-2-thing/feature.txt"
run_feature "$repo" 2 --implemented
expect_stopped "$repo" 1 "implemented was given, but the completion gate does not pass (missing)"
expect_sessions "$repo" 0 0 0 0
mkdir -p "$repo-2-thing/.agents/completion" "$repo-2-thing/.agents/summaries"
printf '{"schema": "completion/v1", "status": "complete", "criteria": [{"criterion": "The feature file exists", "status": "met", "evidence": "feature.txt"}], "remaining": []}\n' \
  >"$repo-2-thing/.agents/completion/2.json"
run_feature "$repo" 2 --implemented
expect_stopped "$repo" 1 "implemented was given, but the completion gate does not pass (no summary)"
printf -- '- Adds the feature file by hand.\n' >"$repo-2-thing/.agents/summaries/2.md"
run_feature "$repo" 2 --implemented
expect_published "$repo"
expect_sessions "$repo" 0 1 0 0
cat "$repo"/.agents/run/records/*.jsonl | jq -e -s 'any(.type == "intervention" and (.what | test("--implemented")))' >/dev/null ||
  fail "--implemented is not recorded as an intervention"

# Without it, a worktree that no run completed is resumed by the implementer.
repo="$(setup_repo resumed)"
git -C "$repo" worktree add -q -b feature/2-thing "$repo-2-thing" origin/main
run_feature "$repo" 2
expect_published "$repo"
expect_sessions "$repo" 1 1 0 0
grep -Fq "You are resuming interrupted work" "$repo.control/implementer.args" || fail "the worktree was not resumed"

# Refusals, before anything starts.
repo="$(setup_repo refused)"
for arguments in "two" "2 thing main extra" "2 --merge" "2 --implemented" ""; do
  # shellcheck disable=SC2086
  run_feature "$repo" $arguments
  [[ "$status" -ne 0 ]] || fail "the arguments were accepted: '$arguments'"
done
expect_sessions "$repo" 0 0 0 0
if compgen -G "$repo-2-*" >/dev/null; then fail "a refused run created a worktree"; fi
git -C "$repo" worktree add -q -b feature/2-thing "$repo-2-thing" origin/main
run_feature "$repo" 2 other
[[ "$status" -ne 0 ]] || fail "a slug was accepted for a feature that already has a worktree"
expect_sessions "$repo" 0 0 0 0

echo "run-feature tests passed"
