#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

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
  # With --output-format json the real CLI answers in a result envelope.
  if [[ "$*" == *"--output-format json"* ]]; then
    echo '{"is_error": false, "result": "claude report"}'
  else
    echo "claude report"
  fi
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
  agent_run write "$provider" "model-$provider" "$workdir" "the prompt" >/dev/null
  grep -Fq -- "--model model-$provider" "$MOCK_AGENT_LOG" ||
    fail "$provider did not receive the model in an interactive run"
  grep -Fqx "PWD=$workdir" "$MOCK_AGENT_LOG" || fail "$provider did not run in the work directory"

  : >"$MOCK_AGENT_LOG"
  agent_run read-only "$provider" "model-$provider" "$workdir" "the prompt" "$tmp/report.txt"
  grep -Fq -- "--model model-$provider" "$MOCK_AGENT_LOG" ||
    fail "$provider did not receive the model in a report run"
  grep -Fqx "$provider report" "$tmp/report.txt" || fail "$provider report was not stored"
done

# A Codex write session has network access, like a Claude write session, and
# asks the user for what its sandbox blocks instead of failing or running
# unsandboxed. A read-only session gets neither.
: >"$MOCK_AGENT_LOG"
agent_run write codex model-a "$workdir" "the prompt" >/dev/null
grep -Fq -- "sandbox_workspace_write.network_access=true" "$MOCK_AGENT_LOG" ||
  fail "codex write session has no network access"
grep -Fq -- "--sandbox workspace-write --ask-for-approval on-request" "$MOCK_AGENT_LOG" ||
  fail "codex write session does not ask the user for what its sandbox blocks"
if grep -Eq -- "danger-full-access|bypass-approvals" "$MOCK_AGENT_LOG"; then
  fail "codex write session runs without a sandbox"
fi
: >"$MOCK_AGENT_LOG"
agent_run read-only codex model-a "$workdir" "the prompt" "$tmp/report.txt"
if grep -Eq -- "network_access|--ask-for-approval" "$MOCK_AGENT_LOG"; then
  fail "codex read-only session was given network access or approval prompts"
fi

# A read-only run uses the read-only flags of each provider.
: >"$MOCK_AGENT_LOG"
agent_run read-only codex model-a "$workdir" "the prompt" "$tmp/report.txt"
for flag in "--ignore-user-config" "--sandbox read-only" "--disable apps" "--disable computer_use" 'web_search="disabled"'; do
  grep -Fq -- "$flag" "$MOCK_AGENT_LOG" || fail "isolated Codex read-only session lacks: $flag"
done
: >"$MOCK_AGENT_LOG"
agent_run read-only claude model-b "$workdir" "the prompt" "$tmp/report.txt"
grep -Fq -- "--strict-mcp-config --permission-mode dontAsk --tools Read,Glob,Grep" "$MOCK_AGENT_LOG" ||
  fail "claude read-only run was not restricted to read tools"

# An unattended run has the reach of a write session without a terminal: it
# gets the model, runs in the work directory, stores the final message, and
# is never started without a sandbox or with every permission check bypassed.
for provider in codex claude; do
  : >"$MOCK_AGENT_LOG"
  rm -f "$tmp/final.txt"
  agent_run unattended "$provider" "model-$provider" "$workdir" "the prompt" "$tmp/final.txt" >/dev/null ||
    fail "$provider unattended run failed"
  grep -Fq -- "--model model-$provider" "$MOCK_AGENT_LOG" || fail "$provider did not receive the model in an unattended run"
  grep -Fqx "PWD=$workdir" "$MOCK_AGENT_LOG" || fail "$provider did not run unattended in the work directory"
  grep -Fqx "$provider report" "$tmp/final.txt" || fail "the final message of the unattended $provider run was not stored"
  if grep -Eq -- "danger-full-access|bypass|dangerously" "$MOCK_AGENT_LOG"; then
    fail "the unattended $provider run bypasses its sandbox or permission checks"
  fi
done
: >"$MOCK_AGENT_LOG"
agent_run unattended codex model-a "$workdir" "the prompt" "$tmp/final.txt" >/dev/null
grep -Fq -- "exec --ignore-user-config -c sandbox_workspace_write.network_access=true --sandbox workspace-write" "$MOCK_AGENT_LOG" ||
  fail "the unattended codex run is not a non-interactive run in the workspace sandbox"
