#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/agent.sh"
source "$script_dir/lib/review-data.sh"
source "$script_dir/lib/fingerprint.sh"
source "$script_dir/lib/review-run.sh"

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
schema_file="$root/.agents/schemas/review.schema.json"

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
[[ -f "$schema_file" ]] || fail "review schema not found: $schema_file"
review_data_require_jq

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

head_before="$(git -C "$root" rev-parse HEAD)"
# The fingerprint of the reviewed content, including uncommitted and untracked
# files; the diff below is built from the same snapshot.
tree_before="$(fingerprint_worktree "$root" "$tmp_work")" ||
  fail "could not compute the fingerprint of the working tree."
cp "$tmp_work/fingerprint.index" "$tmp_work/index.before"

review_paths=(. ":(exclude).agents/reviews" ":(exclude).agents/triage")
context_file="$tmp_work/context.md"
report_file="$tmp_work/result.json"

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
  candidate="$reviews_dir/${slug}-review-$(printf "%02d" "$review_number")"
  if [[ ! -e "$candidate.json" && ! -e "$candidate.md" ]]; then
    out="$candidate"
    break
  fi
  # A round without JSON, such as a review from before JSON artifacts, is not
  # an input for the re-review.
  if [[ -f "$candidate.json" ]]; then
    previous_review="$candidate.json"
  fi
  review_number=$((review_number + 1))
done
review_relative=".agents/reviews/$(basename "$out")"

echo "Preparing independent review:"
echo "  Issue:    #$issue"
echo "  Branch:   $branch"
echo "  Base:     $base_ref"
echo "  Agent:    $agent"
echo "  Model:    $model"
echo "  Output:   $review_relative.json"
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

Read the previous review (JSON):
.agents/reviews/$(basename "$previous_review")

Check whether its findings have been resolved, but perform an independent review of the complete current implementation. Do not limit the review to the previous findings."
fi

START_PROMPT+="

You have read-only access. Do not modify, create, or delete any file.
Return the review as JSON that matches the supplied schema. The calling
script validates and stores it."

echo "Starting $agent reviewer ($model) with read-only permissions..."
echo

review_run_reviewer "$agent" "$model" "$root" "$START_PROMPT" "$context_file" "$schema_file" "$report_file" "$tmp_work"

metadata="$(jq -n \
  --argjson issue "$issue" \
  --argjson round "$review_number" \
  --arg branch "$branch" \
  --arg base "$base_ref" \
  --arg merge_base "$merge_base" \
  --arg head "$head_before" \
  --arg tree "$tree_before" \
  --arg agent "$agent" \
  --arg model "$model" \
  --arg created_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  '{
    schema: "review/v1",
    kind: "feature",
    issue: $issue,
    round: $round,
    branch: $branch,
    base: $base,
    merge_base: $merge_base,
    head: $head,
    reviewed_tree: $tree,
    reviewed_paths: null,
    reviewer: {agent: $agent, model: $model},
    created_at: $created_at
  }')"
review_store "$report_file" "$out" "$metadata"
echo "  $review_relative.json  (source of truth)"
echo "  $review_relative.md    (generated report)"
