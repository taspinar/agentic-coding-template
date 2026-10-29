#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$source_root/tests/lib-fakes.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/verify-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "verify test failed: $*" >&2
  exit 1
}

mkdir -p "$tmp/bin"
printf '#!/usr/bin/env bash\necho "ruff $*" >>"$MOCK_TOOL_LOG"\nexit "${MOCK_RUFF_EXIT:-0}"\n' >"$tmp/bin/ruff"
printf '#!/usr/bin/env bash\necho "pytest $*" >>"$MOCK_TOOL_LOG"\nexit "${MOCK_PYTEST_EXIT:-0}"\n' >"$tmp/bin/pytest"
chmod +x "$tmp/bin/ruff" "$tmp/bin/pytest"

# Creates an isolated project that contains only verify.sh and the given config.
setup_project() {
  local label="$1"
  local project="$tmp/$label"

  mkdir -p "$project/scripts"
  cp "$source_root/scripts/verify.sh" "$project/scripts/verify.sh"
  if [[ $# -gt 1 ]]; then
    printf '%s\n' "${@:2}" >"$project/scripts/verify.conf"
  fi
  printf '%s\n' "$project"
}

run_verify() {
  local project="$1"

  PATH="$tmp/bin:/usr/bin:/bin" MOCK_TOOL_LOG="$project/tools.log" \
    "$project/scripts/verify.sh" ${2+"$2"} >"$project/out.log" 2>&1
}

expect_failure() {
  local project="$1"
  local description="$2"

  if run_verify "$project"; then
    cat "$project/out.log" >&2
    fail "expected failure: $description"
  fi
}

# All required checks pass.
project="$(setup_project pass "# stack checks" "" "lint: ruff check ." "tests: pytest")"
run_verify "$project" || {
  cat "$project/out.log" >&2
  fail "passing checks were reported as a failure"
}
[[ "$(grep -c . "$project/tools.log")" -eq 2 ]] || fail "not every configured check ran"

# A failing linter fails verification, and later checks still run.
project="$(setup_project lint-fails "lint: ruff check ." "tests: pytest")"
MOCK_RUFF_EXIT=1 expect_failure "$project" "ruff failure must propagate"
grep -Fq "pytest" "$project/tools.log" || fail "checks after a failure did not run"
grep -Eq "FAIL +lint" "$project/out.log" || fail "failed check was not identified"

# A failing test run fails verification.
project="$(setup_project tests-fail "lint: ruff check ." "tests: pytest")"
MOCK_PYTEST_EXIT=3 expect_failure "$project" "pytest failure must propagate"
grep -Eq "FAIL +tests" "$project/out.log" || fail "failed test check was not identified"

# A failure inside a pipeline or before a later command is not masked.
project="$(setup_project pipeline "lint: ruff check . | cat")"
MOCK_RUFF_EXIT=1 expect_failure "$project" "pipeline failure must propagate"

project="$(setup_project sequence "lint: ruff check .; pytest")"
MOCK_RUFF_EXIT=1 expect_failure "$project" "failure before a later command must propagate"

# A required check whose tool is missing fails and names the check and tool.
project="$(setup_project missing-tool "lint: ruff check ." "types: mypy .")"
expect_failure "$project" "missing required tool must fail"
grep -Fq "mypy" <<<"$(grep -F "types" "$project/out.log")" ||
  fail "missing tool message did not name the check and tool"

# A required check script that is not executable fails.
project="$(setup_project not-executable "suite: ./suite.sh")"
printf '#!/usr/bin/env bash\nexit 0\n' >"$project/suite.sh"
expect_failure "$project" "non-executable check script must fail"

# Checks run from the repository root, regardless of the caller's directory.
project="$(setup_project cwd "marker: test -f scripts/verify.conf")"
mkdir -p "$project/nested"
(cd "$project/nested" && run_verify "$project") ||
  fail "checks did not run from the repository root"

# Missing, empty, malformed, and duplicate configuration is rejected.
project="$(setup_project no-config)"
expect_failure "$project" "missing configuration must fail"

project="$(setup_project empty-config "# no checks" "")"
expect_failure "$project" "configuration without checks must fail"

project="$(setup_project malformed "lint ruff check .")"
expect_failure "$project" "malformed check line must fail"
[[ ! -e "$project/tools.log" ]] || fail "checks ran despite malformed configuration"

project="$(setup_project duplicate "lint: ruff check ." "lint: pytest")"
expect_failure "$project" "duplicate check name must fail"

# The workflow self-tests live in their own file and run only when a workflow
# file differs from the base branch.
setup_workflow_project() {
  local project

  project="$(setup_project "$1" "lint: ruff check .")"
  mkdir -p "$project/tools" "$project/src"
  printf 'paths: tools .gitignore scripts/verify-workflow.conf\nself-test: pytest\n' \
    >"$project/scripts/verify-workflow.conf"
  printf 'one\n' >"$project/tools/tool.sh"
  printf 'one\n' >"$project/src/app.txt"
  git -C "$project" init -q -b main
  git -C "$project" config user.name "Test User"
  git -C "$project" config user.email "test@example.com"
  git -C "$project" add -A
  git -C "$project" commit -qm "Initial commit"
  git -C "$project" checkout -q -b feature/1-change
  printf '%s\n' "$project"
}

self_tests_ran() {
  grep -Fq "pytest" "$1/tools.log"
}

expect_skipped() {
  local project="$1"
  local description="$2"

  rm -f "$project/tools.log"
  run_verify "$project" || {
    cat "$project/out.log" >&2
    fail "verification failed: $description"
  }
  grep -Fq "ruff" "$project/tools.log" || fail "the project checks did not run: $description"
  if self_tests_ran "$project"; then fail "the self-tests ran although $description"; fi
  grep -Eq "^SKIP +workflow self-tests \(1 checks\)" "$project/out.log" ||
    fail "the skipped self-tests were not reported: $description"
}

expect_ran() {
  local project="$1"
  local description="$2"

  rm -f "$project/tools.log"
  run_verify "$project" ${3+"$3"} || {
    cat "$project/out.log" >&2
    fail "verification failed: $description"
  }
  self_tests_ran "$project" || fail "the self-tests did not run although $description"
  if grep -Fq "SKIP" "$project/out.log"; then fail "a skip was reported although $description"; fi
}

project="$(setup_workflow_project workflow-unchanged)"
expect_skipped "$project" "nothing changed"
printf 'two\n' >>"$project/src/app.txt"
printf 'new\n' >"$project/src/new.txt"
expect_skipped "$project" "only project files changed"
git -C "$project" add -A
git -C "$project" commit -qm "Change the project"
expect_skipped "$project" "only project files were committed"
expect_ran "$project" "--all was given" --all

project="$(setup_workflow_project workflow-uncommitted)"
printf 'two\n' >>"$project/tools/tool.sh"
expect_ran "$project" "a workflow file has an uncommitted change"

project="$(setup_workflow_project workflow-untracked)"
printf 'new\n' >"$project/tools/new.sh"
expect_ran "$project" "a workflow file is new and untracked"

# A path entry can name a single file in the repository root.
project="$(setup_workflow_project workflow-root-file)"
printf 'build/\n' >"$project/.gitignore"
expect_ran "$project" "a guarded file in the repository root is new"

project="$(setup_workflow_project workflow-committed)"
git -C "$project" rm -q tools/tool.sh
git -C "$project" commit -qm "Remove a workflow file"
expect_ran "$project" "a workflow file was removed in a commit"

# A path entry can exclude a file from a guarded directory.
project="$(setup_workflow_project workflow-excluded)"
printf 'paths: tools :(exclude)tools/tool.sh\nself-test: pytest\n' >"$project/scripts/verify-workflow.conf"
git -C "$project" commit -qam "Exclude a file"
git -C "$project" branch -q -f main
printf 'two\n' >>"$project/tools/tool.sh"
expect_skipped "$project" "only an excluded file changed"
printf 'new\n' >"$project/tools/other.sh"
expect_ran "$project" "another file in the guarded directory is new"

# Without a base branch the change cannot be determined, so the self-tests run.
project="$(setup_workflow_project workflow-no-base)"
git -C "$project" branch -q -D main
expect_ran "$project" "there is no base branch"

project="$(setup_project workflow-no-repository "lint: ruff check .")"
printf 'paths: tools\nself-test: pytest\n' >"$project/scripts/verify-workflow.conf"
expect_ran "$project" "the project is not a Git repository"

# A failing self-test fails verification, and a self-test file without paths
# or without checks is rejected.
project="$(setup_workflow_project workflow-fails)"
printf 'two\n' >>"$project/tools/tool.sh"
MOCK_PYTEST_EXIT=1 expect_failure "$project" "a failing self-test must propagate"
grep -Eq "FAIL +self-test" "$project/out.log" || fail "the failed self-test was not identified"

project="$(setup_workflow_project workflow-no-paths)"
printf 'self-test: pytest\n' >"$project/scripts/verify-workflow.conf"
expect_failure "$project" "self-tests without paths must fail"

project="$(setup_workflow_project workflow-no-checks)"
printf 'paths: tools\n' >"$project/scripts/verify-workflow.conf"
expect_failure "$project" "a self-test file without checks must fail"

project="$(setup_workflow_project workflow-duplicate)"
printf 'paths: tools\nlint: pytest\n' >"$project/scripts/verify-workflow.conf"
expect_failure "$project" "a check name used in both files must fail"

# A run in which every check passed is recorded for the content it verified,
# and --reuse skips a second run on exactly that content.
setup_recorded_project() {
  local project

  project="$(setup_project "$1" "lint: ruff check .")"
  mkdir -p "$project/scripts/lib" "$project/src"
  cp "$source_root/scripts/lib/fingerprint.sh" "$source_root/scripts/lib/verification.sh" "$project/scripts/lib/"
  printf '*.log\n.agents/verification/\n' >"$project/.gitignore"
  printf 'one\n' >"$project/src/app.txt"
  git -C "$project" init -q -b main
  git -C "$project" config user.name "Test User"
  git -C "$project" config user.email "test@example.com"
  git -C "$project" add -A
  git -C "$project" commit -qm "Initial commit"
  printf '%s\n' "$project"
}

record="/.agents/verification/passed"

# run_checks <project> <description> [option...]: the checks must really run.
expect_checks_ran() {
  local project="$1"
  local description="$2"

  shift 2
  rm -f "$project/tools.log"
  PATH="$tmp/bin:/usr/bin:/bin" MOCK_TOOL_LOG="$project/tools.log" \
    "$project/scripts/verify.sh" "$@" >"$project/out.log" 2>&1 || {
    cat "$project/out.log" >&2
    fail "verification failed: $description"
  }
  grep -Fq "ruff" "$project/tools.log" 2>/dev/null || fail "the checks did not run although $description"
}

expect_reused() {
  local project="$1"
  local description="$2"

  shift 2
  rm -f "$project/tools.log"
  PATH="$tmp/bin:/usr/bin:/bin" MOCK_TOOL_LOG="$project/tools.log" \
    "$project/scripts/verify.sh" "$@" >"$project/out.log" 2>&1 || {
    cat "$project/out.log" >&2
    fail "a reused verification failed: $description"
  }
  [[ ! -e "$project/tools.log" ]] || fail "the checks ran again although $description"
  grep -Fq "already passed" "$project/out.log" || fail "the reuse was not reported: $description"
}

project="$(setup_recorded_project recorded)"
expect_checks_ran "$project" "nothing was recorded yet" --reuse
[[ -f "$project$record" ]] || fail "a passed run was not recorded"
[[ -z "$(git -C "$project" status --porcelain)" ]] || fail "the record changed the working tree"
expect_reused "$project" "the content is unchanged" --reuse
expect_checks_ran "$project" "--reuse was not given"
printf 'two\n' >>"$project/src/app.txt"
expect_checks_ran "$project" "a tracked file changed" --reuse
expect_reused "$project" "the changed content was verified" --reuse
printf 'new\n' >"$project/src/new.txt"
expect_checks_ran "$project" "an untracked file was added" --reuse
git -C "$project" add -A
git -C "$project" commit -qm "Commit the same content"
expect_reused "$project" "the same content was only committed" --reuse

# A failing run records nothing and removes an earlier record.
if MOCK_RUFF_EXIT=1 run_verify "$project"; then fail "a failing run returned success"; fi
[[ ! -e "$project$record" ]] || fail "a failing run left a record"
expect_checks_ran "$project" "the last run failed" --reuse

# A run whose check changes a file verified no single content.
project="$(setup_recorded_project self-modifying)"
printf 'touch: date >>src/app.txt\n' >"$project/scripts/verify.conf"
run_verify "$project" || fail "a run whose check changes a file failed"
[[ ! -e "$project$record" ]] || fail "a run that changed the content was recorded"

# Without the ignore rule the record would become part of the content, so
# none is written.
project="$(setup_recorded_project not-ignored)"
printf '*.log\n' >"$project/.gitignore"
git -C "$project" commit -qam "Drop the ignore rule"
expect_checks_ran "$project" "no record can be kept" --reuse
[[ ! -e "$project$record" ]] || fail "a record was written where Git does not ignore it"
expect_checks_ran "$project" "no record can be kept" --reuse

# A record made without the workflow self-tests does not cover --all.
project="$(setup_workflow_project recorded-workflow)"
mkdir -p "$project/scripts/lib"
cp "$source_root/scripts/lib/fingerprint.sh" "$source_root/scripts/lib/verification.sh" "$project/scripts/lib/"
printf 'paths: tools\nself-test: pytest\n' >"$project/scripts/verify-workflow.conf"
printf '*.log\n.agents/verification/\n' >"$project/.gitignore"
git -C "$project" add -A
git -C "$project" commit -qm "Keep verification records"
git -C "$project" branch -q -f main
expect_checks_ran "$project" "nothing was recorded yet" --reuse
if self_tests_ran "$project"; then fail "the self-tests ran although no workflow file changed"; fi
expect_reused "$project" "the content is unchanged" --reuse
expect_checks_ran "$project" "the record does not include the self-tests" --reuse --all
self_tests_ran "$project" || fail "--all with --reuse did not run the self-tests"
expect_reused "$project" "the self-tests were included in the record" --reuse --all
expect_reused "$project" "a complete record covers a plain run" --reuse

project="$(setup_project unknown-option "lint: ruff check .")"
if PATH="$tmp/bin:/usr/bin:/bin" "$project/scripts/verify.sh" --everything >"$project/out.log" 2>&1; then
  fail "an unknown option was accepted"
fi
[[ ! -e "$project/tools.log" ]] || fail "checks ran despite an unknown option"

# Groups: a check may name one, and --only runs the checks of the named
# groups. run_with <project> [option...] runs verify.sh with a fresh tool log.
run_with() {
  local project="$1"

  shift
  rm -f "$project/tools.log"
  PATH="$tmp/bin:/usr/bin:/bin" MOCK_TOOL_LOG="$project/tools.log" \
    "$project/scripts/verify.sh" "$@" >"$project/out.log" 2>&1
}

# ran <project>: the commands that ran, on one line.
ran() {
  tr '\n' ';' <"$1/tools.log" 2>/dev/null || true
}

project="$(setup_project groups "lint [code]: ruff check ." "tests[code]: pytest unit" \
  "slow  [e2e-1]: pytest e2e" "plain: ruff plain")"

# Without --only every check runs, as before.
run_with "$project" || fail "a configuration with groups failed"
[[ "$(ran "$project")" == "ruff check .;pytest unit;pytest e2e;ruff plain;" ]] ||
  fail "not every check ran without --only: $(ran "$project")"

run_with "$project" --groups || fail "--groups failed"
[[ "$(tr '\n' ',' <"$project/out.log")" == "code,e2e-1,default," ]] ||
  fail "--groups did not print the groups in the order of their first check: $(cat "$project/out.log")"
[[ ! -e "$project/tools.log" ]] || fail "--groups ran a check"

run_with "$project" --only code || fail "--only with one group failed"
[[ "$(ran "$project")" == "ruff check .;pytest unit;" ]] || fail "--only code ran: $(ran "$project")"
grep -Fq "Not a verification" "$project/out.log" || fail "a partial run did not say that it is not a verification"
if grep -Fq "Verification passed" "$project/out.log"; then fail "a partial run reported a passed verification"; fi

# A check without a group is in 'default', and several groups run in the
# order of the file, not of the option.
run_with "$project" --only default,code || fail "--only with two groups failed"
[[ "$(ran "$project")" == "ruff check .;pytest unit;ruff plain;" ]] || fail "--only default,code ran: $(ran "$project")"

if run_with "$project" --only code,nope; then fail "an unknown group was accepted"; fi
grep -Fq "no check is in the group 'nope'" "$project/out.log" || fail "the unknown group was not named"
[[ ! -e "$project/tools.log" ]] || fail "a check ran although a group was unknown"
if run_with "$project" --only; then fail "--only without a group was accepted"; fi
if run_with "$project" --only "Code"; then fail "a group name with a capital was accepted"; fi
if run_with "$project" --only code --reuse; then fail "--only was accepted together with --reuse"; fi
grep -Fq "nothing to reuse" "$project/out.log" || fail "the refusal of --reuse did not say why"

# A failing check of a selected group fails the partial run; a failing check
# of another group does not.
if MOCK_PYTEST_EXIT=1 run_with "$project" --only code; then fail "a failing check of the group passed"; fi
MOCK_PYTEST_EXIT=1 run_with "$project" --only default || fail "a failing check of another group failed the run"

# A malformed group is a malformed line.
project="$(setup_project bad-group "lint [Code]: ruff check .")"
expect_failure "$project" "a group name with a capital must fail"
project="$(setup_project empty-group "lint []: ruff check .")"
expect_failure "$project" "an empty group must fail"

# A partial run is never a verification: it records nothing, whichever
# groups it runs, and it leaves a record of a complete run alone. A failing
# partial run removes the record, like any failing run.
project="$(setup_recorded_project partial)"
printf '%s\n' "lint [code]: ruff check ." "tests: pytest" >"$project/scripts/verify.conf"
git -C "$project" commit -qam "Give a check a group"
for group in code default code,default; do
  run_with "$project" --only "$group" || fail "--only $group failed"
  [[ ! -e "$project$record" ]] || fail "a partial run of '$group' recorded a passed verification"
done
run_with "$project" --reuse || fail "a complete run failed"
[[ "$(ran "$project")" == "ruff check .;pytest ;" ]] || fail "--reuse took partial runs for a verification: $(ran "$project")"
[[ -f "$project$record" ]] || fail "a complete run was not recorded"
before="$(cat "$project$record")"
run_with "$project" --only code || fail "a partial run after a complete one failed"
[[ "$(cat "$project$record")" == "$before" ]] || fail "a passing partial run changed the record of a complete run"
if MOCK_RUFF_EXIT=1 run_with "$project" --only code; then fail "a failing partial run returned success"; fi
[[ ! -e "$project$record" ]] || fail "a failing partial run left the record of a passed verification"

# The workflow self-tests have groups too, and keep their own rule: they run
# when a workflow file changed, or with --all.
project="$(setup_workflow_project workflow-groups)"
printf '%s\n' "lint [code]: ruff check ." >"$project/scripts/verify.conf"
printf '%s\n' "paths: scripts" "selftest [workflow]: pytest selftest" >"$project/scripts/verify-workflow.conf"
git -C "$project" add -A
git -C "$project" commit -qm "Group the checks"
git -C "$project" branch -f main HEAD
run_with "$project" --groups || fail "--groups failed with workflow self-tests"
[[ "$(tr '\n' ',' <"$project/out.log")" == "code,workflow," ]] || fail "--groups left out the group of a self-test"
run_with "$project" --only workflow || fail "--only workflow failed"
[[ ! -e "$project/tools.log" ]] || fail "--only ran a self-test although no workflow file changed"
grep -Fq "SKIP  workflow self-tests" "$project/out.log" || fail "the skipped self-tests were not reported"
run_with "$project" --all --only workflow || fail "--all --only workflow failed"
[[ "$(ran "$project")" == "pytest selftest;" ]] || fail "--all --only workflow ran: $(ran "$project")"
run_with "$project" --all --only code || fail "--all --only code failed"
[[ "$(ran "$project")" == "ruff check .;" ]] || fail "--all --only code ran a self-test: $(ran "$project")"

# A check name is unique across both files, also when the two checks name
# different groups: the name identifies the check in the summary.
project="$(setup_workflow_project same-name-groups)"
printf '%s\n' "lint [code]: ruff check ." >"$project/scripts/verify.conf"
printf '%s\n' "paths: scripts" "lint [workflow]: pytest selftest" >"$project/scripts/verify-workflow.conf"
if run_with "$project" --all; then fail "the same check name in both files, in different groups, was accepted"; fi
grep -Fq "duplicate check name" "$project/out.log" || fail "the duplicate name was not reported"
[[ ! -e "$project/tools.log" ]] || fail "a check ran although a check name is used twice"
if run_with "$project" --groups; then fail "--groups accepted a duplicate check name"; fi

# A check does not inherit the agent or attribution configuration chosen for
# the run that verifies.
project="$(setup_project agent-config 'config: test -z "${AGENT_CONFIG_FILE:-}" -a -z "${ATTRIBUTION_CONFIG_FILE:-}"')"
AGENT_CONFIG_FILE=/nonexistent.conf ATTRIBUTION_CONFIG_FILE=/nonexistent.conf run_verify "$project" || {
  cat "$project/out.log" >&2
  fail "a check inherited AGENT_CONFIG_FILE or ATTRIBUTION_CONFIG_FILE"
}

# The workflow self-tests give their own result when started by hand with the
# variable set.
(
  export AGENT_CONFIG_FILE=/nonexistent.conf ATTRIBUTION_CONFIG_FILE=/nonexistent.conf
  source "$source_root/tests/lib-fakes.sh"
  [[ -z "${AGENT_CONFIG_FILE:-}" && -z "${ATTRIBUTION_CONFIG_FILE:-}" ]]
) || fail "tests/lib-fakes.sh kept AGENT_CONFIG_FILE or ATTRIBUTION_CONFIG_FILE"

# A self-test started by hand inside a recorded run writes nothing into that
# run's record: tests/lib-fakes.sh drops the run's RECORDS_* variables, as
# verify.sh does for its checks. The workflow script here is verify.sh, which
# records itself into the run it finds.
project="$(setup_project inside-run "lint: ruff check .")"
mkdir -p "$project/scripts/lib"
cp "$source_root/scripts/lib/records.sh" "$project/scripts/lib/records.sh"
: >"$tmp/parent-run.jsonl"
(
  export RECORDS_RUN_ID=parent-run RECORDS_FILE="$tmp/parent-run.jsonl" RECORDS_COMMAND=scripts/run-feature.sh \
    RECORDS_KIND=feature RECORDS_SUBJECT=1
  source "$source_root/tests/lib-fakes.sh"
  run_verify "$project"
) || {
  cat "$project/out.log" >&2
  fail "verify.sh failed inside a recorded run"
}
[[ ! -s "$tmp/parent-run.jsonl" ]] || fail "a test wrote into the record of the run that started it: $(cat "$tmp/parent-run.jsonl")"

# A partial run inside a recorded run is not a verification and writes
# nothing into that run's record; a complete run there records itself.
project="$(setup_project partial-inside-run "lint [code]: ruff check ." "tests: pytest")"
mkdir -p "$project/scripts/lib"
cp "$source_root/scripts/lib/records.sh" "$project/scripts/lib/records.sh"
: >"$tmp/partial-run.jsonl"
inside_run() {
  RECORDS_RUN_ID=parent-run RECORDS_FILE="$tmp/partial-run.jsonl" RECORDS_COMMAND=scripts/run-feature.sh \
    RECORDS_KIND=feature RECORDS_SUBJECT=1 run_with "$@"
}
inside_run "$project" --only code || {
  cat "$project/out.log" >&2
  fail "verify.sh --only failed inside a recorded run"
}
[[ "$(ran "$project")" == "ruff check .;" ]] || fail "--only code inside a run ran: $(ran "$project")"
[[ ! -s "$tmp/partial-run.jsonl" ]] || fail "a partial run wrote into the record of its run: $(cat "$tmp/partial-run.jsonl")"
inside_run "$project" || fail "verify.sh failed inside a recorded run"
jq -e -s 'any(.type == "verification" and .groups == "all")' "$tmp/partial-run.jsonl" >/dev/null ||
  fail "a complete run inside a recorded run was not recorded"

# Budgets: a check declared as '<name> [<group>] budget: <command>' measures
# something against a target. Over the target it is BUDGET, not FAIL: the
# summary shows it with the output of the check, and the verification passes
# when every other check passed.
over='perf [code] budget: sh -c '"'"'echo "1.4 s, target 1.0 s"; exit 2'"'"
project="$(setup_project budget "lint: ruff check ." "$over" "size budget: echo 12kB")"
run_with "$project" || {
  cat "$project/out.log" >&2
  fail "a budget over its target failed the verification"
}
grep -Fq "ruff" "$project/tools.log" || fail "the other checks did not run with a budget"
grep -Fqx "BUDGET  perf (exit 2)" "$project/out.log" || fail "the exceeded budget is not BUDGET in the summary: $(cat "$project/out.log")"
grep -Fqx "        1.4 s, target 1.0 s" "$project/out.log" || fail "the summary lacks the output of the budget check"
grep -Fqx "PASS  size (budget within its target)" "$project/out.log" || fail "a budget within its target is not PASS"
grep -Fq "Verification passed." "$project/out.log" || fail "the verification with an exceeded budget did not pass"
grep -Fq "1 budget check(s) exceeded their target" "$project/out.log" || fail "the summary does not say that a budget was exceeded"
if grep -Fq "FAIL" "$project/out.log"; then fail "an exceeded budget was reported as a failure"; fi
grep -Fq -- "-- perf (budget):" "$project/out.log" || fail "a budget check is not marked as one when it runs"

# Every other check still has to pass: a failed check fails the verification
# as before, and the budget is still shown as BUDGET.
if MOCK_RUFF_EXIT=1 run_with "$project"; then fail "a failed check passed next to a budget"; fi
grep -Fqx "FAIL  lint (exit 1)" "$project/out.log" || fail "the failed check next to a budget was not identified"
grep -Fqx "BUDGET  perf (exit 2)" "$project/out.log" || fail "the budget is not BUDGET when another check fails"

# A budget check that does not finish measured nothing: the status 124 of
# 'timeout' and a death by a signal are FAIL, as for any check; so is a
# missing tool.
project="$(setup_project budget-timeout "slow budget: timeout 0.2 sleep 5")"
expect_failure "$project" "a budget check that does not finish must fail"
grep -Fqx "FAIL  slow (exit 124, the budget check did not finish)" "$project/out.log" ||
  fail "a budget check that did not finish is not FAIL: $(cat "$project/out.log")"
project="$(setup_project budget-signal 'killed budget: sh -c '"'"'kill -TERM $$'"'"'')"
expect_failure "$project" "a budget check killed by a signal must fail"
grep -Eq "^FAIL  killed \(exit 1[0-9][0-9], the budget check did not finish\)" "$project/out.log" ||
  fail "a budget check killed by a signal is not FAIL: $(cat "$project/out.log")"
project="$(setup_project budget-no-tool "perf budget: mypy --bench")"
expect_failure "$project" "a budget check without its tool must fail"
grep -Fq "FAIL  perf (missing tool: mypy)" "$project/out.log" || fail "a budget check without its tool is not FAIL"

# So are the statuses 125 to 127, which 'timeout' and the shell use for a check
# that could not run: an error of 'timeout' itself (125), and a command that is
# not executable (126) or not found (127) behind 'timeout' or anywhere in the
# command. Nothing was measured: FAIL, not BUDGET.
project="$(setup_project budget-timeout-error "perf budget: timeout --bogus 1 true")"
expect_failure "$project" "a budget check whose 'timeout' fails must fail"
grep -Fqx "FAIL  perf (exit 125, the budget check could not run)" "$project/out.log" ||
  fail "a budget check with a failing 'timeout' is not FAIL: $(cat "$project/out.log")"
project="$(setup_project budget-not-executable "perf budget: timeout 5 ./scripts/verify.conf")"
expect_failure "$project" "a budget check whose command is not executable must fail"
grep -Fqx "FAIL  perf (exit 126, the budget check could not run)" "$project/out.log" ||
  fail "a budget check with a command that is not executable is not FAIL: $(cat "$project/out.log")"
project="$(setup_project budget-not-found "perf budget: timeout 5 ./no-such-measurement")"
expect_failure "$project" "a budget check whose command is not found must fail"
grep -Fqx "FAIL  perf (exit 127, the budget check could not run)" "$project/out.log" ||
  fail "a budget check with a command that is not found is not FAIL: $(cat "$project/out.log")"
project="$(setup_project budget-not-found-later "perf budget: true && ./no-such-measurement")"
expect_failure "$project" "a budget check whose later command is not found must fail"
grep -Fqx "FAIL  perf (exit 127, the budget check could not run)" "$project/out.log" ||
  fail "a budget check with a later command that is not found is not FAIL: $(cat "$project/out.log")"
# The ordinary statuses up to 123 stay BUDGET, and so does 128: no utility
# returns it for a command that was not invoked, so a measurement may use it
# like any other status (review 02 M1).
project="$(setup_project budget-exit-128 "perf budget: sh -c 'echo over; exit 128'")"
run_with "$project" || fail "a budget check that exits 128 failed the verification"
grep -Fqx "BUDGET  perf (exit 128)" "$project/out.log" || fail "a budget check that exits 128 is not BUDGET: $(cat "$project/out.log")"
project="$(setup_project budget-exit-123 "perf budget: sh -c 'echo over; exit 123'")"
run_with "$project" || fail "a budget check that exits 123 failed the verification"
grep -Fqx "BUDGET  perf (exit 123)" "$project/out.log" || fail "a budget check that exits 123 is not BUDGET: $(cat "$project/out.log")"

# A budget with an empty output says so, and the exit status is kept.
project="$(setup_project budget-silent "perf budget: sh -c 'exit 3'")"
run_with "$project" || fail "a silent budget over its target failed the verification"
grep -Fqx "BUDGET  perf (exit 3)" "$project/out.log" || fail "the silent budget is not BUDGET"
grep -Fqx "        (no output)" "$project/out.log" || fail "the summary does not say that the budget check had no output"

# A budget belongs to its group like any check: --only runs it there, and a
# partial run passes with BUDGET too.
project="$(setup_project budget-groups "lint: ruff check ." "$over")"
run_with "$project" --only code || fail "--only with an exceeded budget failed"
grep -Fqx "BUDGET  perf (exit 2)" "$project/out.log" || fail "--only did not show the budget as BUDGET"
[[ ! -e "$project/tools.log" ]] || fail "--only code ran a check of another group"
run_with "$project" --only default || fail "--only default failed"
if grep -Fq "BUDGET" "$project/out.log"; then fail "--only default ran the budget of another group"; fi
run_with "$project" --groups || fail "--groups failed with a budget"
[[ "$(tr '\n' ',' <"$project/out.log")" == "default,code," ]] || fail "--groups lacks the group of a budget: $(cat "$project/out.log")"

# The syntax is exact: 'budget' stands before the colon, after the name or
# the group, separated by a space. Anything else is a name or malformed, and
# 'paths' is not a check.
project="$(setup_project budget-is-a-name "perfbudget: ruff check .")"
run_with "$project" || fail "a name that ends in 'budget' failed"
grep -Fqx "PASS  perfbudget" "$project/out.log" || fail "a name that ends in 'budget' is not an ordinary check"
project="$(setup_project budget-no-space "perf [code]budget: ruff check .")"
expect_failure "$project" "'budget' glued to the group must be malformed"
project="$(setup_project budget-space-before-colon "perf budget : ruff check .")"
expect_failure "$project" "a space before the colon must be malformed"
project="$(setup_project budget-no-group-space "perf[code] budget: ruff check .")"
run_with "$project" || fail "a group without a space before it failed with a budget"
project="$(setup_workflow_project budget-paths)"
printf 'paths budget: tools\nself-test: pytest\n' >"$project/scripts/verify-workflow.conf"
expect_failure "$project" "'paths' as a budget must be refused"
grep -Fq "'paths' is not a check and cannot be a budget" "$project/out.log" || fail "the refusal of 'paths budget:' did not say why"

# The budget results are recorded with the pass, next to the record, so the
# scripts that reuse the pass can show the measurement. A run without a
# budget check keeps no budget record, and a failing run removes both.
budgets="/.agents/verification/budgets"
project="$(setup_recorded_project recorded-budgets)"
printf '%s\n' "lint: ruff check ." "$over" "size budget: echo 12kB" >"$project/scripts/verify.conf"
git -C "$project" commit -qam "Declare budgets"
expect_checks_ran "$project" "nothing was recorded yet" --reuse
[[ -f "$project$record" ]] || fail "a passed run with an exceeded budget was not recorded"
[[ -f "$project$budgets" ]] || fail "the budget results were not recorded with the pass"
grep -Fqx "budget: perf" "$project$budgets" && grep -Fqx "status: exceeded" "$project$budgets" &&
  grep -Fqx "exit: 2" "$project$budgets" && grep -Fqx "  1.4 s, target 1.0 s" "$project$budgets" ||
  fail "the budget record lacks the result of the exceeded budget: $(cat "$project$budgets")"
grep -Fqx "budget: size" "$project$budgets" && grep -Fqx "status: within" "$project$budgets" ||
  fail "the budget record lacks the budget within its target: $(cat "$project$budgets")"
[[ -z "$(git -C "$project" status --porcelain)" ]] || fail "the budget record changed the working tree"
expect_reused "$project" "the content is unchanged" --reuse
grep -Fqx "  budget perf exceeded: 1.4 s, target 1.0 s" "$project/out.log" || fail "a reused pass does not show its budget results: $(cat "$project/out.log")"
grep -Fqx "  budget size within its target" "$project/out.log" || fail "a reused pass does not show the budget within its target"
[[ -f "$project$budgets" ]] || fail "a reused pass lost the budget record"
run_with "$project" --only code || fail "a partial run with a budget failed"
[[ -f "$project$budgets" ]] || fail "a partial run removed the budget record of a complete run"
if MOCK_RUFF_EXIT=1 run_with "$project"; then fail "a failing run with a budget returned success"; fi
[[ ! -e "$project$record" && ! -e "$project$budgets" ]] || fail "a failing run left the record or the budget record"
printf '%s\n' "lint: ruff check ." >"$project/scripts/verify.conf"
git -C "$project" commit -qam "Drop the budgets"
run_with "$project" || fail "a run without budgets failed"
[[ -f "$project$record" && ! -e "$project$budgets" ]] || fail "a run without a budget check kept a budget record"

# The library reads the record and reports it; the report is for a person:
# one line per budget, the whole output of an exceeded one, or the last lines
# with a pointer to the whole output when the caller asks for a limit.
(
  source "$source_root/scripts/lib/fingerprint.sh"
  source "$source_root/scripts/lib/verification.sh"
  file="$tmp/budgets.txt"
  : >"$file"
  printf 'a\nb\nc\n' >"$tmp/out3"
  : >"$tmp/out0"
  printf 'one\n' >"$tmp/out1"
  verification_budget_add "$file" long exceeded 1 "$tmp/out3"
  verification_budget_add "$file" silent exceeded 7 "$tmp/out0"
  verification_budget_add "$file" fine within 0 "$tmp/out1"
  report="$(verification_budget_report <"$file")"
  [[ "$report" == "$(printf 'budget long exceeded:\n  a\n  b\n  c\nbudget silent exceeded (exit 7, no output)\nbudget fine within its target')" ]] ||
    { echo "the budget report is wrong: $report" >&2; exit 1; }
  report="$(verification_budget_report 2 <"$file")"
  [[ "$report" == "$(printf 'budget long exceeded:\n  (1 earlier lines of the output left out)\n  b\n  c\nbudget silent exceeded (exit 7, no output)\nbudget fine within its target')" ]] ||
    { echo "the limited budget report is wrong: $report" >&2; exit 1; }
  report="$(verification_budget_report 2 "the record" <"$file")"
  [[ "$report" == "$(printf 'budget long exceeded:\n  (1 earlier lines of the output left out; the full output is in the record)\n  b\n  c\nbudget silent exceeded (exit 7, no output)\nbudget fine within its target')" ]] ||
    { echo "the limited budget report does not say where the full output is: $report" >&2; exit 1; }
  [[ "$(verification_budget_report 3 "the record" <"$file" | head -1)" == "budget long exceeded:" && "$(verification_budget_report 3 <"$file" | sed -n 2p)" == "  a" ]] ||
    { echo "a limit that the output does not reach left lines out" >&2; exit 1; }
  verification_budgets_exceeded "$(cat "$file")" || { echo "an exceeded budget was not seen" >&2; exit 1; }
  if verification_budgets_exceeded "budget: fine"$'\n'"status: within"; then echo "a budget within its target counted as exceeded" >&2; exit 1; fi
  [[ "$(verification_budgets_json "$file" | jq -c 'map([.name, .status, .exit, .output])')" == '[["long","exceeded",1,"a\nb\nc"],["silent","exceeded",7,""],["fine","within",0,"one"]]' ]] ||
    { echo "the budget results as JSON are wrong: $(verification_budgets_json "$file")" >&2; exit 1; }
  [[ "$(verification_budgets_json "$tmp/none")" == "[]" ]] || { echo "a missing budget file is not an empty list" >&2; exit 1; }
) || fail "the budget functions of lib/verification.sh"

# Inside a recorded run, the verification event carries the budget results,
# also for a reused pass; a partial run records nothing, as before.
project="$(setup_recorded_project budgets-inside-run)"
cp "$source_root/scripts/lib/records.sh" "$project/scripts/lib/records.sh"
printf '%s\n' "lint [code]: ruff check ." "$over" >"$project/scripts/verify.conf"
git -C "$project" commit -qam "Declare a budget"
: >"$tmp/budget-run.jsonl"
budget_run() {
  RECORDS_RUN_ID=parent-run RECORDS_FILE="$tmp/budget-run.jsonl" RECORDS_COMMAND=scripts/run-feature.sh \
    RECORDS_KIND=feature RECORDS_SUBJECT=1 run_with "$@"
}
budget_run "$project" --only code || fail "a partial run with a budget failed inside a run"
[[ ! -s "$tmp/budget-run.jsonl" ]] || fail "a partial run with a budget wrote into the record of its run"
budget_run "$project" || fail "verify.sh with a budget failed inside a recorded run"
jq -e -s 'any(.type == "verification" and .status == 0 and .reused == false
  and (.budgets | length) == 1 and .budgets[0].name == "perf" and .budgets[0].status == "exceeded"
  and .budgets[0].exit == 2 and .budgets[0].output == "1.4 s, target 1.0 s")' "$tmp/budget-run.jsonl" >/dev/null ||
  fail "the verification event lacks the budget results: $(cat "$tmp/budget-run.jsonl")"
budget_run "$project" --reuse || fail "a reused pass with a budget failed inside a recorded run"
jq -e -s 'any(.type == "verification" and .reused == true and (.budgets | length) == 1 and .budgets[0].name == "perf")' "$tmp/budget-run.jsonl" >/dev/null ||
  fail "the verification event of a reused pass lacks the budget results: $(cat "$tmp/budget-run.jsonl")"
printf '%s\n' "lint [code]: ruff check ." >"$project/scripts/verify.conf"
budget_run "$project" || fail "verify.sh without a budget failed inside a recorded run"
jq -e -s 'any(.type == "verification" and .reused == false and .budgets == [])' "$tmp/budget-run.jsonl" >/dev/null ||
  fail "a verification without a budget check does not record an empty list"

# Every check is timed. The durations are recorded with the pass, next to
# the record, and in the verification event of a run; a reused pass ran no
# check. 'budget-seconds: <n>' in either file is the target for the duration
# of all checks of that file: over it, the summary shows BUDGET with the
# total, the target, and the slowest checks, the verification passes when
# every check passed, and the result is recorded as a budget result.
summary_of() {
  sed -n '/^== Verification summary ==$/,$p' "$1/out.log"
}
durations="/.agents/verification/durations"
project="$(setup_recorded_project durations)"
cp "$source_root/scripts/lib/records.sh" "$project/scripts/lib/records.sh"
printf '%s\n' "lint: ruff check ." "slow: sleep 1.2" "medium: sleep 0.3" >"$project/scripts/verify.conf"
git -C "$project" add -A
git -C "$project" commit -qm "A slow check"
run_with "$project" || fail "a run with a slow check failed"
plain_summary="$(summary_of "$project")"
grep -Fq -- "-- slow took 1." "$project/out.log" || fail "the duration of a check is not shown when it ran: $(cat "$project/out.log")"
[[ "$(cut -f1,2,4 "$project$durations" | tr '\t\n' ' ;')" == "lint scripts/verify.conf pass;slow scripts/verify.conf pass;medium scripts/verify.conf pass;" ]] ||
  fail "the durations are not recorded with the pass: $(cat "$project$durations" 2>/dev/null)"
[[ "$(awk -F '\t' '$1 == "slow" { print ($3 >= 1200) }' "$project$durations")" == "1" ]] ||
  fail "the duration of the slow check is not measured: $(cat "$project$durations")"
[[ ! -e "$project$budgets" ]] || fail "a run without a budget kept a budget record"
[[ -z "$(git -C "$project" status --porcelain)" ]] || fail "the durations changed the working tree"

# Without the line the summary is the one it always was; with a target that
# is not exceeded, it is the same, and only the durations are recorded.
[[ "$plain_summary" == "$(printf '%s\n' "== Verification summary ==" "PASS  lint" "PASS  slow" "PASS  medium" "Verification passed.")" ]] ||
  fail "the summary without a target changed: $plain_summary"
printf '%s\n' "budget-seconds: 100" "lint: ruff check ." "slow: sleep 1.2" "medium: sleep 0.3" >"$project/scripts/verify.conf"
git -C "$project" commit -qam "A target that holds"
run_with "$project" || fail "a run within its target failed"
[[ "$(summary_of "$project")" == "$plain_summary" ]] || fail "a target that is not exceeded changed the summary: $(summary_of "$project")"
[[ ! -e "$project$budgets" && -s "$project$durations" ]] || fail "a target that is not exceeded kept a budget result, or lost the durations"

# Over the target: BUDGET with the total, the target, and the slowest checks
# first; the verification passes and the result is a budget result.
printf '%s\n' "budget-seconds: 1" "lint: ruff check ." "slow: sleep 1.2" "medium: sleep 0.3" >"$project/scripts/verify.conf"
git -C "$project" commit -qam "A target that does not hold"
: >"$tmp/duration-run.jsonl"
duration_run() {
  RECORDS_RUN_ID=parent-run RECORDS_FILE="$tmp/duration-run.jsonl" RECORDS_COMMAND=scripts/run-feature.sh \
    RECORDS_KIND=feature RECORDS_SUBJECT=1 run_with "$@"
}
duration_run "$project" || fail "a run over the target of its duration failed: $(cat "$project/out.log")"
grep -Eqx 'BUDGET  duration of scripts/verify\.conf \(1\.[5-9]s, target 1s\)' "$project/out.log" ||
  fail "the summary lacks the BUDGET line with the total and the target: $(cat "$project/out.log")"
[[ "$(summary_of "$project" | grep -A3 '^BUDGET' | tail -n 3 | sed -E 's/ [0-9]+\.[0-9]s$//' | tr '\n' ';')" == "        slow;        medium;        lint;" ]] ||
  fail "the summary lacks the slowest checks, slowest first: $(summary_of "$project")"
grep -Fq "Verification passed." "$project/out.log" || fail "a verification over the target of its duration did not pass"
if grep -Fq "FAIL" "$project/out.log"; then fail "a duration over its target was reported as a failure"; fi
grep -Fqx "budget: duration of scripts/verify.conf" "$project$budgets" && grep -Fqx "status: exceeded" "$project$budgets" &&
  grep -Eq '^  slow [0-9.]+s$' "$project$budgets" ||
  fail "the duration over its target is not recorded as a budget result: $(cat "$project$budgets" 2>/dev/null)"
jq -e -s 'any(.type == "verification" and .status == 0 and .reused == false
  and (.budgets | map(select(.name == "duration of scripts/verify.conf" and .status == "exceeded")) | length) == 1
  and (.checks | map(.name)) == ["lint", "slow", "medium"]
  and (.checks | map(select(.name == "slow" and .seconds >= 1.2 and .result == "pass" and .config == "scripts/verify.conf")) | length) == 1)' \
  "$tmp/duration-run.jsonl" >/dev/null ||
  fail "the verification event lacks the durations or the budget result: $(cat "$tmp/duration-run.jsonl")"