if grep -Fq -- "--ask-for-approval" "$MOCK_AGENT_LOG"; then fail "the unattended codex run can ask for approval"; fi
# No tools from the user's configuration reach an unattended session.
for flag in "--ignore-user-config" "--disable apps" "--disable browser_use" "--disable computer_use"; do
  grep -Fq -- "$flag" "$MOCK_AGENT_LOG" || fail "the unattended codex run lacks: $flag"
done
: >"$MOCK_AGENT_LOG"
agent_run unattended claude model-b "$workdir" "the prompt" "$tmp/final.txt" >/dev/null
grep -Fq -- "--print --permission-mode auto --permission-prompts none --strict-mcp-config" "$MOCK_AGENT_LOG" ||
  fail "the unattended claude run does not decide permissions without the user"
status=0
MOCK_AGENT_EXIT=9 agent_run unattended claude model-b "$workdir" "the prompt" "$tmp/final.txt" >/dev/null 2>&1 || status=$?
[[ "$status" -eq 9 ]] || fail "the exit status of an unattended run was not propagated"
# A failed unattended codex run says where its reason is, and shows it.
status=0
MOCK_AGENT_EXIT=4 agent_run unattended codex model-a "$workdir" "the prompt" "$tmp/final.txt" >/dev/null 2>"$tmp/codex.err" || status=$?
[[ "$status" -eq 4 ]] || fail "the exit status of an unattended codex run was not propagated"
grep -Fq "$tmp/final.txt.log" "$tmp/codex.err" || fail "a failed unattended codex run did not name its log"
# Codex writes its errors as JSON events: a failed session says them, and a
# usage limit is named as one, for a read-only and an unattended session.
mkdir -p "$tmp/failing-bin"
cat >"$tmp/failing-bin/codex" <<'FAKE'
#!/usr/bin/env bash
echo '{"type":"thread.started","thread_id":"t"}'
jq -cn --arg m "${MOCK_CODEX_ERROR:-You have hit your usage limit. Try again at 1:56 PM.}" '{type: "error", message: $m}'
echo '{"type":"turn.failed","error":{"message":"{\"type\":\"error\",\"status\":400,\"error\":{\"message\":\"The model is not supported.\"}}"}}'
echo "Reading additional input from stdin..." >&2
exit 1
FAKE
chmod +x "$tmp/failing-bin/codex"
for profile in read-only unattended; do
  status=0
  (PATH="$tmp/failing-bin:$PATH" agent_run "$profile" codex model-a "$workdir" "the prompt" "$tmp/failed.txt") \
    >/dev/null 2>"$tmp/failed.err" || status=$?
  [[ "$status" -ne 0 ]] || fail "a failed $profile codex session returned success"
  grep -Fq "You have hit your usage limit. Try again at 1:56 PM." "$tmp/failed.err" ||
    fail "a failed $profile codex session did not say its error: $(cat "$tmp/failed.err")"
  grep -Fq "The model is not supported." "$tmp/failed.err" || fail "the inner message of an API error was not shown ($profile)"
  grep -Fq "This is a usage limit of codex, not a defect" "$tmp/failed.err" || fail "a usage limit was not named as one ($profile)"
  if grep -Fq "the prompt" "$tmp/failed.err"; then fail "the prompt reached the error output ($profile)"; fi
done
# Another error is said without calling it a usage limit.
(MOCK_CODEX_ERROR="The sandbox could not start." PATH="$tmp/failing-bin:$PATH" agent_run read-only codex model-a "$workdir" "the prompt" "$tmp/failed.txt") >/dev/null 2>"$tmp/failed.err" || true
grep -Fq "The sandbox could not start." "$tmp/failed.err" || fail "another error of a codex session was not shown"
if grep -Fq "usage limit" "$tmp/failed.err"; then fail "another error was called a usage limit"; fi

