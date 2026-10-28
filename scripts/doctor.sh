#!/usr/bin/env bash

set -euo pipefail

# Read-only check of the local prerequisites for the template workflow.
# Uses only Bash builtins besides the tools it checks.

script_dir="${BASH_SOURCE[0]%/*}"
[[ "$script_dir" != "${BASH_SOURCE[0]}" ]] || script_dir="."
root="$script_dir/.."
source "$script_dir/lib/agent.sh"
source "$script_dir/lib/github.sh"
source "$script_dir/lib/attribution.sh"

failed=0
gh_ready=0

ok() {
  echo "OK       $1"
}

warn() {
  echo "WARNING  $1"
  echo "         $2"
}

missing() {
  echo "FAILED   $1"
  echo "         $2"
  failed=1
}

# note: a fact to know that nothing here can change.
note() {
  echo "NOTE     $1"
  echo "         $2"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

# check_main_protection
# Warns when a pull request into 'main' can be merged without a passing status
# check. Rulesets are read first, then classic branch protection.
check_main_protection() {
  local count

  [[ "$gh_ready" -eq 1 ]] || return 0
  count="$(github_required_checks main)"

  if [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]]; then
    ok "branch 'main' requires a passing status check before a merge"
  elif [[ "$count" == "0" ]]; then
    warn "branch 'main' accepts a merge while its checks fail" \
      "Add a ruleset for 'main' that requires the CI status check; see docs/repository-setup.md."
  else
    warn "could not read the rules of branch 'main' on GitHub" \
      "Check that 'main' requires the CI status check; see docs/repository-setup.md."
  fi
}

echo "== Agentic template doctor =="

if have git; then
  ok "git is installed"
else
  missing "git is not installed" "Install Git: https://git-scm.com/downloads"
fi

if have jq; then
  # The workflow scripts are written for jq 1.6 and later.
  jq_version="$(jq --version 2>/dev/null || true)"
  if [[ "$jq_version" =~ ^jq-([0-9]+)\.([0-9]+) ]] &&
    ((BASH_REMATCH[1] < 1 || (BASH_REMATCH[1] == 1 && BASH_REMATCH[2] < 6))); then
    missing "jq $jq_version is too old" "Install jq 1.6 or later: 'brew install jq' or 'sudo apt-get install jq'"
  else
    ok "jq is installed"
  fi
else
  missing "jq is not installed" "Install jq: 'brew install jq' or 'sudo apt-get install jq'"
fi

if have gh; then
  ok "GitHub CLI (gh) is installed"
  if gh auth status >/dev/null 2>&1; then
    ok "GitHub CLI is authenticated"
    gh_ready=1
  else
    missing "GitHub CLI is not authenticated" "Run: gh auth login"
  fi
else
  missing "GitHub CLI (gh) is not installed" "Install it: https://cli.github.com"
fi

# Providers that .agents/agents.conf assigns to a role are required, on its
# plain line and on its lines per risk level ('<role>@<level>'), which are
# validated like the plain ones.
codex_roles=""
claude_roles=""
# configured_provider <role> [level]: the provider the role resolves to for
# a feature of the level, by the line of the level or the plain line; nothing
# when neither exists.
configured_provider() {
  agent_lookup "$root" "$1" "${2:-}"
  if [[ -n "${2:-}" && -n "$AGENT_LEVEL_PROVIDER" ]]; then
    printf '%s' "$AGENT_LEVEL_PROVIDER"
  else
    printf '%s' "$AGENT_CONFIG_PROVIDER"
  fi
}
if config_error="$( (agent_lookup "$root" implementer) 2>&1)"; then
  if [[ -f "${AGENT_CONFIG_FILE:-$root/.agents/agents.conf}" ]]; then
    ok "agent configuration is valid"
    for role in $AGENT_ROLES; do
      agent_lookup "$root" "$role"
      role_levels="$AGENT_CONFIG_LEVELS"
      case "$AGENT_CONFIG_PROVIDER" in
        codex) codex_roles+=" $role" ;;
        claude) claude_roles+=" $role" ;;
        "") ;;
        *)
          missing "role '$role' uses unsupported agent '$AGENT_CONFIG_PROVIDER'" \
            "Use 'codex' or 'claude' in .agents/agents.conf."
          ;;
      esac
      for level in $role_levels; do
        agent_lookup "$root" "$role" "$level"
        case "$AGENT_LEVEL_PROVIDER" in
          codex) codex_roles+=" $role@$level" ;;
          claude) claude_roles+=" $role@$level" ;;
          *)
            missing "role '$role@$level' uses unsupported agent '$AGENT_LEVEL_PROVIDER'" \
              "Use 'codex' or 'claude' in .agents/agents.conf."
            ;;
        esac
      done
      if [[ -n "$role_levels" && " $AGENT_FEATURE_ROLES " != *" $role "* ]]; then
        warn "role '$role' has a line per risk level ($role_levels) that never applies" \
          "Only a role of a feature (${AGENT_FEATURE_ROLES// /, }) runs with a risk level; the plain line of '$role' is used."
      fi
    done
    # A reviewing role and the role whose work it reviews should resolve to
    # different providers: for the plain lines, and for every level that
    # either side has a line for.
    for pair in $AGENT_REVIEW_PAIRS; do
      reviewing="${pair%%:*}"
      reviewed="${pair#*:}"
      reviewing_provider="$(configured_provider "$reviewing")"
      reviewed_provider="$(configured_provider "$reviewed")"
      if [[ -n "$reviewing_provider" && "$reviewing_provider" == "$reviewed_provider" ]]; then
        warn "roles '$reviewing' and '$reviewed' use the same agent ($reviewing_provider)" \
          "Use a different provider for a reviewing role than for the role whose work it reviews."
      fi
      for level in $AGENT_LEVELS; do
        agent_lookup "$root" "$reviewing" "$level"
        pair_levels="$AGENT_LEVEL_PROVIDER"
        agent_lookup "$root" "$reviewed" "$level"
        pair_levels+="$AGENT_LEVEL_PROVIDER"
        [[ -n "$pair_levels" ]] || continue
        reviewing_provider="$(configured_provider "$reviewing" "$level")"
        reviewed_provider="$(configured_provider "$reviewed" "$level")"
        if [[ -n "$reviewing_provider" && "$reviewing_provider" == "$reviewed_provider" ]]; then
          warn "roles '$reviewing' and '$reviewed' use the same agent ($reviewing_provider) for a $level-risk feature" \
            "The pair resolved for the level ('<role>@$level', or the plain line) should use different providers."
        fi
      done
    done
  else
    warn "agent configuration .agents/agents.conf was not found" \
      "Every workflow script then needs --agent and --model."
  fi