# A reused pass shows the measurement and ran no check.
duration_run "$project" --reuse || fail "a reused pass over the target failed"
grep -Fq "  budget duration of scripts/verify.conf exceeded:" "$project/out.log" || fail "a reused pass does not show the duration budget: $(cat "$project/out.log")"
jq -e -s 'any(.type == "verification" and .reused == true and .checks == [] and (.budgets | length) == 1)' "$tmp/duration-run.jsonl" >/dev/null ||
  fail "the verification event of a reused pass is wrong: $(cat "$tmp/duration-run.jsonl")"

# A failing check still fails the verification; the measurement is shown.
if MOCK_RUFF_EXIT=1 duration_run "$project"; then fail "a failing check passed next to a target for the duration"; fi
grep -Fqx "FAIL  lint (exit 1)" "$project/out.log" || fail "the failing check is not FAIL next to a target for the duration"
grep -Fq "BUDGET  duration of scripts/verify.conf" "$project/out.log" || fail "the duration is not measured in a failing run"
[[ ! -e "$project$record" && ! -e "$project$durations" ]] || fail "a failing run left the record or the durations"
jq -e -s 'any(.type == "verification" and .status == 1 and (.checks | map(select(.name == "lint" and .result == "fail")) | length) == 1)' \
  "$tmp/duration-run.jsonl" >/dev/null || fail "the run record lacks the durations of a failing run"

