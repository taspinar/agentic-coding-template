#!/usr/bin/env bash

# Shared agent configuration and launcher for the workflow scripts.
# Source this file; do not execute it. It uses Bash builtins, the selected
# agent CLI, jq when an agent is asked for structured output, and the run
# records of lib/records.sh, which record every call.
#
# Provider and model per role come from .agents/agents.conf. The --agent and
# --model options of a workflow script override that file. A requested model is
# always passed to the provider and is never replaced by another one.
#
# A role of a feature (implementer, reviewer, triage, triage-implementer) may
# have a line per risk level of the feature (lib/risk.sh), '<role>@<level>:
# <provider> <model>'. When a script starts such a role it takes, in this
# order: the command line; the line of the role and the effective level of
# the feature at that moment, raised to the highest level an earlier session
# of the feature ran at (the run records keep it); the plain line of the role.
# Without a level line the plain line applies, as before the levels existed.

# With Bash builtins only: doctor.sh loads this file with a minimal PATH.
agent_library_dir="${BASH_SOURCE[0]%/*}"
[[ "$agent_library_dir" != "${BASH_SOURCE[0]}" ]] || agent_library_dir="."
source "$agent_library_dir/records.sh"
source "$agent_library_dir/attribution.sh"

AGENT_ROLES="project-grill project-planner planning-reviewer implementer reviewer triage triage-implementer analyst"
# The roles that run for a feature, with its risk level; a '<role>@<level>'
# line of another role never applies.
AGENT_FEATURE_ROLES="implementer reviewer triage triage-implementer"
AGENT_LEVELS="low medium high"
# A reviewing role and the role whose work it reviews, which should use
# different providers; doctor.sh checks the resolved pair.
AGENT_REVIEW_PAIRS="reviewer:implementer planning-reviewer:project-planner"

agent_fail() {
  echo "Error: $*" >&2
  exit 1
}

# agent_parse_args "$@"
# Separates --agent/--model from the other arguments of a workflow script.
# Sets AGENT_CLI_PROVIDER, AGENT_CLI_MODEL, and the AGENT_POSITIONAL array.
# --unattended sets AGENT_UNATTENDED to 1: the script asks nothing and runs
# its writing agent with the 'unattended' profile. A script that cannot run
# that way calls agent_reject_unattended.
agent_parse_args() {
  AGENT_CLI_PROVIDER=""
  AGENT_CLI_MODEL=""
  AGENT_UNATTENDED=0
  AGENT_POSITIONAL=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --unattended)
        AGENT_UNATTENDED=1
        shift
        ;;
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

agent_reject_unattended() {
  [[ "${AGENT_UNATTENDED:-0}" -eq 0 ]] ||
    agent_fail "this step needs your decisions and cannot run with --unattended."
}

# agent_require_ignored <root> <path>
# Fails unless Git ignores <path> in the working tree at <root>. A working
# file that is not ignored would be committed with the feature, and would
# change the content that a verification or review was recorded for.
agent_require_ignored() {
  git -C "$1" check-ignore -q "$2" 2>/dev/null ||
    agent_fail "Git does not ignore $2 in $1. Add '$(dirname "$2")/' to .gitignore, or take over the template's .gitignore with ./scripts/sync-template.sh."
}

# What an unattended writing agent is told, in addition to its task.
AGENT_UNATTENDED_PROMPT="This session is unattended: nobody reads along and nobody answers questions.
Do not ask anything and do not wait for the human. When you cannot continue
without a decision of the human, or the work conflicts with the Issue's scope,
the architecture, or an ADR, stop: record the question under 'Open questions'
in the handoff note, and end your final message with one line that starts with
'BLOCKED: ' and gives the reason. Otherwise finish the work and end normally.

BLOCKED is only for that. A verification is not a decision: when
./scripts/verify.sh fails on something outside your work, does not finish
within your session, or cannot run here, do not write a BLOCKED line. Say in
your final message and in the handoff note what happened and what you checked
instead, and end normally. The script that started you verifies the result
after your session and stops the run when the verification really fails.