# A plain message stays as it is, without a parser error.
(PATH="$tmp/failing-bin:$PATH" agent_run read-only codex model-a "$workdir" "the prompt" "$tmp/failed.txt") >/dev/null 2>"$tmp/failed.err" || true
if grep -Eq "Invalid numeric literal|while parsing" "$tmp/failed.err"; then fail "a plain message became a parser error: $(cat "$tmp/failed.err")"; fi
# A limit that only the error output names is a usage limit too, for both
# providers.
mkdir -p "$tmp/stderr-bin"
printf '#!/usr/bin/env bash\necho "Error: 429 Too Many Requests: rate limit exceeded" >&2\nexit 1\n' >"$tmp/stderr-bin/codex"
cp "$tmp/stderr-bin/codex" "$tmp/stderr-bin/claude"
chmod +x "$tmp/stderr-bin/codex" "$tmp/stderr-bin/claude"
for provider in codex claude; do
  for profile in read-only unattended; do
    (PATH="$tmp/stderr-bin:$PATH" agent_run "$profile" "$provider" model-a "$workdir" "the prompt" "$tmp/failed.txt") >/dev/null 2>"$tmp/failed.err" || true
    grep -Fq "This is a usage limit of $provider, not a defect" "$tmp/failed.err" ||
      fail "a limit on the error output of $provider ($profile) was not named: $(cat "$tmp/failed.err")"
  done
done
# Neither the prompt nor a secret is shown, also when the provider repeats
# them in its error output.
printf '#!/usr/bin/env bash\necho "Implement the secret feature described in docs/plan.md" >&2\necho "auth failed for token sk-abcdefghijklmnopqrstuv" >&2\nexit 1\n' >"$tmp/stderr-bin/codex"
(PATH="$tmp/stderr-bin:$PATH" agent_run read-only codex model-a "$workdir" "Implement the secret feature described in docs/plan.md" "$tmp/failed.txt") >/dev/null 2>"$tmp/failed.err" || true
if grep -Fq "Implement the secret feature" "$tmp/failed.err"; then fail "the prompt reached the error output"; fi
if grep -Fq "sk-abcdefghijklmnopqrstuv" "$tmp/failed.err"; then fail "a secret reached the error output"; fi
grep -Fq "auth failed for token [redacted]" "$tmp/failed.err" || fail "the error without its secret was not shown: $(cat "$tmp/failed.err")"
# Also a prompt that the provider repeats behind a prefix, over several
# lines, and a private key with its whole body.
cat >"$tmp/stderr-bin/codex" <<'FAKE'
#!/usr/bin/env bash
printf 'Error processing prompt: Build the payment page for the shop\nUse the card numbers in fixtures/cards.json\n' >&2
printf -- '-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAsecretbody\nmoresecretbody\n-----END RSA PRIVATE KEY-----\n' >&2
echo "rate limit exceeded" >&2
exit 1
FAKE
chmod +x "$tmp/stderr-bin/codex"
(PATH="$tmp/stderr-bin:$PATH" agent_run read-only codex model-a "$workdir" "$(printf 'Build the payment page for the shop\nUse the card numbers in fixtures/cards.json')" "$tmp/failed.txt") \
  >/dev/null 2>"$tmp/failed.err" || true
for leak in "payment page" "fixtures/cards.json" "secretbody" "PRIVATE KEY"; do
  if grep -Fq "$leak" "$tmp/failed.err"; then fail "the error output shows '$leak': $(cat "$tmp/failed.err")"; fi
done
grep -Fq "Error processing prompt: [prompt]" "$tmp/failed.err" || fail "the prefix of a repeated prompt was not kept: $(cat "$tmp/failed.err")"
grep -Fq "This is a usage limit of codex" "$tmp/failed.err" || fail "the limit beside the removed lines was not named"
# A private key longer than any window, and a short prompt, are not shown.
cat >"$tmp/stderr-bin/codex" <<'FAKE'
#!/usr/bin/env bash
echo "-----BEGIN OPENSSH PRIVATE KEY-----" >&2
for i in $(seq 1 30); do echo "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAA$i" >&2; done
echo "-----END OPENSSH PRIVATE KEY-----" >&2
echo "Error processing prompt: secret task" >&2
exit 1
FAKE
(PATH="$tmp/stderr-bin:$PATH" agent_run read-only codex model-a "$workdir" "secret task" "$tmp/failed.txt") >/dev/null 2>"$tmp/failed.err" || true
for leak in "b3BlbnNzaC1rZXktdjEAAAAA" "secret task" "PRIVATE KEY"; do
  if grep -Fq "$leak" "$tmp/failed.err"; then fail "the error output shows '$leak': $(cat "$tmp/failed.err")"; fi
