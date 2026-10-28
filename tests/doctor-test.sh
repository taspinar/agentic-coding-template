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
  # The sandbox check needs mkdir, rm and sleep whatever else is present.
  for tool in mkdir rm sleep "$@"; do
    case "$tool" in
      git)
        cat >"$bin/git" <<FAKE
#!$bash_path
case "\$*" in
  "rev-parse --show-toplevel") exit "\${MOCK_REPO_EXIT:-0}" ;;
  "remote get-url origin") exit "\${MOCK_ORIGIN_EXIT:-0}" ;;
  "ls-remote --exit-code --heads origin main") exit "\${MOCK_MAIN_EXIT:-0}" ;;
  "push --dry-run --quiet origin HEAD:refs/heads/doctor-push-check") exit "\${MOCK_PUSH_EXIT:-0}" ;;
  "config user.name") [[ -z "\${MOCK_GIT_NO_IDENTITY:-}" ]] || exit 1; echo "Test User"; exit 0 ;;
  "config user.email") [[ -z "\${MOCK_GIT_NO_IDENTITY:-}" ]] || exit 1; echo "test@example.com"; exit 0 ;;
  "-C "*" init -q") exit 0 ;;
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
      jq | mkdir | rm | sleep)
        # The real tools: doctor.sh reads a settings file with jq, lays out
        # the scratch repository of the Codex sandbox check with mkdir and
        # rm, and waits for the session with sleep.
        printf '#!%s\nexec %q "$@"\n' "$bash_path" "$(command -v "$tool")" >"$bin/$tool"
        ;;
      codex)
        # Answers 'login status' and 'exec'. For 'exec' it behaves as an
        # obedient model: it runs the probe that the prompt names ('bash
        # <path>') and writes the final message. MOCK_CODEX_DENIED names a
        # directory of the scratch repository that the sandbox would refuse;
        # MOCK_CODEX_NO_PROBE is a model that answers without running the
        # command; MOCK_CODEX_HANG a session that never ends.
        cat >"$bin/codex" <<FAKE
#!$bash_path
printf '%s\n' "\$*" >>"\${MOCK_CODEX_LOG:-/dev/null}"
case "\$1" in
  login) exit "\${MOCK_CODEX_LOGIN_EXIT:-0}" ;;
  --version) echo "codex-cli 0.0.0-fake"; exit 0 ;;
  exec) ;;
  *) echo "unexpected codex call: \$*" >&2; exit 97 ;;