Ending normally does not mean that the Issue is done. Before you end, write
the completion record that the implementer contract describes under
'Completion', with the status complete, awaiting_evidence, partial, or blocked
as it really is. awaiting_evidence is only for criteria whose evidence cannot
exist yet (CI of the pull request, the owner's approval, the default branch
after the merge). The scripts go on to the review and the commit on 'complete'
or 'awaiting_evidence', and start you again when work remains."

# agent_blocked_reason <final-message-file>
# Prints the reason of the last 'BLOCKED: ' line of an unattended session's
# final message, or nothing when the session did not report one.
agent_blocked_reason() {
  [[ -f "$1" ]] || return 0
  sed -n 's/^[[:space:]]*BLOCKED:[[:space:]]*//p' "$1" | tail -n 1
}

# agent_lookup <root> <role> [level]
# Validates the complete configuration while it reads the file: the structure
# of every line, and the provider and the model of every line, the level
# lines like the plain ones, whether or not the line is the one asked for.
# An invalid line of any role fails before a role is resolved. Only the CLI
# of a provider is not checked here: a missing CLI is reported for the
# provider that is selected (agent_validate), and doctor.sh for the
# providers that the file needs. Sets AGENT_CONFIG_PROVIDER and
# AGENT_CONFIG_MODEL from the plain line of the role, AGENT_LEVEL_PROVIDER
# and AGENT_LEVEL_MODEL from its line for <level>, and AGENT_CONFIG_LEVELS
# to the levels the role has a line for. What has no line, or the whole
# file, stays empty.
agent_lookup() {
  local root="$1"
  local role="$2"
  local level="${3:-}"
  local config="${AGENT_CONFIG_FILE:-$root/.agents/agents.conf}"
  local comment_pattern='^[[:space:]]*(#.*)?$'
  local entry_pattern='^([a-z][a-z-]*)(@([a-z]+))?:[[:space:]]*([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]*$'
  local line
  local line_number=0
  local seen=" "
  local entry_role
  local entry_level
  local entry_key
  local entry_provider
  local entry_model

  AGENT_CONFIG_PROVIDER=""
  AGENT_CONFIG_MODEL=""
  AGENT_LEVEL_PROVIDER=""
  AGENT_LEVEL_MODEL=""
  AGENT_CONFIG_LEVELS=""

  [[ " $AGENT_ROLES " == *" $role "* ]] || agent_fail "unknown agent role: $role"
  [[ -z "$level" || " $AGENT_LEVELS " == *" $level "* ]] || agent_fail "unknown risk level: $level"
  [[ -f "$config" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    [[ "$line" =~ $comment_pattern ]] && continue
    [[ "$line" =~ $entry_pattern ]] ||
      agent_fail "malformed entry on line $line_number of $config; expected '<role>: <provider> <model>' or '<role>@<level>: <provider> <model>'."
    entry_role="${BASH_REMATCH[1]}"
    entry_level="${BASH_REMATCH[3]}"
    entry_provider="${BASH_REMATCH[4]}"
    entry_model="${BASH_REMATCH[5]}"
    [[ " $AGENT_ROLES " == *" $entry_role "* ]] ||
      agent_fail "unknown role '$entry_role' on line $line_number of $config. Known roles: $AGENT_ROLES"
    [[ -z "$entry_level" || " $AGENT_LEVELS " == *" $entry_level "* ]] ||
      agent_fail "unknown risk level '$entry_level' on line $line_number of $config; a level line is '<role>@<level>: <provider> <model>' with low, medium, or high."
    entry_key="$entry_role${entry_level:+@$entry_level}"
    [[ "$seen" != *" $entry_key "* ]] ||
      agent_fail "role '$entry_key' is configured more than once in $config."
    seen+="$entry_key "
    agent_check_pair "$entry_provider" "$entry_model" " for role '$entry_key' on line $line_number of $config"

    [[ "$entry_role" == "$role" ]] || continue
    if [[ -z "$entry_level" ]]; then
      AGENT_CONFIG_PROVIDER="$entry_provider"
      AGENT_CONFIG_MODEL="$entry_model"
    else
      AGENT_CONFIG_LEVELS+="${AGENT_CONFIG_LEVELS:+ }$entry_level"
      if [[ "$entry_level" == "$level" ]]; then
        AGENT_LEVEL_PROVIDER="$entry_provider"
        AGENT_LEVEL_MODEL="$entry_model"
      fi
    fi
  done <"$config"
}

# agent_check_pair <provider> <model> [where]
# Fails unless the provider is supported, the model is well-formed, and the
# combination is one the provider accepts. <where> names the source of the
# pair in the message, for a line of the configuration; the command line
# and the resolved pair give none. Whether the CLI of the provider is
# installed is not checked here: that is required only of a provider that
# is selected (agent_validate) or that the configuration needs (doctor.sh).
agent_check_pair() {
  local provider="$1"
  local model="$2"
  local where="${3:-}"
  local model_pattern='^[A-Za-z0-9][A-Za-z0-9._:/+@-]*$'

  case "$provider" in
    codex | claude) ;;
    *) agent_fail "unsupported agent '$provider'$where. Supported agents: codex, claude." ;;
  esac

  [[ "$model" =~ $model_pattern ]] ||
    agent_fail "model must use only letters, numbers, '.', '_', ':', '/', '+', '@', or '-': $model$where"

  case "$provider:$model" in
    codex:fable | claude:astra)
      agent_fail "unsupported agent/model combination: $provider + $model$where."
      ;;
  esac
}