# A partial run measures the checks it runs and compares with nothing.
printf '%s\n' "budget-seconds: 1" "lint: ruff check ." "slow [slow]: sleep 1.2" >"$project/scripts/verify.conf"
run_with "$project" --only slow || fail "a partial run with a target for the duration failed"
grep -Fq -- "-- slow took 1." "$project/out.log" || fail "a partial run does not measure its checks"
if grep -Fq "BUDGET" "$project/out.log"; then fail "a partial run compared with the target for the duration"; fi

# The target of a file covers only its checks, and self-tests that did not
# run compare with nothing.
project="$(setup_workflow_project duration-workflow)"
printf '%s\n' "budget-seconds: 1" "lint: sleep 1.2" >"$project/scripts/verify.conf"
printf '%s\n' "budget-seconds: 1" "paths: tools" "self-test: pytest" >"$project/scripts/verify-workflow.conf"
git -C "$project" commit -qam "Targets for both files"
run_with "$project" || fail "a run with targets in both files failed"
grep -Fq "SKIP  workflow self-tests" "$project/out.log" || fail "the self-tests ran although no workflow file changed"
grep -Fq "BUDGET  duration of scripts/verify.conf" "$project/out.log" || fail "the project checks were not compared with their target"
if grep -Fq "duration of scripts/verify-workflow.conf" "$project/out.log"; then fail "self-tests that did not run were compared with their target"; fi
run_with "$project" --all || fail "a run of every check with targets in both files failed"
if grep -Fq "duration of scripts/verify-workflow.conf" "$project/out.log"; then
  fail "the self-tests were charged with the duration of the project checks: $(cat "$project/out.log")"
