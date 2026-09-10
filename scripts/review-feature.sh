#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <issue-number> <agent> [base-branch] [model]"
  echo
  echo "Examples:"
  echo "  $0 2 claude"
  echo "  $0 2 codex"
  echo "  $0 2 codex main astra"
  exit 1
fi

issue="$1"
agent="$2"
base="${3:-main}"
model="${4:-}"

root="$(git rev-parse --show-toplevel)"
branch="$(git branch --show-current)"
slug="${branch//\//-}"

reviews_dir="$root/.agents/reviews"
prompt_file="$root/.agents/prompts/reviewer.md"

# Ensure we're reviewing the expected feature branch.
if [[ "$branch" != feature/${issue}-* ]]; then
  echo "Error: current branch does not look like feature/${issue}-*"
  echo "Current branch: $branch"
  exit 1
fi

# Ensure selected reviewer CLI exists.
if ! command -v "$agent" >/dev/null 2>&1; then
  echo "Error: '$agent' command not found."
  exit 1
fi

# Ensure reviewer contract exists.
if [[ ! -f "$prompt_file" ]]; then
  echo "Error: reviewer prompt not found:"
  echo "  $prompt_file"
  exit 1
fi

mkdir -p "$reviews_dir"

# Determine next review number.
review_number=1
previous_review=""

while true; do
  review_suffix="$(printf "%02d" "$review_number")"
  candidate="$reviews_dir/${slug}-review-${review_suffix}.md"

  if [[ ! -e "$candidate" ]]; then
    out="$candidate"
    break
  fi

  previous_review="$candidate"
  review_number=$((review_number + 1))
done

echo "Preparing independent review:"
echo "  Issue:    #$issue"
echo "  Branch:   $branch"
echo "  Base:     $base"
echo "  Agent:    $agent"

if [[ -n "$model" ]]; then
  echo "  Model:    $model"
else
  echo "  Model:    default"
fi

echo "  Output:   $out"

if [[ -n "$previous_review" ]]; then
  echo "  Previous: $previous_review"
fi

echo

# Prepare review artifact.
cat > "$out" <<EOT
# Independent Review — $branch

Issue: #$issue

Base: $base

HEAD at review start: $(git rev-parse HEAD)

Working tree changes included: yes

Reviewer: $agent

## Critical

## Major

## Minor

## Suggestions

## Verdict

PENDING
EOT

review_relative=".agents/reviews/$(basename "$out")"

START_PROMPT="Read and follow .agents/prompts/reviewer.md.

Your assigned work item is GitHub Issue #${issue}.

Base branch: ${base}.

Read GitHub Issue #${issue} using the GitHub CLI.

Read the matching .agents/plans/${issue}-*.md if one exists.

Review the complete current implementation, including uncommitted working-tree changes.

Write the final review to:
${review_relative}"

if [[ -n "$previous_review" ]]; then
  previous_relative=".agents/reviews/$(basename "$previous_review")"

  START_PROMPT+="

This is a re-review.

Read the previous review:
${previous_relative}

Check whether its findings have been resolved, but perform an independent review of the complete current implementation. Do not limit the review to the previous findings."
fi

START_PROMPT+="

Do not modify implementation files.
Do not commit, push, merge, or deploy."

echo "Starting $agent reviewer..."
echo

case "$agent" in
  codex)
    codex_args=(
      --sandbox workspace-write
      --ask-for-approval never
    )

    if [[ -n "$model" ]]; then
      codex_args+=(--model "$model")
    fi

    (
      cd "$root"
      codex "${codex_args[@]}" "$START_PROMPT"
    )
    ;;

  claude)
    (
      cd "$root"
      claude "$START_PROMPT"
    )
    ;;

  *)
    echo "Error: unsupported agent '$agent'"
    echo "Supported agents: codex, claude"
    exit 1
    ;;
esac

echo
echo "Review completed:"
echo "  $review_relative"