esac
if [[ -n "\${MOCK_CODEX_HANG:-}" ]]; then sleep 60; exit 0; fi
output=""
probe=""
args=("\$@")
for ((i = 0; i < \${#args[@]}; i++)); do
  [[ "\${args[\$i]}" != "--output-last-message" ]] || output="\${args[\$((i + 1))]}"
done
prompt="\${args[\${#args[@]} - 1]}"
[[ ! "\$prompt" =~ bash\ ([^[:space:]]+) ]] || probe="\${BASH_REMATCH[1]}"
if [[ -z "\${MOCK_CODEX_NO_PROBE:-}" && -n "\$probe" ]]; then
  [[ -z "\${MOCK_CODEX_DENIED:-}" ]] || $(command -v chmod) a-w "\${probe%/*}/\$MOCK_CODEX_DENIED"
  "\$BASH" "\$probe" >/dev/null 2>&1 || true
  [[ -z "\${MOCK_CODEX_DENIED:-}" ]] || $(command -v chmod) u+w "\${probe%/*}/\$MOCK_CODEX_DENIED"
fi
[[ -z "\$output" ]] || echo "done" >"\$output"
exit "\${MOCK_CODEX_EXEC_EXIT:-0}"
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

# And an explicit attribution preference, 'allowed' unless a test sets
# another, so the result does not depend on the repository's own file.
attribution="$tmp/attribution.conf"
printf 'agent-attribution: allowed\n' >"$attribution"
claude_settings="$tmp/claude-settings.json"

# The codex here is a fake, so the test runs also inside a Codex session,
# which the real check skips (CODEX_SESSION_ID, CODEX_THREAD_ID): an
# implementer's own run of verify.sh gets here.
run_doctor() {
  PATH="$1" AGENT_CONFIG_FILE="$config" ATTRIBUTION_CONFIG_FILE="$attribution" \
    ATTRIBUTION_CLAUDE_SETTINGS_FILE="$claude_settings" TMPDIR="$tmp/scratch" DOCTOR_CODEX_TIMEOUT="${DOCTOR_CODEX_TIMEOUT:-20}" \
    CODEX_SESSION_ID="${MOCK_CODEX_SESSION_ID:-}" CODEX_THREAD_ID= \
    "$bash_path" "$script" >"$tmp/out.log" 2>&1
}
mkdir -p "$tmp/scratch"

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
export MOCK_CODEX_LOG="$tmp/codex.log"
: >"$MOCK_CODEX_LOG"
run_doctor "$bin" || {
  cat "$tmp/out.log" >&2
  fail "complete environment was reported as a failure"
}
if grep -Eq '^(FAILED|WARNING)' "$tmp/out.log"; then
  cat "$tmp/out.log" >&2
  fail "complete environment reported a problem"
fi
grep -Eq '^OK +git has a commit identity' "$tmp/out.log" || fail "the commit identity was not reported"

# The Codex sandbox check: the implementer uses codex, so a real unattended
# session ran in a scratch repository, with the writable roots of agent.sh,
# and every runtime directory was writable.
grep -Eq '^OK +codex can write the runtime directories under .agents/ inside its sandbox' "$tmp/out.log" ||
  fail "the sandbox check did not report the writable runtime directories: $(cat "$tmp/out.log")"
grep -q '^exec .*--sandbox workspace-write.*sandbox_workspace_write.writable_roots=\[' "$MOCK_CODEX_LOG" ||
  grep -q '^exec .*sandbox_workspace_write.writable_roots=\[.*--sandbox workspace-write' "$MOCK_CODEX_LOG" ||
  fail "the sandbox check did not run codex exec with the writable roots of agent.sh: $(cat "$MOCK_CODEX_LOG")"
grep -q '^exec .*/doctor-codex-sandbox\.' "$MOCK_CODEX_LOG" || fail "the sandbox check did not run in a scratch repository"
[[ -z "$(ls -A "$tmp/scratch")" ]] || fail "the sandbox check left its scratch repository behind: $(ls -A "$tmp/scratch")"
# A directory the sandbox refuses fails the check, with its path.
if [[ "$(id -u)" -ne 0 ]]; then
  MOCK_CODEX_DENIED=.agents/summaries expect_failure "$bin" "codex cannot write .agents/summaries inside its sandbox"
  grep -Fq "writable roots" "$tmp/out.log" || fail "the failed sandbox check does not name the mechanism"
  [[ -z "$(ls -A "$tmp/scratch")" ]] || fail "the failed sandbox check left its scratch repository behind"
fi
# A model that answers without running the probe proves nothing: one more
# session, then a failure that shows the answer.
: >"$MOCK_CODEX_LOG"
MOCK_CODEX_NO_PROBE=1 expect_failure "$bin" "codex did not write the runtime files under .agents/ inside its sandbox"
grep -Fq "The session answered: done" "$tmp/out.log" || fail "the final message of the session was not shown"
[[ "$(grep -c '^exec' "$MOCK_CODEX_LOG")" -eq 2 ]] || fail "a model that did not run the probe was not given a second session: $(cat "$MOCK_CODEX_LOG")"
[[ -z "$(ls -A "$tmp/scratch")" ]] || fail "the failed sandbox check left its scratch repository behind"
# Codex not logged in: a warning, and no session.
: >"$MOCK_CODEX_LOG"
MOCK_CODEX_LOGIN_EXIT=1 run_doctor "$bin" || { cat "$tmp/out.log" >&2; fail "a codex that is not logged in was reported as a failure"; }
grep -Eq '^WARNING +whether codex can write .* was not checked: codex is not logged in' "$tmp/out.log" ||
  fail "a codex that is not logged in did not skip the sandbox check with a warning: $(cat "$tmp/out.log")"
if grep -q '^exec' "$MOCK_CODEX_LOG"; then fail "a session was started although codex is not logged in"; fi
# Inside a Codex session, which cannot start another one, the check is
# skipped with a warning and no session.
: >"$MOCK_CODEX_LOG"
MOCK_CODEX_SESSION_ID=0123 run_doctor "$bin" || { cat "$tmp/out.log" >&2; fail "the doctor inside a Codex session was reported as a failure"; }
grep -Eq '^WARNING +whether codex can write .* was not checked: this runs inside a Codex session' "$tmp/out.log" ||
  fail "the sandbox check inside a Codex session was not skipped with a warning: $(cat "$tmp/out.log")"
if grep -q '^exec' "$MOCK_CODEX_LOG"; then fail "a session was started inside a Codex session"; fi
# A session that fails is a warning with its reason, not a failure of the host.
MOCK_CODEX_EXEC_EXIT=3 MOCK_CODEX_NO_PROBE=1 run_doctor "$bin" || { cat "$tmp/out.log" >&2; fail "a failed codex session was reported as a failure of the host"; }
grep -Eq '^WARNING +whether codex can write .* the codex session failed \(status 3\)' "$tmp/out.log" ||
  fail "a failed codex session was not reported as a warning: $(cat "$tmp/out.log")"
# A session that does not end is stopped and reported, and does not hang the
# doctor. The session gets the configured seconds, no fewer: a wait that
# returns at once would stop a slow but sound session. SECONDS has whole
# seconds, so a stop after at least 3 s of wall-clock time shows as 3 or more.
started=$SECONDS
MOCK_CODEX_HANG=1 DOCTOR_CODEX_TIMEOUT=3 run_doctor "$bin" || { cat "$tmp/out.log" >&2; fail "a stopped codex session was reported as a failure"; }
elapsed=$((SECONDS - started))
grep -Eq '^WARNING +the codex session that checks the sandbox did not end within 3 seconds' "$tmp/out.log" ||
  fail "a session that does not end was not stopped and reported: $(cat "$tmp/out.log")"
[[ "$elapsed" -ge 3 ]] || fail "the session was stopped after $elapsed s, before the configured 3 s had passed"
[[ "$elapsed" -le 30 ]] || fail "the session was stopped after $elapsed s, long after the configured 3 s"
[[ -z "$(ls -A "$tmp/scratch")" ]] || fail "the stopped sandbox check left its scratch repository behind"
# No Codex role with write access: no session, and no line about the sandbox.
printf 'implementer: claude model-a\nreviewer: codex model-b\n' >"$config"
: >"$MOCK_CODEX_LOG"
run_doctor "$bin" || { cat "$tmp/out.log" >&2; fail "a read-only codex role was reported as a failure"; }
if grep -q '^exec' "$MOCK_CODEX_LOG"; then fail "the sandbox was checked although no codex role has write access"; fi
if grep -Fq "sandbox" "$tmp/out.log"; then fail "the sandbox was mentioned although no codex role has write access"; fi
# A level line that gives a write role to codex is enough.
printf 'implementer: claude model-a\nimplementer@high: codex model-c\nreviewer: claude model-b\n' >"$config"
run_doctor "$bin" || { cat "$tmp/out.log" >&2; fail "a codex level line was reported as a failure"; }
grep -q '^exec .*--model model-c' "$MOCK_CODEX_LOG" || fail "the sandbox was not checked with the model of the level line: $(cat "$MOCK_CODEX_LOG")"
printf 'implementer: codex model-a\nreviewer: claude model-b\n' >"$config"
# Codex configured for a write role but not installed: the missing CLI fails,
# and the sandbox check says it was skipped.
bin_no_codex="$(make_bin no-codex git gh jq claude)"
expect_failure "$bin_no_codex" "codex CLI is not installed"
grep -Eq '^WARNING +whether codex can write .* was not checked: codex is not installed' "$tmp/out.log" ||
  fail "the sandbox check was not reported as skipped without codex: $(cat "$tmp/out.log")"

# Git without a commit identity fails, with both commands to set one.
MOCK_GIT_NO_IDENTITY=1 expect_failure "$bin" "git has no commit identity"
grep -Fq 'git config --global user.name' "$tmp/out.log" && grep -Fq 'git config --global user.email' "$tmp/out.log" ||
  fail "the commands that set the identity were not shown: $(cat "$tmp/out.log")"

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
# Also an unsupported provider or an invalid model on the plain line of a
# role, reported with its line.
printf 'implementer: claude model-a\nreviewer: copilot model-b\n' >"$config"
expect_failure "$bin" "agent configuration is invalid"
grep -Fq "unsupported agent 'copilot' for role 'reviewer' on line 2" "$tmp/out.log" || fail "the unsupported provider was not named with its line: $(cat "$tmp/out.log")"
printf 'implementer: claude model-a\nreviewer: codex --fallback\n' >"$config"
expect_failure "$bin" "agent configuration is invalid"
grep -Fq "for role 'reviewer' on line 2" "$tmp/out.log" || fail "the invalid model was not named with its line: $(cat "$tmp/out.log")"


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
