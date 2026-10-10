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
    echo "https://github.com/example/project/pull/7"
    ;;
  "pr view") echo "main" ;;
  "api repos/{owner}/{repo}/rules/branches/main") echo "1" ;;
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
  printf 'sound: test ! -e broken.txt\n' >"$seed/scripts/verify.conf"
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
git -C "$repo-2-thing" log -1 --format=%s | grep -Fqx "F02 — Feature file" || fail "the commit is not named after the Issue"
git -C "$repo-2-thing" log -1 --format=%B | grep -Fqx -- "- Adds the feature file." ||
  fail "the commit message lacks the implementer's summary"

if grep -Fq "MERGE APPROVAL REQUIRED" "$repo.out"; then fail "ordinary work was reported as needing the owner's approval"; fi
git -C "$repo-2-thing" log -1 --format=%B | grep -A1 -Fx "Merge approval:" | grep -Fqx -- "- not required" ||
  fail "the commit does not record that no approval is needed"

# A finished feature is not run again: a repeated command only publishes.
run_feature "$repo" 2
expect_published "$repo"
expect_sessions "$repo" 1 1 0 0

# Findings are triaged without a question and fixed, and a second round
# confirms the fixes.
repo="$(setup_repo fixed)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 2 1 1
triage="$repo-2-thing/.agents/triage/feature-2-thing-review-01-triage.json"
[[ "$(jq -r '.unattended' "$triage")" == "true" ]] || fail "the triage does not record that no human approved it"
[[ "$(jq -r '[.decisions[].decision] | join(",")' "$triage")" == "FIX_NOW,DEFER" ]] || fail "the triage lost its decisions"
grep -q '^issue comment 2 ' "$repo.control/gh.log" || fail "the triage was not published on the Issue"
grep -q '^issue create ' "$repo.control/gh.log" || fail "the deferred finding got no follow-up Issue"
git -C "$repo-2-thing" log -1 --format=%B | grep -q "^Review: round 2.*PASS" || fail "the commit does not name the confirming round"
grep -Fqx "fixed" "$repo-2-thing/feature.txt" || fail "the fixes are not in the feature"

# A feature that adds an ADR still gets its pull request, and the run says
# that only the owner may merge it, although the reviewer calls it minor.
repo="$(setup_repo adr)"
printf '%s\n' 'eval "$default"; mkdir -p docs/decisions; printf "# ADR 002: Other\n\nStatus: Proposed\n" >docs/decisions/002-other.md' \
  >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
grep -Fq "MERGE APPROVAL REQUIRED" "$repo.out" || fail "the run did not say that the owner must approve the merge"
git -C "$repo-2-thing" log -1 --format=%B | grep -Fq "docs/decisions/002-other.md: an ADR is added, changed, or removed" ||
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

# An implementer that needs a decision stops the run with status 3. After the
# answer, the same command resumes the implementation and goes on.
repo="$(setup_repo blocked)"
printf '%s\n' 'reply="BLOCKED: the Issue contradicts ADR 002"' >"$repo.control/implementer-1.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 3 "the implementer needs a decision of yours"
grep -Fq "the Issue contradicts ADR 002" "$repo.out" || fail "the question of the implementer was not shown"
expect_sessions "$repo" 1 0 0 0
run_feature "$repo" 2
expect_published "$repo"
expect_sessions "$repo" 2 1 0 0
grep -Fq "You are resuming interrupted work" "$repo.control/implementer.args" || fail "the second session did not resume the work"

# A failing implementer stops the run; the next run resumes it.
repo="$(setup_repo implementer-fails)"
printf '%s\n' 'exit 9' >"$repo.control/implementer-1.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "the implementation failed"
run_feature "$repo" 2
expect_published "$repo"
expect_sessions "$repo" 2 1 0 0

# A failing reviewer, for example on a usage limit, stops the run. The next
# run does not implement again.
repo="$(setup_repo reviewer-fails)"
printf '%s\n' 'exit 9' >"$repo.control/reviewer-1.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "the review did not complete"
run_feature "$repo" 2
expect_published "$repo"
expect_sessions "$repo" 1 2 0 0

# Verification that fails after the implementation stops the run before a
# review.
repo="$(setup_repo unverified)"
printf '%s\n' 'printf "x\n" >broken.txt; reply="Done. ./scripts/verify.sh did not finish in this session."' \
  >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "the review did not complete"
expect_sessions "$repo" 1 0 0 0
# The agent reported no result of the verification; the step that verifies
# names the check that fails.
grep -Eq "FAIL +sound" "$repo.out" || fail "the failing check was not named when the run stopped"

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

# Verification that still fails after the fixes stops the run.
repo="$(setup_repo fixes-break)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
printf '%s\n' 'printf "x\n" >broken.txt; reply="Fixed."' >"$repo.control/fixes.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "the fixes for round 1 failed"
expect_sessions "$repo" 1 1 1 1

# A fixing agent that needs a decision stops the run with status 3, and one
# that changes nothing stops it too, instead of reviewing the same content.
repo="$(setup_repo fixes-blocked)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
printf '%s\n' 'reply="BLOCKED: which format?"' >"$repo.control/fixes-1.sh"
# The implementer continues only with the answer from the handoff note.
printf '%s\n' 'if [[ "$count" -eq 1 ]]; then eval "$default"
elif grep -q "Answer: JSON" ".agents/handoffs/$RUN_ISSUE.md" 2>/dev/null && [[ "$*" == *"handoff note: .agents/handoffs/"* ]]; then
  printf "answered\n" >>feature.txt; reply="Continued with the answer."
else reply="BLOCKED: no answer"; fi' >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 3 "the agent that applies the fixes needs a decision of yours"
# The answer is given: the next run hands it to the implementer, which
# resumes, and round 2 confirms the result.
mkdir -p "$repo-2-thing/.agents/handoffs"
printf 'Open questions\n\nWhich format?\nAnswer: JSON\n' >"$repo-2-thing/.agents/handoffs/2.md"
run_feature "$repo" 2
expect_published "$repo"
expect_sessions "$repo" 2 2 1 1
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
printf '%s\n' 'reply="BLOCKED: wait"' >"$repo.control/fixes-1.sh"
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

# --implemented continues a feature that you implemented in your own session.
repo="$(setup_repo by-hand)"
git -C "$repo" worktree add -q -b feature/2-thing "$repo-2-thing" origin/main
printf 'by hand\n' >"$repo-2-thing/feature.txt"
run_feature "$repo" 2 --implemented
expect_published "$repo"
expect_sessions "$repo" 0 1 0 0

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