fi
printf '%s\n' "budget-seconds: 1" "paths: tools" "self-test: sleep 1.2" >"$project/scripts/verify-workflow.conf"
run_with "$project" --all || fail "self-tests over their target failed"
grep -Eqx 'BUDGET  duration of scripts/verify-workflow\.conf \(1\.[2-9]s, target 1s\)' "$project/out.log" ||
  fail "the self-tests were not compared with their own target: $(cat "$project/out.log")"

# The line is exact: a whole number above 0, once per file, no group, no
# budget check, and never a check of its own.
for line in "budget-seconds: 0" "budget-seconds: 1.5" "budget-seconds: ten" "budget-seconds [code]: 5" "budget-seconds budget: 5"; do
  project="$(setup_project duration-malformed "$line" "lint: ruff check .")"
  expect_failure "$project" "'$line' must be refused"
  grep -Fq "'budget-seconds'" "$project/out.log" || fail "the refusal of '$line' did not say why: $(cat "$project/out.log")"
  [[ ! -e "$project/tools.log" ]] || fail "checks ran despite '$line'"
  rm -rf "$project"
done
project="$(setup_project duration-twice "budget-seconds: 5" "budget-seconds: 6" "lint: ruff check .")"
expect_failure "$project" "'budget-seconds' twice must be refused"
grep -Fq "declared more than once" "$project/out.log" || fail "the refusal of a second 'budget-seconds' did not say why"
project="$(setup_project duration-only "budget-seconds: 5")"
expect_failure "$project" "a file with a target and no check must be refused"

