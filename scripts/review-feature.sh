#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/agent.sh"

fail() {
  echo "Error: $*" >&2
  exit 1
}

agent_parse_args "$@"
if [[ "${#AGENT_POSITIONAL[@]}" -lt 1 || "${#AGENT_POSITIONAL[@]}" -gt 2 ]]; then
  echo "Usage: $0 <issue-number> [base-branch] [--agent <agent>] [--model <model>]"
  echo
  echo "The agent and model come from role 'reviewer' in .agents/agents.conf"
  echo "unless --agent and --model are given."
  echo
  echo "Examples:"
  echo "  $0 2"
  echo "  $0 2 develop"
  echo "  $0 2 --agent codex --model gpt-6-astra"
  exit 1
fi

issue="${AGENT_POSITIONAL[0]}"
base="${AGENT_POSITIONAL[1]:-main}"

[[ "$issue" =~ ^[0-9]+$ ]] || fail "issue number must be numeric: $issue"

root="$(git rev-parse --show-toplevel)"
branch="$(git branch --show-current)"
slug="${branch//\//-}"

reviews_dir="$root/.agents/reviews"
prompt_file="$root/.agents/prompts/reviewer.md"

# Ensure we're reviewing the expected feature branch.
if [[ "$branch" != feature/${issue}-* ]]; then
  echo "Error: current branch does not look like feature/${issue}-*" >&2
  echo "Current branch: $branch" >&2
  exit 1
fi

agent_resolve "$root" reviewer "$AGENT_CLI_PROVIDER" "$AGENT_CLI_MODEL"
agent="$AGENT_PROVIDER"
model="$AGENT_MODEL"

[[ -f "$prompt_file" ]] || fail "reviewer prompt not found: $prompt_file"

command -v gh >/dev/null 2>&1 || fail "GitHub CLI 'gh' is not installed."
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated. Run: gh auth login"

if git -C "$root" rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
  base_ref="$base"
elif git -C "$root" rev-parse --verify --quiet "origin/$base^{commit}" >/dev/null; then
  base_ref="origin/$base"
else
  fail "base branch not found locally or on origin: $base"
fi
merge_base="$(git -C "$root" merge-base HEAD "$base_ref")" ||
  fail "could not determine the merge base of HEAD and $base_ref."

tmp_work="$(mktemp -d "${TMPDIR:-/tmp}/review-feature.XXXXXX")"
trap 'rm -rf "$tmp_work"' EXIT

# The reviewer is read-only and has no network access, so the script supplies
# the Issue and the complete diff.
issue_context="$(gh issue view "$issue" \
  --json title,body \
  --template 'Title: {{.title}}{{"\n\n"}}{{.body}}')" ||
  fail "could not read GitHub Issue #$issue."

# Tree of the complete working tree, including uncommitted and untracked
# files, built in a temporary index so the real index is not touched.
snapshot_tree() {
  local index="$tmp_work/index.$1"
  local real_index

  # Start from the real index so tracked files that match an ignore rule stay
  # in the snapshot. The path may be relative to the repository root.
  real_index="$(cd "$root" && git rev-parse --git-path index)"
  if (cd "$root" && [[ -f "$real_index" ]]); then
    (cd "$root" && cp "$real_index" "$index") ||
      fail "could not copy the Git index for the review snapshot."
  fi
  GIT_INDEX_FILE="$index" git -C "$root" add -A >/dev/null
  GIT_INDEX_FILE="$index" git -C "$root" write-tree
}

head_before="$(git -C "$root" rev-parse HEAD)"
tree_before="$(snapshot_tree before)"

review_paths=(. ":(exclude).agents/reviews" ":(exclude).agents/triage")
context_file="$tmp_work/context.md"
report_file="$tmp_work/report.md"

if GIT_INDEX_FILE="$tmp_work/index.before" git -C "$root" diff --cached --quiet "$merge_base" -- "${review_paths[@]}"; then
  fail "no changes to review between $base_ref and the working tree."
fi

{
  echo "# Review context for Issue #$issue"
  echo
  echo "## GitHub Issue #$issue"
  echo
  printf '%s\n' "$issue_context"
  echo
  echo "## Changed files"
  echo
  GIT_INDEX_FILE="$tmp_work/index.before" git -C "$root" diff --cached --stat --no-color "$merge_base" -- "${review_paths[@]}"
  echo
  echo "## Complete diff against $base_ref, including uncommitted and untracked changes"
  echo
  GIT_INDEX_FILE="$tmp_work/index.before" git -C "$root" diff --cached --no-color "$merge_base" -- "${review_paths[@]}"
} >"$context_file"

