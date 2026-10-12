#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
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
grep -F "types" "$project/out.log" | grep -Fq "mypy" ||
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

echo "verify tests passed"
