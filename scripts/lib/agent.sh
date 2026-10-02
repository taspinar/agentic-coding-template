#!/usr/bin/env bash

# Shared agent configuration and launcher for the workflow scripts.
# Source this file; do not execute it. It uses only Bash builtins besides the
# selected agent CLI.
#
# Provider and model per role come from .agents/agents.conf. The --agent and
# --model options of a workflow script override that file. A requested model is
# always passed to the provider and is never replaced by another one.

AGENT_ROLES="project-grill project-planner planning-reviewer implementer reviewer triage triage-implementer"

agent_fail() {
  echo "Error: $*" >&2
  exit 1
}

# agent_parse_args "$@"
# Separates --agent/--model from the other arguments of a workflow script.
# Sets AGENT_CLI_PROVIDER, AGENT_CLI_MODEL, and the AGENT_POSITIONAL array.
agent_parse_args() {
  AGENT_CLI_PROVIDER=""
  AGENT_CLI_MODEL=""
  AGENT_POSITIONAL=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent | --model)
        [[ $# -ge 2 && -n "$2" ]] || agent_fail "$1 requires a value."
        if [[ "$1" == "--agent" ]]; then
          AGENT_CLI_PROVIDER="$2"
        else
          AGENT_CLI_MODEL="$2"
        fi
        shift 2
        ;;
      *)
        AGENT_POSITIONAL+=("$1")
        shift
        ;;
    esac
  done
}

# agent_lookup <root> <role>
# Validates the complete configuration and sets AGENT_CONFIG_PROVIDER and
# AGENT_CONFIG_MODEL for the role; both stay empty when the role, or the whole
# file, is absent.
agent_lookup() {
  local root="$1"
  local role="$2"
  local config="${AGENT_CONFIG_FILE:-$root/.agents/agents.conf}"
  local comment_pattern='^[[:space:]]*(#.*)?$'
  local entry_pattern='^([a-z][a-z-]*):[[:space:]]*([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]*$'
  local line
  local line_number=0
  local seen=" "

  AGENT_CONFIG_PROVIDER=""
  AGENT_CONFIG_MODEL=""

  [[ " $AGENT_ROLES " == *" $role "* ]] || agent_fail "unknown agent role: $role"
  [[ -f "$config" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    [[ "$line" =~ $comment_pattern ]] && continue
    [[ "$line" =~ $entry_pattern ]] ||
      agent_fail "malformed entry on line $line_number of $config; expected '<role>: <provider> <model>'."
    [[ " $AGENT_ROLES " == *" ${BASH_REMATCH[1]} "* ]] ||
      agent_fail "unknown role '${BASH_REMATCH[1]}' on line $line_number of $config. Known roles: $AGENT_ROLES"
    [[ "$seen" != *" ${BASH_REMATCH[1]} "* ]] ||
      agent_fail "role '${BASH_REMATCH[1]}' is configured more than once in $config."
    seen+="${BASH_REMATCH[1]} "

    if [[ "${BASH_REMATCH[1]}" == "$role" ]]; then
      AGENT_CONFIG_PROVIDER="${BASH_REMATCH[2]}"
      AGENT_CONFIG_MODEL="${BASH_REMATCH[3]}"
    fi
  done <"$config"
}

# agent_validate <provider> <model>
agent_validate() {
  local provider="$1"
  local model="$2"
  local model_pattern='^[A-Za-z0-9][A-Za-z0-9._:/+@-]*$'

  case "$provider" in
    codex | claude) ;;
    *) agent_fail "unsupported agent '$provider'. Supported agents: codex, claude." ;;
  esac

  [[ "$model" =~ $model_pattern ]] ||
    agent_fail "model must use only letters, numbers, '.', '_', ':', '/', '+', '@', or '-': $model"

  case "$provider:$model" in
    codex:fable | claude:astra)
      agent_fail "unsupported agent/model combination: $provider + $model."
      ;;
  esac

  command -v "$provider" >/dev/null 2>&1 ||
    agent_fail "'$provider' command not found. Install the $provider CLI or select another agent."
}

# agent_resolve <root> <role> [provider-override] [model-override]
# Sets AGENT_PROVIDER and AGENT_MODEL, or fails before any side effect.
agent_resolve() {
  local root="$1"
  local role="$2"
  local override_provider="${3:-}"
  local override_model="${4:-}"
  local provider
  local model

  agent_lookup "$root" "$role"

  provider="${override_provider:-$AGENT_CONFIG_PROVIDER}"
  [[ -n "$provider" ]] ||
    agent_fail "no agent is configured for role '$role'. Add '$role: <provider> <model>' to .agents/agents.conf or pass --agent and --model."

  if [[ -n "$override_model" ]]; then
    model="$override_model"
  elif [[ "$provider" == "$AGENT_CONFIG_PROVIDER" ]]; then
    model="$AGENT_CONFIG_MODEL"
  else
    agent_fail "--agent $provider differs from the provider configured for role '$role'; pass --model as well."
  fi

  agent_validate "$provider" "$model"
  AGENT_PROVIDER="$provider"
  AGENT_MODEL="$model"
}

# agent_run_interactive <provider> <model> <workdir> <prompt>
# Starts an interactive, write-capable session. Returns the agent's status.
agent_run_interactive() {
  local provider="$1"
  local model="$2"
  local workdir="$3"
  local prompt="$4"

  case "$provider" in
    codex)
      (
        cd "$workdir"
        codex \
          --sandbox workspace-write \
          --ask-for-approval never \
          --model "$model" \
          --cd "$workdir" \
          "$prompt"
      )
      ;;
    claude)
      (
        cd "$workdir"
        claude \
          --permission-mode acceptEdits \
          --model "$model" \
          "$prompt"
      )
      ;;
    *) agent_fail "unsupported agent '$provider'. Supported agents: codex, claude." ;;
  esac
}

# agent_run_report <provider> <model> <workdir> <prompt> <output-file>
# Runs a non-interactive, read-only session and stores the agent's final
# message in the output file. Returns the agent's status.
agent_run_report() {
  local provider="$1"
  local model="$2"
  local workdir="$3"
  local prompt="$4"
  local output_file="$5"

  case "$provider" in
    codex)
      codex exec \
        --sandbox read-only \
        --ephemeral \
        --color never \
        --cd "$workdir" \
        --output-last-message "$output_file" \
        --model "$model" \
        "$prompt" >/dev/null
      ;;
    claude)
      (
        cd "$workdir"
        claude \
          --print \
          --permission-mode plan \
          --tools "Read,Glob,Grep" \
          --no-session-persistence \
          --model "$model" \
          "$prompt"
      ) >"$output_file"
      ;;
    *) agent_fail "unsupported agent '$provider'. Supported agents: codex, claude." ;;
  esac
}