# The library turns the durations into JSON for the run record and skips a
# damaged line.
(
  source "$source_root/scripts/lib/verification.sh"
  file="$tmp/durations.txt"
  : >"$file"
  verification_duration_add "$file" slow scripts/verify.conf 1234 pass
  verification_duration_add "$file" over scripts/verify-workflow.conf 5 budget
  printf 'damaged line\n' >>"$file"
  [[ "$(verification_durations_json "$file" | jq -c 'map([.name, .config, .seconds, .result])')" == '[["slow","scripts/verify.conf",1.234,"pass"],["over","scripts/verify-workflow.conf",0.005,"budget"]]' ]] ||
    { echo "the durations as JSON are wrong: $(verification_durations_json "$file")" >&2; exit 1; }
  [[ "$(verification_durations_json "$tmp/none")" == "[]" ]] || { echo "a missing durations file is not an empty list" >&2; exit 1; }
) || fail "the duration functions of lib/verification.sh"

# Every self-test passes through tests/lib-fakes.sh before it starts anything.
for test in "$source_root"/tests/*-test.sh; do
  grep -Eq '^source "\$(source_)?root/tests/lib-fakes\.sh"$' "$test" ||
    fail "${test#"$source_root/"} does not source tests/lib-fakes.sh"
done

echo "verify tests passed"