done
grep -Fq "Error processing prompt: [prompt]" "$tmp/failed.err" || fail "a short repeated prompt was not replaced: $(cat "$tmp/failed.err")"
# A prompt line that is part of the marker does not make the report hang, and
# a short prompt line is replaced as a word of its own, not inside others.
for prompt in prompt romp PIN; do
  printf '#!/usr/bin/env bash\necho "Error processing prompt: %s (PINNED)" >&2\nexit 1\n' "$prompt" >"$tmp/stderr-bin/codex"
  (PATH="$tmp/stderr-bin:$PATH" agent_run read-only codex model-a "$workdir" "$prompt" "$tmp/failed.txt") >/dev/null 2>"$tmp/failed.err" &
  pid=$!
  for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid"; fail "the report of a failure hung for the prompt '$prompt'"; fi
  wait "$pid" || true
done
grep -Fq "Error processing prompt: [prompt] (PINNED)" "$tmp/failed.err" || fail "a short prompt line was not replaced as a word: $(cat "$tmp/failed.err")"
# A write session shows the agent in the terminal; the script repeats nothing
# of it and says only that it failed, with its status.
printf '#!/usr/bin/env bash\necho "auth failed for token sk-abcdefghijklmnopqrstuv" >&2\nexit 6\n' >"$tmp/stderr-bin/codex"
status=0
(PATH="$tmp/stderr-bin:$PATH" agent_run write codex model-a "$workdir" "the prompt") >/dev/null 2>"$tmp/write.err" || status=$?
[[ "$status" -eq 6 ]] || fail "a failed write session did not return its status"
# The token is in the output once, written by the agent itself; the line of
# the script holds neither the prompt nor the token.
[[ "$(grep -c "sk-abcdefghijklmnopqrstuv" "$tmp/write.err")" -eq 1 ]] || fail "the script repeated the output of a write session"
status_line="$(grep -F "The codex session ended with status 6" "$tmp/write.err")" || fail "a failed write session was not reported"
if grep -Eq "sk-abcdefghijklmnopqrstuv|the prompt" <<<"$status_line"; then fail "the report of a write session holds the prompt or the token"; fi
# A repeated prompt that holds a secret is replaced whole, and a limit that
# later lines push out of the lines shown is still named.
cat >"$tmp/stderr-bin/codex" <<'FAKE'
#!/usr/bin/env bash
echo "Error processing prompt: Deploy confidential customer project with sk-abcdefghijklmnopqrstuv" >&2
echo "rate limit exceeded" >&2
for i in $(seq 1 12); do echo "cleanup step $i" >&2; done
exit 1
FAKE
(PATH="$tmp/stderr-bin:$PATH" agent_run read-only codex model-a "$workdir" "Deploy confidential customer project with sk-abcdefghijklmnopqrstuv" "$tmp/failed.txt") \
  >/dev/null 2>"$tmp/failed.err" || true
if grep -Fq "confidential customer" "$tmp/failed.err"; then fail "a repeated prompt with a secret was shown: $(cat "$tmp/failed.err")"; fi
grep -Fq "This is a usage limit of codex" "$tmp/failed.err" || fail "a limit before more than ten lines was not named"
# The ordinary answer of a failed read-only session is not shown.
printf '#!/usr/bin/env bash\necho "Here is my review of the confidential code"\nexit 1\n' >"$tmp/stderr-bin/claude"
(PATH="$tmp/stderr-bin:$PATH" agent_run read-only claude model-b "$workdir" "the prompt" "$tmp/failed.txt") >/dev/null 2>"$tmp/failed.err" || true
if grep -Fq "confidential code" "$tmp/failed.err"; then fail "the answer of a failed session was shown as its error"; fi

# A codex session that ends without a final message is a failure too.
mkdir -p "$tmp/silent-bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/silent-bin/codex"
chmod +x "$tmp/silent-bin/codex"
rm -f "$tmp/final.txt"
if (PATH="$tmp/silent-bin:$PATH" agent_run unattended codex model-a "$workdir" "the prompt" "$tmp/final.txt") >/dev/null 2>&1; then
  fail "an unattended codex run without a final message returned success"
fi
# The whole task is in the prompt: a context or schema file is refused.
: >"$MOCK_AGENT_LOG"
if (agent_run unattended claude model-b "$workdir" "the prompt" "$tmp/final.txt" "$tmp/agents.conf") 2>/dev/null; then
  fail "an unattended run with a context file was accepted"
fi
if (agent_run unattended codex model-a "$workdir" "the prompt" "$tmp/final.txt" /dev/null "$tmp/agents.conf") 2>/dev/null; then
  fail "an unattended run with a schema file was accepted"
