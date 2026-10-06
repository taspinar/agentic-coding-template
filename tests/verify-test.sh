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

project="$(setup_project unknown-option "lint: ruff check .")"
if PATH="$tmp/bin:/usr/bin:/bin" "$project/scripts/verify.sh" --everything >"$project/out.log" 2>&1; then
  fail "an unknown option was accepted"
fi
[[ ! -e "$project/tools.log" ]] || fail "checks ran despite an unknown option"

echo "verify tests passed"
