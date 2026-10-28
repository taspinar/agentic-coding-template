#!/usr/bin/env bash

set -euo pipefail

# Runs the real Codex CLI the way scripts/lib/agent.sh starts an unattended
# session, in a scratch repository laid out like a feature worktree, and
# checks what the session can write. Codex 0.164 mounts .agents/, .git/, and
# .codex/ read-only in its workspace-write sandbox; agent.sh grants exactly
# the runtime directories that the implementer and the triage-implementer
# write (completion record, handoff note, summary, manual steps, experience
# notes) and nothing else. The write profile cannot run without a terminal:
# its command line is checked with a fake codex and must grant the same roots.
#
# Skipped, with a message, when codex is not installed, not logged in, or no
# role with write access uses it (AGENT_SANDBOX_TEST_MODEL names a model
# then). The session is a real one: it takes a minute and uses tokens.

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$source_root/tests/lib-fakes.sh"

skip() {
  echo "agent sandbox test skipped: $*"
  exit 0
}

fail() {
  echo "agent sandbox test failed: $*" >&2
  exit 1
}

command -v codex >/dev/null 2>&1 || skip "the codex CLI is not installed; the test needs the real binary"
# A Codex session cannot start another one: inside its sandbox, codex cannot
# write its own home ("failed to initialize in-process app-server client:
# Read-only file system"). The implementer's own run of verify.sh gets here.
[[ -z "${CODEX_SESSION_ID:-}${CODEX_THREAD_ID:-}" ]] || skip "running inside a Codex session, which cannot start another one; run the test from a terminal"
codex login status </dev/null >/dev/null 2>&1 || skip "codex is not logged in (see 'codex login status'); the test needs a real session"

source "$source_root/scripts/lib/agent.sh"

# The model of a Codex role that writes the runtime files, from the
# repository's configuration, a level line included.
model="${AGENT_SANDBOX_TEST_MODEL:-}"
if [[ -z "$model" ]]; then
  for role in implementer triage-implementer; do
    agent_lookup "$source_root" "$role"
    if [[ "$AGENT_CONFIG_PROVIDER" == "codex" ]]; then
      model="$AGENT_CONFIG_MODEL"
      break
    fi
    for level in $AGENT_CONFIG_LEVELS; do
      agent_lookup "$source_root" "$role" "$level"
      if [[ "$AGENT_LEVEL_PROVIDER" == "codex" ]]; then
        model="$AGENT_LEVEL_MODEL"
        break 2
      fi
    done
  done
fi
[[ -n "$model" ]] || skip "neither the implementer nor the triage-implementer uses codex in .agents/agents.conf; set AGENT_SANDBOX_TEST_MODEL to run the test"

# The sandbox lets a session write /tmp and $TMPDIR, so a scratch repository
# there could not show that a write outside the worktree fails. The layout
# goes next to the repository, where a feature worktree is, or under $HOME.
base="$(mktemp -d "$(dirname "$source_root")/agent-sandbox-test.XXXXXX" 2>/dev/null)" ||
  base="$(mktemp -d "$HOME/agent-sandbox-test.XXXXXX")"
base="$(cd "$base" && pwd -P)"

cleanup() {
  rm -rf "$base"
}
trap cleanup EXIT