fi
[[ ! -s "$MOCK_AGENT_LOG" ]] || fail "an agent was started for an unattended run with a context or schema file"
if (agent_run unattended claude model-b "$workdir" "the prompt") 2>/dev/null; then
  fail "an unattended run without an output file was accepted"
fi

# An unknown profile, or a read-only run without an output file, starts no agent.
: >"$MOCK_AGENT_LOG"
if (agent_run admin claude model-b "$workdir" "the prompt") 2>/dev/null; then
  fail "unknown permission profile was accepted"
fi
if (agent_run read-only claude model-b "$workdir" "the prompt") 2>/dev/null; then
  fail "read-only run without an output file was accepted"
fi
[[ ! -s "$MOCK_AGENT_LOG" ]] || fail "an agent was started with an unsupported profile"

# The agent's exit status reaches the caller.
status=0
MOCK_AGENT_EXIT=7 agent_run write claude model-b "$workdir" "the prompt" >/dev/null || status=$?
[[ "$status" -eq 7 ]] || fail "agent exit status was not propagated"

# Structured output from Claude arrives in a result envelope. The launcher
# extracts it, reports errors with a non-zero status, and keeps the session
# isolated from the user's configuration.
mkdir -p "$tmp/envelope-bin"
cat >"$tmp/envelope-bin/claude" <<'FAKE'
#!/usr/bin/env bash
echo "ARGS=$*" >>"$MOCK_AGENT_LOG"
printf '%s\n' "$MOCK_ENVELOPE"
exit "${MOCK_AGENT_EXIT:-0}"
FAKE
chmod +x "$tmp/envelope-bin/claude"
printf '{"type": "object"}\n' >"$tmp/schema.json"

# An unattended Claude session reports through the same envelope: an error
# fails the run, and the final message is taken from the result.
run_unattended_envelope() {
  PATH="$tmp/envelope-bin:$PATH" agent_run unattended claude model-b "$workdir" "the prompt" "$tmp/unattended.txt" \
    >/dev/null 2>"$tmp/unattended.err"
}
MOCK_ENVELOPE='{"is_error": false, "result": "All done."}' run_unattended_envelope ||
  fail "a successful unattended envelope was reported as a failure"
grep -Fqx "All done." "$tmp/unattended.txt" || fail "the final message was not taken from the envelope"
if MOCK_ENVELOPE='{"is_error": true, "result": "Usage limit reached."}' run_unattended_envelope; then
  fail "an unattended session that reported an error returned success"
fi
grep -Fq "Usage limit reached." "$tmp/unattended.err" || fail "the error of an unattended session was not shown"
grep -Fq "This is a usage limit of claude, not a defect" "$tmp/unattended.err" || fail "a usage limit of claude was not named as one"
# Output that is not a result envelope with a final message is a failure, not
# a final message.
for envelope in 'not json at all' '{"is_error": false}' '{"is_error": false, "result": null}'; do
  if MOCK_ENVELOPE="$envelope" run_unattended_envelope; then
    fail "an unattended session without a final message returned success: $envelope"
  fi
done

# A session that exits 0 without a final message says why from its error
# output, not by printing its raw output.
cat >"$tmp/envelope-bin/claude-quiet" <<'FAKE'
#!/usr/bin/env bash
echo '{"is_error": false, "result": null, "note": "sk-abcdefghijklmnopqrstuv"}'
echo "rate limit exceeded" >&2
exit 0
FAKE
chmod +x "$tmp/envelope-bin/claude-quiet"
mkdir -p "$tmp/quiet-bin" && cp "$tmp/envelope-bin/claude-quiet" "$tmp/quiet-bin/claude"
(PATH="$tmp/quiet-bin:$PATH" agent_run unattended claude model-b "$workdir" "the prompt" "$tmp/unattended.txt") >/dev/null 2>"$tmp/quiet.err" &&
  fail "a session without a final message returned success"
grep -Fq "This is a usage limit of claude" "$tmp/quiet.err" || fail "the error output of a session without a final message was not shown: $(cat "$tmp/quiet.err")"
if grep -Fq "sk-abcdefghijklmnopqrstuv" "$tmp/quiet.err"; then fail "the raw output of a session without a final message was printed"; fi

run_structured() {
  PATH="$tmp/envelope-bin:$PATH" agent_run read-only claude model-b "$workdir" "the prompt" \
    "$tmp/structured.json" /dev/null "$tmp/schema.json" 2>/dev/null
}