# Determine next review number.
review_number=1
previous_review=""
while true; do
  candidate="$reviews_dir/${slug}-review-$(printf "%02d" "$review_number").md"
  if [[ ! -e "$candidate" ]]; then
    out="$candidate"
    break
  fi
  previous_review="$candidate"
  review_number=$((review_number + 1))
done
review_relative=".agents/reviews/$(basename "$out")"

echo "Preparing independent review:"
echo "  Issue:    #$issue"
echo "  Branch:   $branch"
echo "  Base:     $base_ref"
echo "  Agent:    $agent"
echo "  Model:    $model"
echo "  Output:   $review_relative"
if [[ -n "$previous_review" ]]; then
  echo "  Previous: .agents/reviews/$(basename "$previous_review")"
fi
echo

START_PROMPT="Read and follow .agents/prompts/reviewer.md.

Your assigned work item is GitHub Issue #${issue}.

Standard input contains the Issue title and body, the list of changed files,
and the complete diff of the current implementation against ${base_ref},
including uncommitted and untracked changes. Review that complete diff. Read
the files in the repository for surrounding context.

Read the matching .agents/plans/${issue}-*.md if one exists."

if [[ -n "$previous_review" ]]; then
  START_PROMPT+="

This is a re-review.

Read the previous review:
.agents/reviews/$(basename "$previous_review")

Check whether its findings have been resolved, but perform an independent review of the complete current implementation. Do not limit the review to the previous findings."
fi

START_PROMPT+="

You have read-only access. Do not modify, create, or delete any file.
Return the complete review as your final message, starting with the
'## Critical' section. The calling script stores it."

echo "Starting $agent reviewer ($model) with read-only permissions..."
echo

set +e
agent_run read-only "$agent" "$model" "$root" "$START_PROMPT" "$report_file" "$context_file"
agent_status=$?
set -e

if [[ "$(git -C "$root" rev-parse HEAD)" != "$head_before" || "$(snapshot_tree after)" != "$tree_before" ]]; then
  echo "Error: the reviewer modified the working tree or created a commit. No review was stored." >&2
  git -C "$root" status --short >&2
  exit 1
fi

[[ "$agent_status" -eq 0 ]] ||
  fail "reviewer failed with status $agent_status. No review was stored."

# Keep the report from its first section heading and require a usable verdict.
report_body="$(awk '/^## / { found = 1 } found { print }' "$report_file" 2>/dev/null || true)"
verdict="$(printf '%s\n' "$report_body" | awk '
  /^## Verdict[[:space:]]*$/ { in_verdict = 1; next }
  in_verdict && /^## / { exit }
  in_verdict && $0 !~ /^[[:space:]]*$/ {
    gsub(/[*`]/, "")
    sub(/^[[:space:]]+/, "")
    sub(/[[:space:]]+$/, "")
    print
    exit
  }
')"

for section in "## Critical" "## Major" "## Minor" "## Suggestions" "## Verdict"; do
  if ! grep -Eq "^${section}[[:space:]]*$" <<<"$report_body"; then
    echo "Error: the reviewer's report has no '$section' section. No review was stored." >&2
    echo "Returned output:" >&2
    cat "$report_file" >&2 2>/dev/null || true
    exit 1
  fi
done

case "$verdict" in
  PASS | "PASS WITH MINOR FINDINGS" | "CHANGES REQUIRED") ;;
  *)
    fail "the reviewer's verdict is missing or invalid: '${verdict}'. No review was stored."
    ;;
esac

mkdir -p "$reviews_dir"
{
  echo "# Independent Review — $branch"
  echo
  echo "Issue: #$issue"
  echo
  echo "Base: $base_ref ($merge_base)"
  echo
  echo "HEAD at review start: $head_before"
  echo
  echo "Working tree changes included: yes"
  echo
  echo "Reviewed tree: $tree_before"
  echo
  echo "Reviewer: $agent ($model), read-only"
  echo
  printf '%s\n' "$report_body"
} >"$out"

echo "Review completed: $verdict"
echo "  $review_relative"
