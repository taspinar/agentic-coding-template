#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 2 ]]; then echo "Usage: $0 <issue-number> <slug> [base-branch]"; exit 1; fi
issue="$1"; slug="$2"; base="${3:-main}"
branch="feature/${issue}-${slug}"
repo_root="$(git rev-parse --show-toplevel)"
repo_name="$(basename "$repo_root")"
worktree="$(dirname "$repo_root")/${repo_name}-${issue}-${slug}"
if ! ls "$repo_root/.agents/plans/${issue}-"*.md >/dev/null 2>&1; then
  echo "Warning: no .agents/plans/${issue}-*.md found. Create a plan first for non-trivial work."
fi
git fetch origin "$base" 2>/dev/null || true
git worktree add "$worktree" -b "$branch" "$base"
echo "Created $branch at $worktree"
echo "Start the implementer agent inside that directory and follow .agents/prompts/implementer.md"
