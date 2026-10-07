#!/usr/bin/env bash

set -euo pipefail

# Read-only check of the local prerequisites for the template workflow.
# Uses only Bash builtins besides the tools it checks.

script_dir="${BASH_SOURCE[0]%/*}"
[[ "$script_dir" != "${BASH_SOURCE[0]}" ]] || script_dir="."
root="$script_dir/.."
source "$script_dir/lib/agent.sh"

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

have() {
  command -v "$1" >/dev/null 2>&1
}

# check_main_protection
# Warns when a pull request into 'main' can be merged without a passing status
# check. Rulesets are read first, then classic branch protection.
check_main_protection() {
  local count

  [[ "$gh_ready" -eq 1 ]] || return 0
  count="$(gh api "repos/{owner}/{repo}/rules/branches/main" \
    --jq '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]] | length' 2>/dev/null)" ||
    count=""
  if [[ "$count" == "0" ]]; then
    count="$(gh api "repos/{owner}/{repo}/branches/main" \
      --jq '[(.protection.required_status_checks.contexts // [])[], (.protection.required_status_checks.checks // [])[]] | length' 2>/dev/null)" ||
      count=""
  fi

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

# Providers that .agents/agents.conf assigns to a role are required.
codex_roles=""
claude_roles=""
if config_error="$( (agent_lookup "$root" implementer) 2>&1)"; then
  if [[ -f "${AGENT_CONFIG_FILE:-$root/.agents/agents.conf}" ]]; then
    ok "agent configuration is valid"
    for role in $AGENT_ROLES; do
      agent_lookup "$root" "$role"
      case "$AGENT_CONFIG_PROVIDER" in
        codex) codex_roles+=" $role" ;;
        claude) claude_roles+=" $role" ;;
        "") ;;
        *)
          missing "role '$role' uses unsupported agent '$AGENT_CONFIG_PROVIDER'" \
            "Use 'codex' or 'claude' in .agents/agents.conf."
          ;;
      esac
    done
  else
    warn "agent configuration .agents/agents.conf was not found" \
      "Every workflow script then needs --agent and --model."
  fi
else
  missing "agent configuration is invalid" "${config_error#Error: }"
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