# agent_validate <provider> <model>
# Checks the pair that was selected for a role (agent_check_pair), and that
# the CLI of its provider is installed.
agent_validate() {
  agent_check_pair "$1" "$2"
  command -v "$1" >/dev/null 2>&1 ||
    agent_fail "'$1' command not found. Install the $1 CLI or select another agent."
}

# agent_resolve <root> <role> [provider-override] [model-override] [level]
# Sets AGENT_PROVIDER and AGENT_MODEL, or fails before any side effect. With
# a <level>, the risk level of the feature the role runs for, the line
# '<role>@<level>' of the configuration is taken before the plain line of the
# role; the command line comes before both. AGENT_LEVEL holds the level and
# AGENT_SELECTION where the selection came from: 'command-line',
# 'level-line', or 'plain-line'; the run records note both for every call.
agent_resolve() {
  local root="$1"
  local role="$2"
  local override_provider="${3:-}"
  local override_model="${4:-}"
  local level="${5:-}"
  local config_provider
  local config_model
  local configured
  local selection
  local provider
  local model

  agent_lookup "$root" "$role" "$level"

  if [[ -n "$level" && -n "$AGENT_LEVEL_PROVIDER" ]]; then
    config_provider="$AGENT_LEVEL_PROVIDER"
    config_model="$AGENT_LEVEL_MODEL"
    configured="role '$role' at risk level $level ('$role@$level')"
    selection="level-line"
  else
    config_provider="$AGENT_CONFIG_PROVIDER"
    config_model="$AGENT_CONFIG_MODEL"
    configured="role '$role'"
    selection="plain-line"
  fi
  [[ -z "$override_provider$override_model" ]] || selection="command-line"

  provider="${override_provider:-$config_provider}"
  [[ -n "$provider" ]] ||
    agent_fail "no agent is configured for role '$role'. Add '$role: <provider> <model>' to .agents/agents.conf or pass --agent and --model."

  if [[ -n "$override_model" ]]; then
    model="$override_model"
  elif [[ "$provider" == "$config_provider" ]]; then
    model="$config_model"
  else
    agent_fail "--agent $provider differs from the provider configured for $configured; pass --model as well."
  fi

  agent_validate "$provider" "$model"
  AGENT_PROVIDER="$provider"
  AGENT_MODEL="$model"
  # The role, the level, and the selection the run records name for the
  # agent calls that follow.
  AGENT_ROLE="$role"
  AGENT_LEVEL="$level"
  AGENT_SELECTION="$selection"
}

