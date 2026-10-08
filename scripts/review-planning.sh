#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/agent.sh"
source "$script_dir/lib/review-data.sh"
source "$script_dir/lib/fingerprint.sh"
source "$script_dir/lib/review-run.sh"
source "$script_dir/lib/planning.sh"

fail() {
  echo "Error: $*" >&2
  exit 1
}

agent_parse_args "$@"
agent_reject_unattended
if [[ "${#AGENT_POSITIONAL[@]}" -ne 0 ]]; then
  echo "Usage: $0 [--agent <agent>] [--model <model>]"
  echo
  echo "Run in a planning worktree (branch planning/<name>). The agent and model come"
  echo "from role 'planning-reviewer' in .agents/agents.conf unless --agent and"
  echo "--model are given."
  exit 1
fi

root="$(git rev-parse --show-toplevel)"
branch="$(git branch --show-current)"
[[ "$branch" == planning/* ]] ||
  fail "review-planning.sh must run in a planning worktree (branch planning/<name>). Current branch: $branch"
name="${branch#planning/}"

prompt_file="$root/.agents/prompts/planning-reviewer.md"
schema_file="$root/.agents/schemas/review.schema.json"
reviews_dir="$root/.agents/reviews"
[[ -f "$prompt_file" ]] || fail "planning reviewer prompt not found: $prompt_file"
[[ -f "$schema_file" ]] || fail "review schema not found: $schema_file"
review_data_require_jq

for required in docs/PROJECT_REQUIREMENTS.md docs/architecture.md docs/roadmap.md; do
  [[ -f "$root/$required" && ! -L "$root/$required" ]] || fail "required planning document is missing: $required"
done
grep -Fqx "Status: Approved" "$root/docs/PROJECT_REQUIREMENTS.md" ||
  fail "the project requirements are not approved. Finish start-planning.sh first."

agent_resolve "$root" planning-reviewer "$AGENT_CLI_PROVIDER" "$AGENT_CLI_MODEL"
agent="$AGENT_PROVIDER"
model="$AGENT_MODEL"

# The reviewed scope: the planning documents, and nothing else.
scope=("${PLANNING_SCOPE[@]}")

# The documents whose contents the reviewer receives.
paths=()
[[ ! -f "$root/docs/PROJECT_DESCRIPTION.md" ]] || paths+=(docs/PROJECT_DESCRIPTION.md)
# A change cycle has a change request named after its branch.
change_request="docs/changes/$name.md"
[[ -f "$root/$change_request" ]] || change_request=""
[[ -z "$change_request" ]] || paths+=("$change_request")
paths+=(docs/PROJECT_REQUIREMENTS.md docs/architecture.md docs/roadmap.md)
while IFS= read -r decision; do
  paths+=("docs/decisions/$decision")
done < <(cd "$root" && find docs/decisions -mindepth 1 -maxdepth 1 -name '*.md' -type f 2>/dev/null |
  sed 's#^docs/decisions/##' | LC_ALL=C sort)

if git -C "$root" rev-parse --verify --quiet "origin/main^{commit}" >/dev/null; then
  base_ref="origin/main"
elif git -C "$root" rev-parse --verify --quiet "main^{commit}" >/dev/null; then
  base_ref="main"
else
  fail "neither origin/main nor main exists."
fi
merge_base="$(git -C "$root" merge-base HEAD "$base_ref")"

tmp_work="$(mktemp -d "${TMPDIR:-/tmp}/review-planning.XXXXXX")"
trap 'rm -rf "$tmp_work"' EXIT

tree="$(fingerprint_files "$root" "$tmp_work" "${scope[@]}")" ||
  fail "could not compute the fingerprint of the planning documents."
head_before="$(git -C "$root" rev-parse HEAD)"

context_file="$tmp_work/context.md"
result_file="$tmp_work/result.json"
{
  echo "# Planning review context ($branch)"
  echo
  for path in "${paths[@]}"; do
    echo "## $path"
    echo
    echo '````markdown'
    cat "$root/$path"
    echo '````'
    echo
  done
  echo "## Diff of the planning documents against $base_ref, including uncommitted changes and deletions"
  echo
  GIT_INDEX_FILE="$tmp_work/fingerprint-files.index" git -C "$root" diff --cached --no-color "$merge_base" -- "${scope[@]}"
} >"$context_file"

review_number=1
previous_review=""
while true; do
  candidate="$reviews_dir/planning-${name}-review-$(printf "%02d" "$review_number")"
  if [[ ! -e "$candidate.json" && ! -e "$candidate.md" ]]; then
    out="$candidate"
    break
  fi
  if [[ -f "$candidate.json" ]]; then
    previous_review="$candidate.json"
  fi
  review_number=$((review_number + 1))
done
review_relative=".agents/reviews/$(basename "$out")"

echo "Preparing independent planning review:"
echo "  Branch:   $branch"
echo "  Base:     $base_ref"
echo "  Agent:    $agent"
echo "  Model:    $model"
echo "  Files:    ${paths[*]}"
echo "  Output:   $review_relative.json"
if [[ -n "$previous_review" ]]; then
  echo "  Previous: .agents/reviews/$(basename "$previous_review")"
fi
echo

prompt="Read and follow .agents/prompts/planning-reviewer.md.

Standard input contains the planning documents of $branch and their diff
against ${base_ref}. Review those documents."

if [[ -n "$change_request" ]]; then
  prompt+="

This is a change cycle for a planning that was approved before. The human's
change request is $change_request. Review the change, which is the diff, in
the context of the complete planning, and apply the \"Change cycle\" checks
of your contract."
fi

if [[ -n "$previous_review" ]]; then
  prompt+="

This is a re-review. Read the previous review (JSON):
.agents/reviews/$(basename "$previous_review")
and any revision decisions next to it (*-revision.json). Check whether its
findings have been resolved, but review the complete current planning."
fi

prompt+="

You have read-only access. Do not modify, create, or delete any file.
Return the review as JSON that matches the supplied schema. The calling
script validates and stores it."

echo "Starting $agent planning reviewer ($model) with read-only permissions..."
echo

review_run_reviewer "$agent" "$model" "$root" "$prompt" "$context_file" "$schema_file" "$result_file" "$tmp_work"

paths_json="$(printf '%s\n' "${scope[@]}" | jq -R . | jq -s .)"
metadata="$(jq -n \
  --argjson round "$review_number" \
  --arg branch "$branch" \
  --arg base "$base_ref" \
  --arg merge_base "$merge_base" \
  --arg head "$head_before" \
  --arg tree "$tree" \
  --argjson paths "$paths_json" \
  --arg agent "$agent" \
  --arg model "$model" \
  --arg created_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  '{
    schema: "review/v1",
    kind: "planning",
    issue: null,
    round: $round,
    branch: $branch,
    base: $base,
    merge_base: $merge_base,
    head: $head,
    reviewed_tree: $tree,
    reviewed_paths: $paths,
    reviewer: {agent: $agent, model: $model},
    created_at: $created_at
  }')"
review_store "$result_file" "$out" "$metadata"
echo "  $review_relative.json  (source of truth)"
echo "  $review_relative.md    (generated report)"
echo
if [[ "$(jq '.findings | length' "$out.json")" -gt 0 ]]; then
  echo "Next: ./scripts/revise-planning.sh --review $review_relative.json"
else
  echo "Next: ./scripts/finish-planning.sh"
fi
