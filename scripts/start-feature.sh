#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/agent.sh"

agent_parse_args "$@"
if [[ "${#AGENT_POSITIONAL[@]}" -lt 1 || "${#AGENT_POSITIONAL[@]}" -gt 3 ]]; then
  echo "Usage: $0 <issue-number> [slug] [base-branch] [--agent <agent>] [--model <model>]"
  echo
  echo "The slug names the branch (feature/<issue>-<slug>) and the worktree. Without"
  echo "one, it is derived from the Issue title. The agent and model come from role"
  echo "'implementer' in .agents/agents.conf unless --agent and --model are given."
  echo
  echo "Examples:"
  echo "  $0 3"
  echo "  $0 3 site-skeleton"
  echo "  $0 3 site-skeleton develop"
  echo "  $0 4 multiplayer --agent claude --model fable"
  exit 1
fi

issue="${AGENT_POSITIONAL[0]}"
slug="${AGENT_POSITIONAL[1]:-}"
base="${AGENT_POSITIONAL[2]:-main}"

[[ "$issue" =~ ^[0-9]+$ ]] || agent_fail "issue number must be numeric: $issue"

if [[ -z "$slug" ]]; then
  # Derive the slug from the Issue title: without a leading feature ID, in
  # lowercase, as at most four words joined by hyphens.
  command -v gh >/dev/null 2>&1 || agent_fail "GitHub CLI 'gh' is needed to derive the slug; pass a slug instead."
  issue_title="$(gh issue view "$issue" --json title --jq '.title' </dev/null)" ||
    agent_fail "could not read the title of Issue #$issue; pass a slug instead."
  slug="$(printf '%s' "$issue_title" |
    sed -E 's/^[[:space:]]*F[0-9]+[^[:alnum:]]*//' |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9]+/ /g' |
    awk '{ n = (NF < 4 ? NF : 4); for (i = 1; i <= n; i++) printf "%s%s", (i > 1 ? "-" : ""), $i }')"
  [[ -n "$slug" ]] || agent_fail "could not derive a slug from the title of Issue #$issue; pass a slug instead."
fi
[[ "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]] || agent_fail "slug must match [a-z0-9][a-z0-9-]*: $slug"

branch="feature/${issue}-${slug}"

repo_root="$(git rev-parse --show-toplevel)"
repo_name="$(basename "$repo_root")"
worktree="$(dirname "$repo_root")/${repo_name}-${issue}-${slug}"

agent_resolve "$repo_root" implementer "$AGENT_CLI_PROVIDER" "$AGENT_CLI_MODEL"
agent="$AGENT_PROVIDER"
model="$AGENT_MODEL"

# The implementer may run without network access, so the script supplies the
# Issue.
command -v gh >/dev/null 2>&1 || agent_fail "GitHub CLI 'gh' is not installed."
issue_context="$(gh issue view "$issue" \
  --json title,body \
  --template 'Title: {{.title}}{{"\n\n"}}{{.body}}' </dev/null)" ||
  agent_fail "could not read GitHub Issue #$issue."

echo "Preparing feature:"
echo "  Issue:    #$issue"
echo "  Branch:   $branch"
echo "  Worktree: $worktree"
echo "  Agent:    $agent"
echo "  Model:    $model"
echo

# Modified tracked files would not be part of the feature worktree, which is
# created from the remote base. Untracked files do not matter.
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "Error: this checkout has uncommitted changes to tracked files."
  echo "Commit or stash them before starting a feature."
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

Your assigned work item is GitHub Issue #${issue}. Its title and body follow
below, so you do not need the GitHub CLI or network access to read it.

Read the matching .agents/plans/${issue}-*.md if one exists.

Work only on this issue.

Do not commit, push, merge, or deploy.

--- GitHub Issue #${issue} ---
${issue_context}
--- end of Issue #${issue} ---"

echo "Starting $agent ($model)..."
echo

agent_status=0
agent_run write "$agent" "$model" "$worktree" "$START_PROMPT" || agent_status=$?

echo
if [[ "$agent_status" -ne 0 ]]; then
  echo "Error: the implementation agent exited with status $agent_status." >&2
  echo "The feature worktree is preserved at: $worktree" >&2
  exit "$agent_status"
fi
echo "The implementation session ended. Nothing is committed yet."
echo
echo "Next, in the feature worktree:"
echo "  cd \"$worktree\""
echo "  ./scripts/verify.sh"
echo "  ./scripts/review-feature.sh $issue"
