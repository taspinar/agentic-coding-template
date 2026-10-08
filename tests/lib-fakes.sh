#!/usr/bin/env bash

# Shared fakes for the workflow tests. Source this file.
#
# make_fake_agents <bin-dir>
# Creates fake 'codex' and 'claude' executables that log their arguments and
# standard input and return MOCK_OUTPUT. With MOCK_OUTPUT_FIRST set, the first
# call of a test returns that value instead. MOCK_AGENT_ACTION is evaluated in
# the agent's working directory; MOCK_AGENT_EXIT sets the exit status.
make_fake_agents() {
  local bin="$1"
  local jq_path

  mkdir -p "$bin"

  # Tests restrict PATH to this directory and the system directories, so make
  # jq available wherever it is installed.
  jq_path="$(command -v jq)" || {
    echo "jq is required to run the workflow tests." >&2
    exit 1
  }
  ln -sf "$jq_path" "$bin/jq"
  cat >"$bin/claude" <<'AGENT'
#!/usr/bin/env bash
set -euo pipefail

agent="$(basename "$0")"
{
  echo "AGENT=$agent"
  echo "ARGS=$*"
} >>"$MOCK_AGENT_LOG"
if [[ ! -t 0 ]]; then
  cat >"$MOCK_AGENT_LOG.stdin"
fi

output="${MOCK_OUTPUT:-}"
if [[ -n "${MOCK_OUTPUT_FIRST:-}" && ! -e "$MOCK_AGENT_LOG.called" ]]; then
  output="$MOCK_OUTPUT_FIRST"
fi
: >"$MOCK_AGENT_LOG.called"

output_file=""
structured=0
[[ "$*" != *"--output-format json"* ]] || structured=1
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --output-last-message) output_file="${args[$((i + 1))]}" ;;
    --json-schema | --output-schema) structured=1 ;;
  esac
done

if [[ -n "${MOCK_AGENT_ACTION:-}" ]]; then
  eval "$MOCK_AGENT_ACTION"
fi
# MOCK_WRITE_ACTION and MOCK_WRITE_EXIT apply only to write-capable sessions.
if [[ "$*" == *"--sandbox workspace-write"* || "$*" == *"--permission-mode acceptEdits"* ||
  "$*" == *"--permission-mode auto"* ]]; then
  if [[ -n "${MOCK_WRITE_ACTION:-}" ]]; then
    eval "$MOCK_WRITE_ACTION"
  fi
  if [[ -n "${MOCK_WRITE_EXIT:-}" ]]; then
    exit "$MOCK_WRITE_EXIT"
  fi
fi

if [[ "$agent" == "codex" ]]; then
  if [[ -n "$output_file" ]]; then
    printf '%s\n' "$output" >"$output_file"
  fi
elif [[ "$structured" -eq 1 ]]; then
  # Claude wraps structured output in a result envelope.
  if printf '%s' "$output" | jq -e . >/dev/null 2>&1; then
    printf '{"is_error": false, "structured_output": %s}\n' "$output"
  else
    jq -n --arg result "$output" '{is_error: false, result: $result}'
  fi
else
  printf '%s\n' "$output"
fi

exit "${MOCK_AGENT_EXIT:-0}"
AGENT
  cp "$bin/claude" "$bin/codex"
  chmod +x "$bin/claude" "$bin/codex"
}

# copy_workflow <repo>
# Copies the workflow scripts, libraries, prompts, and schemas into a test
# repository directory.
copy_workflow() {
  local repo="$1"
  local source_root

  source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
  mkdir -p "$repo/scripts/lib" "$repo/.agents/prompts" "$repo/.agents/schemas"
  cp "$source_root"/scripts/*.sh "$repo/scripts/"
  cp "$source_root"/scripts/lib/*.sh "$repo/scripts/lib/"
  cp "$source_root"/.agents/prompts/*.md "$repo/.agents/prompts/"
  cp "$source_root"/.agents/schemas/*.json "$repo/.agents/schemas/"
}

# record_reviewed_tree <repo> <review-json> [triage-json]
# Stores the current fingerprint of what a fixture review covers (its
# reviewed_paths, or the whole repository) as its reviewed tree, and copies it
# into a triage fixture, so the review is current.
record_reviewed_tree() {
  local repo="$1"
  local review="$2"
  local triage="${3:-}"
  local scratch
  local tree

  scratch="$(mktemp -d "${TMPDIR:-/tmp}/fingerprint.XXXXXX")"
  tree="$(
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/scripts/lib/fingerprint.sh"
    fingerprint_review "$repo" "$scratch" "$review"
  )"
  rm -rf "$scratch"

  jq --arg tree "$tree" '.reviewed_tree = $tree' "$review" >"$review.tmp" && mv "$review.tmp" "$review"
  if [[ -n "$triage" ]]; then
    jq --arg tree "$tree" '.reviewed_tree = $tree' "$triage" >"$triage.tmp" && mv "$triage.tmp" "$triage"
  fi
}
