#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
script="$source_root/scripts/doctor.sh"
bash_path="$(command -v bash)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/doctor-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "doctor test failed: $*" >&2
  exit 1
}

# Builds a bin directory that contains only the named fake tools, so that
# PATH can be restricted to it and a missing tool is really missing.
make_bin() {
  local bin="$tmp/$1"
  shift

  mkdir -p "$bin"
  for tool in "$@"; do
    case "$tool" in
      git)
        cat >"$bin/git" <<FAKE
#!$bash_path
case "\$*" in
  "rev-parse --show-toplevel") exit "\${MOCK_REPO_EXIT:-0}" ;;
  "remote get-url origin") exit "\${MOCK_ORIGIN_EXIT:-0}" ;;
  "ls-remote --exit-code --heads origin main") exit "\${MOCK_MAIN_EXIT:-0}" ;;
  "push --dry-run --quiet origin HEAD:refs/heads/doctor-push-check") exit "\${MOCK_PUSH_EXIT:-0}" ;;
esac
echo "unexpected git call: \$*" >&2
exit 97
FAKE
        ;;
      gh)
        cat >"$bin/gh" <<FAKE
#!$bash_path
[[ "\$*" == "auth status" ]] && exit "\${MOCK_GH_AUTH_EXIT:-0}"
echo "unexpected gh call: \$*" >&2
exit 97
FAKE
        ;;
      *)
        printf '#!%s\nexit 0\n' "$bash_path" >"$bin/$tool"
        ;;
    esac
    chmod +x "$bin/$tool"
  done
  printf '%s\n' "$bin"
}

# Every run uses an explicit agent configuration instead of the repository's.
config="$tmp/agents.conf"
printf 'implementer: codex model-a\nreviewer: claude model-b\n' >"$config"

run_doctor() {
  PATH="$1" AGENT_CONFIG_FILE="$config" "$bash_path" "$script" >"$tmp/out.log" 2>&1
}

# Requires a non-zero exit with exactly one FAILED line, matching the pattern,
# so a run that fails for another reason does not pass.
expect_failure() {
  local bin="$1"
  local pattern="$2"

  if run_doctor "$bin"; then
    cat "$tmp/out.log" >&2
    fail "expected a failure matching: $pattern"
  fi
  if [[ "$(grep -c '^FAILED' "$tmp/out.log")" -ne 1 ]] ||
    ! grep -Eq "^FAILED +.*$pattern" "$tmp/out.log"; then
    cat "$tmp/out.log" >&2
    fail "expected exactly one FAILED line matching: $pattern"
  fi
}

# Everything available.
bin="$(make_bin all git gh jq codex claude)"
run_doctor "$bin" || {
  cat "$tmp/out.log" >&2
  fail "complete environment was reported as a failure"
}
if grep -Eq '^(FAILED|WARNING)' "$tmp/out.log"; then
  fail "complete environment reported a problem"
fi

# Each missing required tool fails and is identified.
bin="$(make_bin no-jq git gh codex claude)"
expect_failure "$bin" "jq is not installed"

bin="$(make_bin no-gh git jq codex claude)"
expect_failure "$bin" "gh\\) is not installed"

bin="$(make_bin no-git gh jq codex claude)"
expect_failure "$bin" "git is not installed"

# A jq that is too old for the workflow scripts fails.
bin="$(make_bin old-jq git gh jq codex claude)"
printf '#!%s\necho "jq-1.5"\n' "$bash_path" >"$bin/jq"
expect_failure "$bin" "jq jq-1.5 is too old"

# An unauthenticated GitHub CLI fails.
bin="$(make_bin all-unauthenticated git gh jq codex claude)"
MOCK_GH_AUTH_EXIT=1 expect_failure "$bin" "not authenticated"

# Running outside a repository, a missing origin, and an unreachable main fail.
MOCK_REPO_EXIT=128 expect_failure "$bin" "not inside a Git repository"
MOCK_ORIGIN_EXIT=2 expect_failure "$bin" "'origin' is not configured"
MOCK_MAIN_EXIT=2 expect_failure "$bin" "'main' is not reachable"
MOCK_PUSH_EXIT=128 expect_failure "$bin" "cannot push to origin"

# A missing agent CLI fails when a role uses it and is a warning otherwise.
bin="$(make_bin one-agent git gh jq claude)"
expect_failure "$bin" "codex CLI is not installed"

printf 'implementer: claude model-a\nreviewer: claude model-b\n' >"$config"
run_doctor "$bin" || {
  cat "$tmp/out.log" >&2
  fail "an agent CLI that no role uses must not be required"
}
grep -Eq '^WARNING +codex' "$tmp/out.log" || fail "unused missing agent was not reported as a warning"

# Invalid agent configuration fails.
printf 'implementer claude model-a\n' >"$config"
expect_failure "$bin" "agent configuration is invalid"

echo "doctor tests passed"
