#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$source_root/tests/lib-fakes.sh"
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
if [[ "\$1" == "api" ]]; then
  [[ -z "\${MOCK_GH_API_FAIL:-}" ]] || exit 1
  case "\$2" in
    "repos/{owner}/{repo}/rules/branches/main") echo "\${MOCK_RULESET_CHECKS:-1}" ;;
    "repos/{owner}/{repo}/branches/main") echo "\${MOCK_CLASSIC_CHECKS:-0}" ;;
    *) echo "unexpected gh api call: \$*" >&2; exit 97 ;;
  esac
  exit 0
fi
echo "unexpected gh call: \$*" >&2
exit 97
FAKE
        ;;
      jq)
        # The real jq: doctor.sh reads a settings file with it.
        printf '#!%s\nexec %q "$@"\n' "$bash_path" "$(command -v jq)" >"$bin/jq"
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

# And an explicit attribution preference, 'allowed' unless a test sets
# another, so the result does not depend on the repository's own file.
attribution="$tmp/attribution.conf"
printf 'agent-attribution: allowed\n' >"$attribution"
claude_settings="$tmp/claude-settings.json"

run_doctor() {
  PATH="$1" AGENT_CONFIG_FILE="$config" ATTRIBUTION_CONFIG_FILE="$attribution" \
    ATTRIBUTION_CLAUDE_SETTINGS_FILE="$claude_settings" "$bash_path" "$script" >"$tmp/out.log" 2>&1
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

# A 'main' that can be merged into while its checks fail is a warning, whether
# the requirement would come from a ruleset or from classic branch protection.
expect_warning() {
  local pattern="$1"

  run_doctor "$bin" || {
    cat "$tmp/out.log" >&2
    fail "a warning was reported as a failure: $pattern"
  }
  grep -Eq "^WARNING +.*$pattern" "$tmp/out.log" || {
    cat "$tmp/out.log" >&2
    fail "expected a warning matching: $pattern"
  }
}

bin="$(make_bin protection git gh jq codex claude)"
MOCK_RULESET_CHECKS=0 expect_warning "accepts a merge while its checks fail"
MOCK_RULESET_CHECKS=0 MOCK_CLASSIC_CHECKS=2 run_doctor "$bin" || fail "classic branch protection was reported as a failure"
if grep -Eq '^WARNING' "$tmp/out.log"; then fail "classic branch protection was not recognised"; fi
MOCK_GH_API_FAIL=1 expect_warning "could not read the rules"

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


# Agent attribution: the preference is reported; an unconfigured project is
# a warning; with 'disabled', Claude Code's project settings are checked and
# what no setting can enforce is said as such; an unreadable preference fails.
bin="$(make_bin attribution git gh jq codex claude)"
printf 'implementer: codex model-a\nreviewer: claude model-b\n' >"$config"
run_doctor "$bin" || { cat "$tmp/out.log" >&2; fail "an allowed attribution was reported as a failure"; }
grep -Eq '^OK +agent attribution is allowed' "$tmp/out.log" || fail "the allowed preference was not reported"

rm "$attribution"
expect_warning "agent attribution is not configured"
grep -Eq '^WARNING +Claude' "$tmp/out.log" && fail "an unconfigured project was checked for Claude Code's settings"

printf 'agent-attribution: disabled\n' >"$attribution"
expect_warning "Claude Code's attribution is not turned off"
grep -Eq '^OK +agent attribution is disabled' "$tmp/out.log" || fail "the disabled preference was not reported"
grep -Eq '^NOTE +codex has no attribution setting' "$tmp/out.log" || fail "the clients that no setting reaches were not named"

printf '{"attribution": {"commit": "", "pr": ""}}\n' >"$claude_settings"
run_doctor "$bin" || { cat "$tmp/out.log" >&2; fail "a disabled attribution with matching Claude settings was reported as a failure"; }
grep -Eq "^OK +Claude Code's attribution is turned off" "$tmp/out.log" || fail "matching Claude settings were not recognised"
if grep -Eq '^WARNING' "$tmp/out.log"; then cat "$tmp/out.log" >&2; fail "matching Claude settings still warn"; fi

printf '{"attribution": {"commit": "Co-Authored-By: Claude <noreply@anthropic.com>", "pr": ""}}\n' >"$claude_settings"
expect_warning "Claude Code's attribution is not turned off"
printf '{"includeCoAuthoredBy": false}\n' >"$claude_settings"
run_doctor "$bin" || fail "the legacy Claude setting was reported as a failure"
grep -Eq "^OK +Claude Code's attribution is turned off" "$tmp/out.log" || fail "the legacy Claude setting was not recognised"

# Without jq the settings cannot be checked, and that is said.
bin="$(make_bin attribution-no-jq git gh codex claude)"
run_doctor "$bin" && fail "a missing jq passed"
grep -Eq "^WARNING +Claude Code's attribution .* could not be checked without jq" "$tmp/out.log" || fail "an uncheckable settings file was not reported"
bin="$(make_bin attribution git gh jq codex claude)"

printf 'agent-attribution: maybe\n' >"$attribution"
expect_failure "$bin" "attribution configuration is invalid"
printf 'agent-attribution: allowed\n' >"$attribution"

echo "doctor tests passed"
