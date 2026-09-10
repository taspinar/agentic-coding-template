#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <issue-number> <slug> <agent> [base-branch] [model]"
  echo
  echo "Examples:"
  echo "  $0 1 project-scaffold codex"
  echo "  $0 3 floorplan claude"
  echo "  $0 4 multiplayer codex main gpt-5.6"
  exit 1
fi

issue="$1"
slug="$2"
agent="$3"
base="${4:-main}"
model="${5:-}"

branch="feature/${issue}-${slug}"

repo_root="$(git rev-parse --show-toplevel)"
repo_name="$(basename "$repo_root")"
worktree="$(dirname "$repo_root")/${repo_name}-${issue}-${slug}"

echo "Preparing feature:"
echo "  Issue:    #$issue"
echo "  Branch:   $branch"
echo "  Worktree: $worktree"
echo "  Agent:    $agent"

if [[ -n "$model" ]]; then
  echo "  Model:    $model"
else
  echo "  Model:    default"
fi
echo

# Ensure current working tree is clean.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Error: current working tree is not clean."
  echo "Commit or stash changes before starting a feature."
  exit 1
fi

# Ensure the selected agent CLI exists.
if ! command -v "$agent" >/dev/null 2>&1; then
  echo "Error: '$agent' command not found."
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

echo "Starting $agent..."
echo

case "$agent" in
  codex)
    (
      cd "$worktree"

      codex_args=(
        --sandbox workspace-write
        --ask-for-approval never
      )

      if [[ -n "$model" ]]; then
        codex_args+=(--model "$model")
      fi

      codex "${codex_args[@]}" "$START_PROMPT"
    )
    ;;

  claude)
    (
      cd "$worktree"
      claude "$START_PROMPT"
    )
    ;;

  *)
    echo "Error: unsupported agent '$agent'"
    echo "Supported agents: codex, claude"
    exit 1
    ;;
esac