# A feature worktree: the workflow files (scripts, prompts, and schemas, from
# copy_workflow), the ignore rules, the policies, a handoffs directory with
# its .gitkeep, and a .codex directory; the other runtime directories do not
# exist until agent.sh creates them. A sibling directory stands for the rest
# of the machine.
repo="$base/repo"
mkdir -p "$repo" "$base/sibling"
copy_workflow "$repo"
cp "$source_root/.gitignore" "$repo/.gitignore"
mkdir -p "$repo/.agents/policies" "$repo/.agents/prompts" "$repo/.agents/handoffs" "$repo/.codex"
cp "$source_root"/.agents/policies/* "$repo/.agents/policies/"
cp "$source_root"/.agents/prompts/*.md "$repo/.agents/prompts/"
: >"$repo/.agents/handoffs/.gitkeep"
printf 'implementer: codex %s\n' "$model" >"$repo/.agents/agents.conf"
git -C "$repo" init -q
git -C "$repo" symbolic-ref HEAD refs/heads/feature/177-sandbox
git -C "$repo" add -A
git -C "$repo" -c user.name=test -c user.email=test@example.com commit -qm "scratch feature worktree"

allowed=(.agents/completion .agents/handoffs .agents/summaries .agents/manual-steps .agents/experience)
protected=(.agents/policies .agents/prompts .git .codex)

# A protected directory exists before the session starts, so that a denied
# write there is the sandbox's doing and not a missing parent directory.
for path in "${protected[@]}"; do
  [[ -d "$repo/$path" ]] || fail "the scratch worktree lacks $path, so a write there would fail for the wrong reason"
done

# The probe tries a write in every directory, as the implementer does, and
# records the result in the repository root, which is always writable. A
# denied write must not end it: bash, not sh, whose ':' exits on a failed
# redirect.
probe="$repo/sandbox-probe.sh"
results="$repo/sandbox-probe-results"
{
  echo '#!/usr/bin/env bash'
  printf 'results=%q\n' "$results"
  echo ': >"$results"'
  echo 'try() {'
  echo '  if echo probe >"$1/sandbox-probe" 2>/dev/null; then'
  echo '    rm -f "$1/sandbox-probe"; echo "writable $1" | tee -a "$results"'
  echo '  else'
  echo '    echo "denied $1" | tee -a "$results"'
  echo '  fi'
  echo '}'
  for path in "${allowed[@]}" "${protected[@]}"; do
    printf 'try %q\n' "$repo/$path"
  done
  printf 'try %q\n' "$base/sibling"
  # The prompts tell the implementer to 'mkdir -p' the runtime directories.
  printf 'mkdir -p %q && echo "mkdir -p ok" | tee -a "$results"\n' "$repo/.agents/completion"
} >"$probe"

# The real codex, behind a wrapper that keeps the command line agent.sh built.
real_codex="$(command -v codex)"
mkdir -p "$base/bin" "$base/fake"
cat >"$base/bin/codex" <<WRAP
#!/usr/bin/env bash
for argument in "\$@"; do printf 'ARG=%s\n' "\$argument"; done >>"\$MOCK_AGENT_LOG"
exec "$real_codex" "\$@"
WRAP
# A fake for the write profile, which needs a terminal: it keeps the command
# line only.
cat >"$base/fake/codex" <<'FAKE'
#!/usr/bin/env bash
for argument in "$@"; do printf 'ARG=%s\n' "$argument"; done >>"$MOCK_AGENT_LOG"
FAKE
chmod +x "$base/bin/codex" "$base/fake/codex"

prompt="Use your shell tool to run the command: bash $probe
Then reply with the exact output of that command, nothing else. Do not reply before the command has run."

# A model that answers without running the command proves nothing: one more
# attempt, then the test fails.
export MOCK_AGENT_LOG="$base/unattended.log"
for attempt in 1 2; do
  rm -f "$results" "$base/final.md"
  : >"$MOCK_AGENT_LOG"
  status=0
  PATH="$base/bin:$PATH" agent_run unattended codex "$model" "$repo" "$prompt" "$base/final.md" >"$base/session.out" 2>&1 || status=$?
  if [[ "$status" -ne 0 ]]; then
    cat "$base/session.out" >&2
    fail "the unattended codex session ended with status $status"
  fi
  [[ ! -s "$results" ]] || break
  if [[ "$attempt" -eq 2 ]]; then
    echo "Final message of the session:" >&2
    cat "$base/final.md" >&2
    fail "the session left no probe results in two attempts: it did not run the command"
  fi
done

echo "The session reported:"
sed 's/^/  /' "$results"

for path in "${allowed[@]}"; do
  grep -Fxq "writable $repo/$path" "$results" || fail "the unattended session cannot write $path"
done
grep -Fxq "mkdir -p ok" "$results" || fail "'mkdir -p' of an existing runtime directory fails in the sandbox"
for path in "${protected[@]}"; do
  grep -Fxq "denied $repo/$path" "$results" || fail "the unattended session can write $path, which must stay protected"
done
grep -Fxq "denied $base/sibling" "$results" || fail "the unattended session can write outside the worktree: $base/sibling"

# The command line grants the five directories and no other path.
roots_unattended="$(grep '^ARG=sandbox_workspace_write.writable_roots=' "$MOCK_AGENT_LOG" | head -n 1)"
[[ -n "$roots_unattended" ]] || fail "the unattended invocation passes no writable roots"
for path in "${allowed[@]}"; do
  [[ "$roots_unattended" == *"\"$repo/$path\""* ]] || fail "the writable roots leave out $path: $roots_unattended"
done
[[ "$(grep -o '"' <<<"$roots_unattended" | wc -l)" -eq 10 ]] || fail "the writable roots name more than the five directories: $roots_unattended"
grep -Fxq "ARG=workspace-write" "$MOCK_AGENT_LOG" || fail "the unattended session does not run in the workspace-write sandbox"

# The write profile grants the same roots in the same sandbox.
export MOCK_AGENT_LOG="$base/write.log"
: >"$MOCK_AGENT_LOG"
PATH="$base/fake:$PATH" agent_run write codex "$model" "$repo" "the prompt" >/dev/null
roots_write="$(grep '^ARG=sandbox_workspace_write.writable_roots=' "$MOCK_AGENT_LOG" | head -n 1)"
[[ -n "$roots_write" ]] || fail "the write invocation passes no writable roots"
[[ "$roots_write" == "$roots_unattended" ]] || fail "the write profile grants other roots than the unattended one: $roots_write"
grep -Fxq "ARG=workspace-write" "$MOCK_AGENT_LOG" || fail "the write session does not run in the workspace-write sandbox"

echo "agent sandbox tests passed"
