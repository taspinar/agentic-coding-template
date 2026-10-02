#!/usr/bin/env bash

set -euo pipefail

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/agent-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "agent test failed: $*" >&2
  exit 1
}

source "$source_root/scripts/lib/agent.sh"

mkdir -p "$tmp/bin" "$tmp/work"
for provider in codex claude; do
  cat >"$tmp/bin/$provider" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
{
  echo "AGENT=$(basename "$0")"
  echo "PWD=$PWD"
  echo "ARGS=$*"
} >>"$MOCK_AGENT_LOG"
if [[ "$(basename "$0")" == "claude" ]]; then
  echo "claude report"
else
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--output-last-message" ]]; then
      echo "codex report" >"$2"
    fi
    shift
  done
fi
exit "${MOCK_AGENT_EXIT:-0}"
FAKE
  chmod +x "$tmp/bin/$provider"
done
export PATH="$tmp/bin:$PATH"
export MOCK_AGENT_LOG="$tmp/agent.log"

write_config() {
  printf '%s\n' "$@" >"$tmp/agents.conf"
}
export AGENT_CONFIG_FILE="$tmp/agents.conf"

# Prints "<provider> <model>" for a role, or fails like the calling script would.
resolve() {
  (
    agent_resolve "$tmp" "$@"
    printf '%s %s\n' "$AGENT_PROVIDER" "$AGENT_MODEL"
  ) 2>"$tmp/err.log"
}

expect_resolved() {
  local expected="$1"
  local actual
  shift

  actual="$(resolve "$@")" || {
    cat "$tmp/err.log" >&2
    fail "resolution failed for: $*"
  }
  [[ "$actual" == "$expected" ]] || fail "expected '$expected' for '$*', got '$actual'"
}

expect_rejected() {
  local description="$1"
  shift

  if resolve "$@" >/dev/null; then
    fail "expected rejection: $description"
  fi
}

write_config "# roles" "" "implementer: codex model-a" "reviewer: claude model-b"

# Provider and model come from the configuration per role.
expect_resolved "codex model-a" implementer
expect_resolved "claude model-b" reviewer

# Command-line values override the configuration.
expect_resolved "claude model-c" implementer claude model-c
expect_resolved "codex model-d" implementer "" model-d
expect_resolved "codex model-a" implementer codex ""

# No silent fallback: another provider without a model, and an unconfigured role.
expect_rejected "provider override without a model" implementer claude ""
expect_rejected "role without configuration" triage
expect_resolved "claude model-e" triage claude model-e

# Invalid selections fail.
expect_rejected "unknown role" tester
expect_rejected "unsupported provider" implementer copilot model-x
expect_rejected "unsafe model syntax" implementer codex "bad model"
expect_rejected "option-like model" implementer codex --fallback
expect_rejected "known incompatible combination" implementer codex fable

# A provider whose CLI is not installed fails.
rm "$tmp/bin/claude"
if (PATH="$tmp/bin:/usr/bin:/bin" agent_resolve "$tmp" reviewer) 2>"$tmp/err.log"; then
  fail "missing agent CLI was accepted"
fi
grep -Fq "claude" "$tmp/err.log" || fail "missing agent CLI was not named"
cp "$tmp/bin/codex" "$tmp/bin/claude"

# Invalid configuration fails, also for roles other than the requested one.
write_config "implementer: codex model-a" "reviewer claude model-b"
expect_rejected "malformed configuration line" implementer
write_config "implementer: codex model-a" "tester: claude model-b"
expect_rejected "unknown configured role" implementer
write_config "implementer: codex model-a" "implementer: claude model-b"
expect_rejected "duplicate configured role" implementer

# Without a configuration file, explicit command-line values are sufficient.
rm "$tmp/agents.conf"
expect_resolved "codex model-f" implementer codex model-f
expect_rejected "no configuration and no override" implementer

# Workflow arguments are separated from the agent options.
agent_parse_args 12 --agent claude slug --model model-g main
[[ "$AGENT_CLI_PROVIDER" == "claude" && "$AGENT_CLI_MODEL" == "model-g" ]] ||
  fail "agent options were not parsed"
[[ "${AGENT_POSITIONAL[*]}" == "12 slug main" ]] || fail "positional arguments were not preserved"
if (agent_parse_args 12 --model) 2>/dev/null; then
  fail "option without a value was accepted"
fi

# Both providers receive the model and run in the requested directory.
workdir="$(cd "$tmp/work" && pwd -P)"
for provider in codex claude; do
  : >"$MOCK_AGENT_LOG"
  agent_run_interactive "$provider" "model-$provider" "$workdir" "the prompt" >/dev/null
  grep -Fq -- "--model model-$provider" "$MOCK_AGENT_LOG" ||
    fail "$provider did not receive the model in an interactive run"
  grep -Fqx "PWD=$workdir" "$MOCK_AGENT_LOG" || fail "$provider did not run in the work directory"

  : >"$MOCK_AGENT_LOG"
  agent_run_report "$provider" "model-$provider" "$workdir" "the prompt" "$tmp/report.txt"
  grep -Fq -- "--model model-$provider" "$MOCK_AGENT_LOG" ||
    fail "$provider did not receive the model in a report run"
  grep -Fqx "$provider report" "$tmp/report.txt" || fail "$provider report was not stored"
done

# The agent's exit status reaches the caller.
status=0
MOCK_AGENT_EXIT=7 agent_run_interactive claude model-b "$workdir" "the prompt" >/dev/null || status=$?
[[ "$status" -eq 7 ]] || fail "agent exit status was not propagated"

echo "agent tests passed"