else
  missing "agent configuration is invalid" "${config_error#Error: }"
fi

# The project's preference on agent attribution, and how far the clients
# can be made to follow it. What a client cannot be configured to do is said
# as such: the check of finish-feature.sh and publish-feature.sh is then the
# only enforcement.
if attribution="$( (attribution_preference "$root") 2>&1)"; then
  case "$attribution" in
    unconfigured)
      warn "agent attribution is not configured" \
        "Select it in $ATTRIBUTION_CONFIG: '$ATTRIBUTION_SETTING: allowed' or '$ATTRIBUTION_SETTING: disabled'. Until then agents attribute their work as their clients do, and nothing is checked."
      ;;
    allowed)
      ok "agent attribution is allowed ($ATTRIBUTION_CONFIG)"
      ;;
    disabled)
      ok "agent attribution is disabled ($ATTRIBUTION_CONFIG): finish-feature.sh and publish-feature.sh refuse a commit or a description that carries it"
      claude_settings="${ATTRIBUTION_CLAUDE_SETTINGS_FILE:-$root/.claude/settings.json}"
      claude_settings_relative=".claude/settings.json"
      claude_settings_hint="Claude sessions that the scripts start get the setting on their command line. For a session you start yourself, add to $claude_settings_relative: {\"attribution\": {\"commit\": \"\", \"pr\": \"\"}}"
      if [[ ! -f "$claude_settings" ]]; then
        warn "Claude Code's attribution is not turned off: $claude_settings_relative does not exist" "$claude_settings_hint"
      elif ! have jq; then
        warn "Claude Code's attribution in $claude_settings_relative could not be checked without jq" "$claude_settings_hint"
      elif jq -e '(.attribution == false) or (.attribution.commit == "" and .attribution.pr == "") or (.includeCoAuthoredBy == false and (.attribution | type) != "object")' "$claude_settings" >/dev/null 2>&1; then
        ok "Claude Code's attribution is turned off in $claude_settings_relative"
      else
        warn "Claude Code's attribution is not turned off in $claude_settings_relative" "$claude_settings_hint"
      fi
      note "codex has no attribution setting, and Cursor's can be set only for the user, not in the project" \
        "For them, AGENTS.md and the check of finish-feature.sh and publish-feature.sh are what applies."
      ;;
  esac
else
  missing "the attribution configuration is invalid" "${attribution#Error: }"
fi

for agent in codex claude; do
  roles="${agent}_roles"
  if have "$agent"; then
    ok "$agent CLI is installed"
  elif [[ -n "${!roles}" ]]; then
    missing "$agent CLI is not installed" "It is configured for:${!roles}. Install it or change .agents/agents.conf."
  else
    warn "$agent CLI is not installed" "Install it before selecting '$agent' in a workflow script."
  fi
done

if have git; then
  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    ok "current directory is inside a Git repository"
    if git remote get-url origin >/dev/null 2>&1; then
      ok "remote 'origin' is configured"
      # Never prompt and never wait indefinitely on an unresponsive remote.
      if GIT_TERMINAL_PROMPT=0 \
        GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes -o ConnectTimeout=10" \
        GIT_HTTP_LOW_SPEED_LIMIT=1 GIT_HTTP_LOW_SPEED_TIME=10 \
        git ls-remote --exit-code --heads origin main >/dev/null 2>&1; then
        ok "branch 'main' is reachable on origin"
        # Reading a public repository works with any identity; pushing does
        # not. A dry run asks the remote for permission without changing it.
        if GIT_TERMINAL_PROMPT=0 \
          GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes -o ConnectTimeout=10" \
          GIT_HTTP_LOW_SPEED_LIMIT=1 GIT_HTTP_LOW_SPEED_TIME=10 \
          git push --dry-run --quiet origin HEAD:refs/heads/doctor-push-check >/dev/null 2>&1; then
          ok "you can push to origin"
          check_main_protection
        else
          missing "you cannot push to origin" \
            "Check that the remote URL uses the GitHub account that owns the repository: git remote get-url origin; ssh -T git@github.com"
        fi
      else
        missing "branch 'main' is not reachable on origin" \
          "Check network access and that origin has a 'main' branch: git ls-remote --heads origin main"
      fi
    else
      missing "remote 'origin' is not configured" "Run: git remote add origin <repository-url>"
    fi
  else
    missing "current directory is not inside a Git repository" "Run this script from the project checkout."
  fi
fi

echo
if [[ "$failed" -ne 0 ]]; then
  echo "Doctor found problems. Fix the FAILED items above and run it again." >&2
  exit 1
fi

echo "All required prerequisites are available."