: >"$MOCK_AGENT_LOG"
MOCK_ENVELOPE='{"is_error": false, "structured_output": {"verdict": "PASS"}, "result": "ignored"}' run_structured ||
  fail "structured output was not accepted"
[[ "$(jq -c . "$tmp/structured.json")" == '{"verdict":"PASS"}' ]] || fail "structured output was not extracted"
for flag in "--restricted" "--strict-mcp-config" "--permission-mode dontAsk" "--tools Read,Glob,Grep" "--json-schema"; do
  grep -Fq -- "$flag" "$MOCK_AGENT_LOG" || fail "isolated Claude read-only session lacks: $flag"
done
if grep -Fq -- "--permission-mode plan" "$MOCK_AGENT_LOG"; then
  fail "Claude read-only session still uses plan mode"
fi

MOCK_ENVELOPE='{"is_error": false, "result": "{\"verdict\": \"PASS\"}"}' run_structured ||
  fail "a JSON result without structured_output was not accepted"
[[ "$(jq -c . "$tmp/structured.json")" == '{"verdict":"PASS"}' ]] || fail "JSON in the result field was not extracted"

status=0
MOCK_ENVELOPE='{"is_error": true, "result": "API error"}' run_structured || status=$?
[[ "$status" -ne 0 ]] || fail "an error reported in the envelope returned success"

status=0
MOCK_AGENT_EXIT=5 MOCK_ENVELOPE='{"is_error": true, "result": "failed"}' run_structured || status=$?
[[ "$status" -eq 5 ]] || fail "Claude's exit status was not returned (got $status)"


# Agent attribution. When the project disables it, a Claude session that may
# commit is started with the setting that turns off its commit trailer and
# its pull request line; a read-only session, Codex, and a project that allows
# attribution get nothing. A preference that cannot be read starts no session.
mkdir -p "$workdir/.agents"
printf 'agent-attribution: disabled\n' >"$workdir/.agents/attribution.conf"
for profile in write unattended; do
  : >"$MOCK_AGENT_LOG"
  agent_run "$profile" claude model-b "$workdir" "the prompt" "$tmp/final.txt" >/dev/null ||
    fail "the claude $profile session failed with attribution disabled"
  grep -Fq -- '--settings {"attribution": {"commit": "", "pr": "", "sessionUrl": false}}' "$MOCK_AGENT_LOG" ||
    fail "the claude $profile session was not told to leave out its attribution"
  : >"$MOCK_AGENT_LOG"
  agent_run "$profile" codex model-a "$workdir" "the prompt" "$tmp/final.txt" >/dev/null ||
    fail "the codex $profile session failed with attribution disabled"
  if grep -Fq -- "attribution" "$MOCK_AGENT_LOG"; then fail "codex, which has no attribution setting, was given one"; fi
done
: >"$MOCK_AGENT_LOG"
agent_run read-only claude model-b "$workdir" "the prompt" "$tmp/report.txt"
if grep -Fq -- "--settings" "$MOCK_AGENT_LOG"; then fail "a read-only claude session, which commits nothing, was given the attribution setting"; fi

printf 'agent-attribution: allowed\n' >"$workdir/.agents/attribution.conf"
: >"$MOCK_AGENT_LOG"
agent_run write claude model-b "$workdir" "the prompt" >/dev/null
if grep -Fq -- "--settings" "$MOCK_AGENT_LOG"; then fail "a project that allows attribution changed Claude's settings"; fi
rm "$workdir/.agents/attribution.conf"
: >"$MOCK_AGENT_LOG"
agent_run write claude model-b "$workdir" "the prompt" >/dev/null
if grep -Fq -- "--settings" "$MOCK_AGENT_LOG"; then fail "an unconfigured project changed Claude's settings"; fi

printf 'agent-attribution: maybe\n' >"$workdir/.agents/attribution.conf"
: >"$MOCK_AGENT_LOG"
if agent_run write claude model-b "$workdir" "the prompt" >/dev/null 2>"$tmp/err.log"; then
  fail "a claude session started with an unreadable attribution preference"
fi
[[ ! -s "$MOCK_AGENT_LOG" ]] || fail "claude was started although the attribution preference cannot be read"
grep -Fq "unknown value 'maybe'" "$tmp/err.log" || fail "the unreadable preference was not explained"
rm "$workdir/.agents/attribution.conf"

echo "agent tests passed"
