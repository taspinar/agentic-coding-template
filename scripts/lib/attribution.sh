#!/usr/bin/env bash

# Agent attribution in commits and pull requests: the project's preference,
# and the check of what the scripts commit and publish.
# Source this file; do not execute it. Reading the preference and checking a
# text use Bash builtins only; checking commits uses git.
#
# The preference is one setting in .agents/attribution.conf:
#
#   agent-attribution: allowed | disabled
#
# allowed: agents attribute their work as their clients do; nothing is
# checked. disabled: no commit of a feature may carry an agent's
# Co-authored-by trailer, and no pull request description may carry generated
# attribution text. A project without the setting is 'unconfigured', which
# the scripts treat like 'allowed': what every project did before the setting
# existed.

ATTRIBUTION_CONFIG=".agents/attribution.conf"
ATTRIBUTION_SETTING="agent-attribution"

attribution_fail() {
  echo "Error: $*" >&2
  return 1
}

# attribution_preference <root>
# Prints 'allowed', 'disabled', or 'unconfigured' when the file or the setting
# is absent. Returns 1, with the reason on standard error, for a malformed
# file or an unknown value: a preference that cannot be read is never guessed.
# ATTRIBUTION_CONFIG_FILE selects another file, for a test of the scripts.
attribution_preference() {
  local config="${ATTRIBUTION_CONFIG_FILE:-$1/$ATTRIBUTION_CONFIG}"
  local comment_pattern='^[[:space:]]*(#.*)?$'
  local entry_pattern="^$ATTRIBUTION_SETTING:[[:space:]]*([^[:space:]]+)[[:space:]]*\$"
  local line
  local line_number=0
  local value=""

  if [[ ! -f "$config" ]]; then
    echo "unconfigured"
    return 0
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    [[ "$line" =~ $comment_pattern ]] && continue
    [[ "$line" =~ $entry_pattern ]] ||
      { attribution_fail "malformed line $line_number of $config; expected '$ATTRIBUTION_SETTING: allowed' or '$ATTRIBUTION_SETTING: disabled'."; return 1; }
    [[ -z "$value" ]] ||
      { attribution_fail "'$ATTRIBUTION_SETTING' is set more than once in $config."; return 1; }
    value="${BASH_REMATCH[1]}"
    case "$value" in
      allowed | disabled) ;;
      *)
        attribution_fail "unknown value '$value' on line $line_number of $config; use '$ATTRIBUTION_SETTING: allowed' or '$ATTRIBUTION_SETTING: disabled'."
        return 1
        ;;
    esac
  done <"$config"
  echo "${value:-unconfigured}"
}

# The identities under which coding agents name themselves as co-authors,
# matched without regard to case against the value of a Co-authored-by
# trailer, 'Name <address>'. Only the address, or a GitHub App's '[bot]',
# decides: a person who shares a first name with a product is not an agent,
# and is never rejected.
ATTRIBUTION_AGENT_IDENTITIES=(
  # Claude Code: 'Claude <model> <noreply@anthropic.com>'
  '<noreply@anthropic\.com>'
  # Cursor: 'Cursor <cursoragent@cursor.com>'
  '@cursor\.com>'
  # Codex: 'Codex <noreply@openai.com>'
  '<noreply@openai\.com>'
  # GitHub Copilot in an editor: 'Copilot <copilot@github.com>'
  '<copilot@github\.com>'
  # The Copilot coding agent: '<id>+Copilot@users.noreply.github.com'
  'copilot[^@<>[:space:]]*@users\.noreply\.github\.com>'
  # A GitHub App, such as Devin or Codex on GitHub
  '\[bot\]'
)

# The text with which a client marks what an agent generated, in a pull
# request description or a commit message: Claude Code's 'Generated with'
# line and its address, Cursor's 'Made with Cursor', and the session trailers
# of Claude Code and of the Copilot coding agent.
ATTRIBUTION_GENERATED_TEXT=(
  'Generated (with|by|using) .*(Claude|Codex|Cursor|Copilot|Gemini|Devin|Aider|ChatGPT|OpenAI|Anthropic)'
  'claude\.com/claude-code'
  'Made with Cursor'
  '^[[:space:]]*Claude-Session:'
  '^[[:space:]]*Agent-Logs-Url:'
)

# attribution_matching_lines <pattern>...
# Reads a text on standard input and prints each line that matches one of the
# patterns, without regard to case.
attribution_matching_lines() {
  local line
  local pattern
  local nocasematch

  nocasematch="$(shopt -p nocasematch || true)"
  shopt -s nocasematch
  while IFS= read -r line || [[ -n "$line" ]]; do
    for pattern in "$@"; do
      if [[ "$line" =~ $pattern ]]; then
        printf '%s\n' "$line"
        break
      fi
    done
  done
  eval "$nocasematch"
}

# attribution_agent_trailers
# Reads a commit message on standard input and prints each Co-authored-by
# trailer that names an agent, as 'Co-authored-by: Name <address>'. A trailer
# that names a person is not printed.
attribution_agent_trailers() {
  local trailer_pattern='^[[:space:]]*Co-authored-by:[[:space:]]*(.*[^[:space:]])[[:space:]]*$'
  local line
  local nocasematch

  nocasematch="$(shopt -p nocasematch || true)"
  shopt -s nocasematch
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ $trailer_pattern ]] || continue
    printf 'Co-authored-by: %s\n' "${BASH_REMATCH[1]}" |
      attribution_matching_lines "${ATTRIBUTION_AGENT_IDENTITIES[@]}"
  done
  eval "$nocasematch"
}

# attribution_generated_lines
# Reads a text on standard input and prints each line that carries generated
# attribution text.
attribution_generated_lines() {
  attribution_matching_lines "${ATTRIBUTION_GENERATED_TEXT[@]}"
}

# attribution_commit_trailers <root> <rev-list arguments>...
# For every commit that 'git rev-list' selects, prints one line per agent
# trailer of its message: '<short hash>\t<subject>\t<trailer>'. Prints nothing
# when no commit names an agent.
attribution_commit_trailers() {
  local root="$1"
  local commit
  local trailer
  shift

  while IFS= read -r commit; do
    [[ -n "$commit" ]] || continue
    while IFS= read -r trailer; do
      printf '%s\t%s\t%s\n' "$(git -C "$root" rev-parse --short "$commit")" \
        "$(git -C "$root" log -1 --format=%s "$commit")" "$trailer"
    done < <(git -C "$root" log -1 --format=%B "$commit" | attribution_agent_trailers)
  done < <(git -C "$root" rev-list "$@")
}

# attribution_format_commits
# Reads the lines of attribution_commit_trailers and prints them for a
# message: the commit on one line, its trailer indented on the next.
attribution_format_commits() {
  awk -F '\t' '{ printf "  %s %s\n    %s\n", $1, $2, $3 }'
}
