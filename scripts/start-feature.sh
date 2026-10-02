#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/agent.sh"

agent_parse_args "$@"
if [[ "${#AGENT_POSITIONAL[@]}" -lt 2 || "${#AGENT_POSITIONAL[@]}" -gt 3 ]]; then
  echo "Usage: $0 <issue-number> <slug> [base-branch] [--agent <agent>] [--model <model>]"
  echo
  echo "The agent and model come from role 'implementer' in .agents/agents.conf"
  echo "unless --agent and --model are given."
  echo
  echo "Examples:"
  echo "  $0 1 project-scaffold"
  echo "  $0 3 floorplan develop"
  echo "  $0 4 multiplayer --agent claude --model fable"
  exit 1
fi

issue="${AGENT_POSITIONAL[0]}"
slug="${AGENT_POSITIONAL[1]}"
base="${AGENT_POSITIONAL[2]:-main}"

branch="feature/${issue}-${slug}"

repo_root="$(git rev-parse --show-toplevel)"
repo_name="$(basename "$repo_root")"
worktree="$(dirname "$repo_root")/${repo_name}-${issue}-${slug}"

agent_resolve "$repo_root" implementer "$AGENT_CLI_PROVIDER" "$AGENT_CLI_MODEL"
agent="$AGENT_PROVIDER"
model="$AGENT_MODEL"

echo "Preparing feature:"
echo "  Issue:    #$issue"
echo "  Branch:   $branch"
echo "  Worktree: $worktree"
echo "  Agent:    $agent"
echo "  Model:    $model"
echo

# Ensure current working tree is clean.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Error: current working tree is not clean."
  echo "Commit or stash changes before starting a feature."
  exit 1
fi

# Warn if no plan exists.
# This is allowed when the roadmap/issue explicitly says no plan is required.
if ! ls "$repo_root/.agents/plans/${issue}-"*.md >/dev/null 2>&1; then
  echo "Warning: no .agents/plans/${issue}-*.md found."
  echo "This is fine if the issue does not require a separate implementation plan."
  echo
fi

# Refresh base branch reference.
git fetch origin "$base"

# Prevent accidental duplicate branch/worktree creation.
if git show-ref --verify --quiet "refs/heads/$branch"; then
  echo "Error: branch already exists: $branch"
  exit 1
fi

if [[ -e "$worktree" ]]; then
  echo "Error: worktree path already exists: $worktree"
  exit 1
fi

# Create isolated worktree from latest remote base.
git worktree add "$worktree" -b "$branch" "origin/$base"

echo
echo "Created feature worktree:"
echo "  $worktree"
echo

START_PROMPT="Read and follow .agents/prompts/implementer.md.

Your assigned work item is GitHub Issue #${issue}.

Read GitHub Issue #${issue} using the GitHub CLI.

Read the matching .agents/plans/${issue}-*.md if one exists.

Work only on this issue.

Do not push, merge, or deploy unless explicitly instructed."

echo "Starting $agent ($model)..."
echo

agent_run_interactive "$agent" "$model" "$worktree" "$START_PROMPT"