# agent_selection_text
# One line that says how the agent of the last agent_resolve was selected,
# for the output of a script.
agent_selection_text() {
  case "${AGENT_SELECTION:-}" in
    command-line) echo "--agent or --model on the command line" ;;
    level-line) echo "the line '$AGENT_ROLE@$AGENT_LEVEL' of .agents/agents.conf" ;;
    *)
      if [[ -n "${AGENT_LEVEL:-}" ]]; then
        echo "the plain line of '$AGENT_ROLE' (no '$AGENT_ROLE@$AGENT_LEVEL' line)"
      else
        echo "the plain line of '$AGENT_ROLE'"
      fi
      ;;
  esac
}

# agent_computed_level <worktree> <base>
# Prints the effective risk level of the feature in <worktree> as
# check-risk.sh computes it now, and after a tab where it comes from. A
# level that cannot be determined is high, as the risk library has it: a
# feature that cannot be classified never gets the agent of a lesser one.
agent_computed_level() {
  local output
  local status=0
  local level

  output="$( (cd "$1" && ./scripts/check-risk.sh "$2" </dev/null) 2>&1)" || status=$?
  level="$(printf '%s\n' "$output" | sed -n '1s/^risk: //p')"
  if [[ "$status" -gt 2 || -z "$level" ]]; then
    printf 'high\tthe level could not be determined (check-risk.sh exited with status %s); a feature that cannot be classified is high\n' "$status"
    return 0
  fi
  printf '%s\tcomputed by check-risk.sh against %s\n' "$level" "$2"
}

# agent_feature_level <issue> <level> <why>
# Prints the level that selects the agent of a role of feature <issue>, and
# after a tab why: the <level> computed now, raised to the highest level that
# the run records of the feature hold, so that a later session never runs at
# a weaker configured level than an earlier one did.
agent_feature_level() {
  local issue="$1"
  local level="$2"
  local why="$3"
  local highest=""

  if declare -F records_highest_level >/dev/null; then
    highest="$(records_highest_level "$issue" 2>/dev/null)" || highest=""
  fi
  if [[ -n "$highest" && "$(agent_level_rank "$highest")" -gt "$(agent_level_rank "$level")" ]]; then
    printf '%s\tan earlier session of the feature ran at %s (the run records); %s now, %s\n' "$highest" "$highest" "$level" "$why"
  else
    printf '%s\t%s\n' "$level" "$why"
  fi
}

# agent_level_rank <level>: 0 for low, 1 for medium, 2 for high; -1 otherwise.
agent_level_rank() {
  case "$1" in
    low) echo 0 ;;
    medium) echo 1 ;;
    high) echo 2 ;;
    *) echo -1 ;;
  esac
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
      echo "- Codex works inside this worktree without asking, with network access. It"
      echo "  asks your permission for a command that needs more, such as writing"
      echo "  outside the worktree."
      echo "- When the agent says it is done, type /quit. This script then continues."
      ;;
  esac
  echo
}

# agent_run <profile> <provider> <model> <workdir> <prompt> [output-file] [context-file] [schema-file]
#
# Profiles:
#   write      Interactive session that may modify the work directory and
#              use the network. What goes beyond that needs the user's
#              permission: Claude asks before it runs a shell command, Codex
#              before a command leaves its work-directory sandbox.
#              When the project disables agent attribution
#              (.agents/attribution.conf), a Claude session of this profile
#              and of 'unattended' is started with the setting that turns off
#              its commit trailer and its pull request line; Codex has no
#              such setting.
#   unattended Non-interactive session with the reach of 'write': it may
#              modify the work directory and use the network, needs no
#              terminal, asks nothing, and ends by itself. The agent's final
#              message is stored in <output-file>. What 'write' would ask the
#              user is decided without them: Codex stays inside its
#              work-directory sandbox and is refused what leaves it; Claude
#              runs in its 'auto' permission mode, whose own check allows or
#              denies each action, and anything that would still prompt is
#              denied. Like a read-only session it gets no MCP servers, apps,
#              or other tools from the user's configuration, because those
#              act outside the sandbox: Codex runs without the user's
#              config.toml and with apps, browser use, and computer use
#              disabled; Claude runs without MCP configuration.
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
  local started
  local call=""
  local status=0

  started="$(date +%s)"
  # The start of the call, so that an interrupted one stays visible, and at
  # its end the duration and the usage its provider reported; nothing of the
  # prompt or of the answer.
  if declare -F records_agent_start >/dev/null; then
    call="$(records_id)"
    records_agent_start "$call" "${AGENT_ROLE:-unknown}" "$1" "$2" "$3" "${AGENT_LEVEL:-}" "${AGENT_SELECTION:-}"
  fi
  # The experience notes that an implementing session writes belong to its
  # run (lib/experience.sh); only their hash is recorded here.
  local notes_before=""
  if declare -F experience_notes_hash >/dev/null; then
    notes_before="$(experience_notes_hash "$4")"
  fi
  agent_run_session "$@" || status=$?
  if declare -F records_agent_call >/dev/null; then
    records_agent_call "${AGENT_ROLE:-unknown}" "$1" "$2" "$3" "$(($(date +%s) - started))" "$status" "${6:-}" "$call" "${AGENT_LEVEL:-}" "${AGENT_SELECTION:-}"
  fi
  if declare -F experience_notes_written >/dev/null; then
    experience_notes_written "$4" "$notes_before" "$call" 2>/dev/null || true
  fi
  return "$status"
}

