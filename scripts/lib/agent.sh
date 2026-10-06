#!/usr/bin/env bash

# Shared agent configuration and launcher for the workflow scripts.
# Source this file; do not execute it. It uses only Bash builtins besides the
# selected agent CLI, and jq when an agent is asked for structured output.
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

# agent_session_notice <provider>
# Tells the user how an interactive session behaves and how the calling
# script continues, before the agent's own interface takes over the terminal.
agent_session_notice() {
  echo "An interactive $1 session starts now. This script waits for it."
  case "$1" in
    claude)
      echo "- Claude may ask your permission before it runs a shell command. That is"
      echo "  normal; file edits in the worktree are accepted automatically."
      echo "- When the agent says it is done, type /exit. This script then continues."
      ;;
    codex)
      echo "- Codex works without asking for permission. It can write only inside this"
      echo "  worktree and has network access, for example to install dependencies."
      echo "- When the agent says it is done, type /quit. This script then continues."
      ;;
  esac
  echo
}

# agent_run <profile> <provider> <model> <workdir> <prompt> [output-file] [context-file] [schema-file]
#
# Profiles:
#   write      Interactive session that may modify the work directory and
#              use the network. Codex writes only inside the work directory;
#              Claude asks the user before it runs a shell command.
#   read-only  Non-interactive session that cannot modify files. The agent's
#              final message is stored in <output-file>. <context-file>, when
#              given, is supplied to the agent on standard input. With a
#              <schema-file> (JSON Schema), the provider is asked for
#              structured output and <output-file> holds that JSON; the
#              caller must still validate it.
#
# Read-only sessions are isolated from the user's configuration, so they get no
# MCP servers, apps, or other tools that act outside the sandbox. Codex runs in
# its read-only sandbox without the user's config.toml and with apps, browser
# use, computer use, and web search disabled. Claude runs restricted, without
# user, project, or MCP configuration, with only its Read, Glob, and Grep tools,
# and without asking for any further permission.
#
# A profile that the provider cannot enforce is an error; the agent is never
# started with broader permissions instead. Returns the agent's status; a
# Claude session that reports an error returns 1 even when the CLI exits 0.
agent_run() {
  local profile="$1"
  local provider="$2"
  local model="$3"
  local workdir="$4"
  local prompt="$5"
  local output_file="${6:-}"
  local context_file="${7:-/dev/null}"
  local schema_file="${8:-}"
  local codex_schema=()
  local claude_read_only=(
    --print
    --restricted
    --strict-mcp-config
    --permission-mode dontAsk
    --tools "Read,Glob,Grep"
    --no-session-persistence
  )
  local envelope
  local status

  case "$profile" in
    write | read-only) ;;
    *) agent_fail "unknown permission profile '$profile'. Known profiles: write, read-only." ;;
  esac

  if [[ "$profile" == "read-only" && -z "$output_file" ]]; then
    agent_fail "permission profile 'read-only' requires an output file."
  fi

  if [[ "$profile" == "write" ]]; then
    agent_session_notice "$provider"
  fi

  case "$provider:$profile" in
    codex:write)
      (
        cd "$workdir"
        # Writing stays confined to the work directory. Network access is on,
        # as in a Claude write session, so the agent can install dependencies
        # and run builds; Codex's workspace sandbox blocks it by default.
        codex \
          -c sandbox_workspace_write.network_access=true \
          --sandbox workspace-write \
          --ask-for-approval never \
          --model "$model" \
          --cd "$workdir" \
          "$prompt"
      )
      ;;
    claude:write)
      (
        cd "$workdir"
        claude \
          --permission-mode acceptEdits \
          --model "$model" \
          "$prompt"
      )
      ;;
    codex:read-only)
      if [[ -n "$schema_file" ]]; then
        codex_schema=(--output-schema "$schema_file")
      fi
      codex exec \
        --ignore-user-config \
        --sandbox read-only \
        --disable apps \
        --disable browser_use \
        --disable computer_use \
        -c 'web_search="disabled"' \
        --ephemeral \
        --color never \
        --cd "$workdir" \
        --output-last-message "$output_file" \
        --model "$model" \
        ${codex_schema[@]+"${codex_schema[@]}"} \
        "$prompt" <"$context_file" >/dev/null
      ;;
    claude:read-only)
      if [[ -z "$schema_file" ]]; then
        (
          cd "$workdir"
          claude "${claude_read_only[@]}" --model "$model" "$prompt"
        ) <"$context_file" >"$output_file"
        return
      fi

      command -v jq >/dev/null 2>&1 || agent_fail "jq is required for structured agent output."

      # Claude returns structured output inside a JSON result envelope.
      envelope="$output_file.envelope"
      # Capture the status without toggling errexit, which belongs to the caller.
      status=0
      (
        cd "$workdir"
        claude "${claude_read_only[@]}" \
          --model "$model" \
          --output-format json \
          --json-schema "$(<"$schema_file")" \
          "$prompt"
      ) <"$context_file" >"$envelope" || status=$?

      if [[ "$status" -ne 0 ]] || jq -e '.is_error == true' "$envelope" >/dev/null 2>&1; then
        jq -r '.result // empty' "$envelope" >&2 2>/dev/null || cat "$envelope" >&2
        [[ "$status" -ne 0 ]] || status=1
        return "$status"
      fi

      # Without structured output, hand the raw result to the caller's
      # validation, which rejects it.
      jq -e '.structured_output // (.result | fromjson?)' "$envelope" >"$output_file" 2>/dev/null ||
        jq -r '.result // empty' "$envelope" >"$output_file" 2>/dev/null ||
        cp "$envelope" "$output_file"
      ;;
    *)
      agent_fail "agent '$provider' cannot enforce permission profile '$profile'."
      ;;
  esac
}
