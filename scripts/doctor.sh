#!/usr/bin/env bash

set -euo pipefail

# Read-only check of the local prerequisites for the template workflow.

failed=0

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

echo "== Agentic template doctor =="

if have git; then
  ok "git is installed"
else
  missing "git is not installed" "Install Git: https://git-scm.com/downloads"
fi

if have jq; then
  ok "jq is installed"
else
  missing "jq is not installed" "Install jq: 'brew install jq' or 'sudo apt-get install jq'"
fi

if have gh; then
  ok "GitHub CLI (gh) is installed"
  if gh auth status >/dev/null 2>&1; then
    ok "GitHub CLI is authenticated"
  else
    missing "GitHub CLI is not authenticated" "Run: gh auth login"
  fi
else
  missing "GitHub CLI (gh) is not installed" "Install it: https://cli.github.com"
fi

agents_found=0
for agent in codex claude; do
  if have "$agent"; then
    ok "$agent CLI is installed"
    agents_found=$((agents_found + 1))
  else
    warn "$agent CLI is not installed" "Install it before selecting '$agent' in a workflow script."
  fi
done
if [[ "$agents_found" -eq 0 ]]; then
  missing "no agent CLI is installed" "Install at least one of: codex, claude"
fi

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