# agent_run_session: agent_run without the record of the call.
# agent_codex_errors <events-file>: the error messages of a Codex session,
# from its JSON events, one per line; a message that is itself the JSON of an
# API error gives its inner message.
agent_codex_errors() {
  [[ -s "$1" ]] || return 0
  jq -r 'select(.type == "error" or .type == "turn.failed") | (.message // .error.message // empty)
    | . as $message | (try (fromjson | .error.message // .message // tostring) catch $message)' "$1" 2>/dev/null | awk '!seen[$0]++' || true
}

# agent_report_failure <provider> <prompt> <diagnostics>: says why a session
# failed, as the provider said it in its error messages and its error output,
# and names a usage or rate limit as one, so that you know to wait instead of
# looking for a defect. What looks like a key or a token, a private key with
# its whole body, is replaced first, over the whole text; then every line of
# the prompt of four characters or more is replaced by [prompt] wherever it
# appears, also behind a prefix, and a line that looks like the body of a key
# is replaced; only then is the output cut to its last ten lines.
agent_report_failure() {
  local provider="$1"
  local prompt="$2"
  local diagnostics="$3"
  local lines
  local cleaned

  [[ -n "$diagnostics" ]] || return 0
  if [[ -n "${RECORDS_REDACT_JQ:-}" ]] && command -v jq >/dev/null 2>&1; then
    diagnostics="$(printf '%s' "$diagnostics" | jq -Rrs "$RECORDS_REDACT_JQ redact" 2>/dev/null)" ||
      diagnostics="(the error output could not be shown safely)"
    # The prompt is matched as it was and as the redaction left it, so that
    # a line of the prompt that held a secret is found too.
    prompt="$prompt
$(printf '%s' "$prompt" | jq -Rrs "$RECORDS_REDACT_JQ redact" 2>/dev/null || true)"
  fi
  cleaned="$(printf '%s\n' "$diagnostics" | PROMPT="$prompt" awk '
      BEGIN { n = split(ENVIRON["PROMPT"], parts, "\n") }
      # word <char>: whether a character belongs to a word.
      function word(c) { return c ~ /[A-Za-z0-9_]/ }
      {
        line = $0
        for (i = 1; i <= n; i++) {
          part = parts[i]
          if (length(part) == 0) continue
          # One pass over the text: what is put in is not searched again. A
          # part shorter than four characters is replaced only as a word of
          # its own.
          done = ""
          rest = line
          while ((at = index(rest, part)) > 0) {
            prefix = done substr(rest, 1, at - 1)
            before = substr(prefix, length(prefix), 1)
            after = substr(rest, at + length(part), 1)
            if (length(part) >= 4 || (!word(before) && !word(after))) {
              done = done substr(rest, 1, at - 1) "[prompt]"
            } else {
              done = done substr(rest, 1, at - 1 + length(part))
            }
            rest = substr(rest, at + length(part))
          }
          line = done rest
        }
        if (line ~ /^[[:space:]]*(\[prompt\][[:space:]]*)*$/) next
        # The body of a key whose first line was not in the output.
        if (length(line) >= 40 && line ~ /^[[:space:]]*[A-Za-z0-9+\/=]+[[:space:]]*$/) line = "[redacted]"
        print line
      }')"
  lines="$(printf '%s\n' "$cleaned" | tail -n 10)"
  [[ -n "$lines" ]] || return 0
  echo "The $provider session reported:" >&2
  printf '%s\n' "$lines" | sed 's/^/  /' >&2
  # A limit is named also when later lines push it out of the lines shown.
  if grep -Eiq 'usage limit|rate limit|quota|too many requests|credit balance|limit reached' <<<"$cleaned"; then
    echo "This is a usage limit of $provider, not a defect: run the step again after the time the provider names." >&2
  fi
}

# agent_write_failed <provider> <status>: a write session runs in your
# terminal, where the agent shows its own messages as it works; capturing them
# would take the terminal from it. The script repeats nothing of them, so it
# adds no prompt or secret of its own: it says only that the session failed,
# and returns its status.
agent_write_failed() {
  echo "The $1 session ended with status $2; its own messages are above in this terminal." >&2
  return "$2"
}

agent_run_session() {
  local profile="$1"
  local provider="$2"
  local model="$3"
  local workdir="$4"
  local prompt="$5"
  local output_file="${6:-}"
  local context_file="${7:-/dev/null}"
  local schema_file="${8:-}"
  local codex_schema=()
  local claude_settings=()
  local attribution
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
    write | unattended | read-only) ;;
    *) agent_fail "unknown permission profile '$profile'. Known profiles: write, unattended, read-only." ;;
  esac

  if [[ "$profile" != "write" && -z "$output_file" ]]; then
    agent_fail "permission profile '$profile' requires an output file."
  fi

  # An unattended session gets its whole task in the prompt; a context or
  # schema file would be dropped without notice.
  if [[ "$profile" == "unattended" && ( "$context_file" != "/dev/null" || -n "$schema_file" ) ]]; then
    agent_fail "permission profile 'unattended' takes no context file or schema file."
  fi

  # Claude Code follows the project's attribution preference through its
  # settings; the setting is given on the command line, so a session the
  # scripts start follows it also without a .claude/settings.json. Only a
  # session that may commit gets it: a read-only session changes nothing.
  if [[ "$provider" == "claude" && "$profile" != "read-only" ]]; then
    attribution="$(attribution_preference "$workdir")" || return 1
    if [[ "$attribution" == "disabled" ]]; then
      claude_settings=(--settings '{"attribution": {"commit": "", "pr": "", "sessionUrl": false}}')
    fi
  fi

  if [[ "$profile" == "unattended" ]]; then
    echo "An unattended $provider session starts now. It asks nothing and ends by itself;"
    echo "this can take a long time. Its final message is stored in:"
    echo "  $output_file"
    echo
  fi

  if [[ "$profile" == "write" ]]; then
    agent_session_notice "$provider"
  fi

  case "$provider:$profile" in
    codex:write)
      (
        cd "$workdir"
        # Codex works freely inside the work directory, with network access
        # so it can install dependencies and run builds; its workspace sandbox
        # blocks the network by default. For a command the sandbox blocks,
        # Codex asks the user instead of failing. Without a sandbox Codex has
        # no policy that asks per command, so that is not used.
        codex \
          -c sandbox_workspace_write.network_access=true \
          --sandbox workspace-write \
          --ask-for-approval on-request \
          --model "$model" \
          --cd "$workdir" \
          "$prompt"
      ) || agent_write_failed codex $?
      ;;
    claude:write)
      (
        cd "$workdir"
        claude \
          --permission-mode acceptEdits \
          ${claude_settings[@]+"${claude_settings[@]}"} \
          --model "$model" \
          "$prompt"
      ) || agent_write_failed claude $?
      ;;
    codex:unattended)
      # As a write session, but without a terminal: 'codex exec' never asks,
      # so a command its sandbox blocks is refused instead of approved.
      status=0
      (
        cd "$workdir"
        codex exec \
          --ignore-user-config \
          -c sandbox_workspace_write.network_access=true \
          --sandbox workspace-write \
          --disable apps \
          --disable browser_use \
          --disable computer_use \
          --color never \
          --json \
          --cd "$workdir" \
          --output-last-message "$output_file" \
          --model "$model" \
          "$prompt"
      ) </dev/null >"$output_file.events" 2>"$output_file.log" || status=$?

      # Nothing validates the result afterwards, so a session without a
      # final message counts as failed. Its own output says why.
      if [[ "$status" -ne 0 || ! -s "$output_file" ]]; then
        echo "The unattended codex session failed or left no final message; its log is $output_file.log." >&2
        agent_report_failure codex "$prompt" "$(cat "$output_file.log" 2>/dev/null; agent_codex_errors "$output_file.events")"
        [[ "$status" -ne 0 ]] || status=1
        return "$status"
      fi
      ;;
    claude:unattended)
      command -v jq >/dev/null 2>&1 || agent_fail "jq is required for an unattended Claude session."

      # 'auto' lets Claude's own permission check decide each action; with no
      # one to answer, whatever would still prompt is denied.
      envelope="$output_file.envelope"
      status=0
      (
        cd "$workdir"
        claude \
          --print \
          --permission-mode auto \
          --permission-prompts none \
          --strict-mcp-config \
          --output-format json \
          ${claude_settings[@]+"${claude_settings[@]}"} \
          --model "$model" \
          "$prompt"
      ) </dev/null >"$envelope" 2>"$output_file.log" || status=$?

      if [[ "$status" -ne 0 ]] || jq -e '.is_error == true' "$envelope" >/dev/null 2>&1; then
        agent_report_failure claude "$prompt" "$(cat "$output_file.log" 2>/dev/null; jq -r 'select(.is_error == true) | .result // empty' "$envelope" 2>/dev/null)"
        [[ "$status" -ne 0 ]] || status=1
        return "$status"
      fi
      # Nothing validates this result afterwards, so anything but a result
      # envelope with a final message counts as a failed session.
      if ! jq -er '.result | strings' "$envelope" >"$output_file" 2>/dev/null; then
        echo "The unattended claude session returned no final message; its output is in $envelope." >&2
        agent_report_failure claude "$prompt" "$(cat "$output_file.log" 2>/dev/null)"
        return 1
      fi
      ;;
    codex:read-only)
      status=0
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
        --json \
        --cd "$workdir" \
        --output-last-message "$output_file" \
        --model "$model" \
        ${codex_schema[@]+"${codex_schema[@]}"} \
        "$prompt" <"$context_file" >"$output_file.events" 2>"$output_file.log" || status=$?
      # In --json mode Codex writes its errors as events, so they are not on
      # the terminal: say them here, with its error output.
      if [[ "$status" -ne 0 ]]; then
        agent_report_failure codex "$prompt" "$(cat "$output_file.log" 2>/dev/null; agent_codex_errors "$output_file.events")"
        return "$status"
      fi
      ;;
    claude:read-only)
      if [[ -z "$schema_file" ]]; then
        status=0
        (
          cd "$workdir"
          claude "${claude_read_only[@]}" --model "$model" "$prompt"
        ) <"$context_file" >"$output_file" 2>"$output_file.log" || status=$?
        # The ordinary answer is not an error message: only the error output.
        [[ "$status" -eq 0 ]] || agent_report_failure claude "$prompt" "$(cat "$output_file.log" 2>/dev/null)"
        return "$status"
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
      ) <"$context_file" >"$envelope" 2>"$output_file.log" || status=$?

      if [[ "$status" -ne 0 ]] || jq -e '.is_error == true' "$envelope" >/dev/null 2>&1; then
        agent_report_failure claude "$prompt" "$(cat "$output_file.log" 2>/dev/null; jq -r 'select(.is_error == true) | .result // empty' "$envelope" 2>/dev/null)"
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
