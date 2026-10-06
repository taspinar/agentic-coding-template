#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/agent.sh"
source "$script_dir/lib/review-data.sh"
source "$script_dir/lib/fingerprint.sh"
source "$script_dir/lib/review-run.sh"
source "$script_dir/lib/scope.sh"

usage() {
  echo "Usage: $0 --review <planning-review-json> [--agent <agent>] [--model <model>]"
  echo
  echo "Run in the planning worktree. The project planner (role 'project-planner')"
  echo "first decides per finding, then, after your approval, revises the planning"
  echo "documents for the adopted findings."
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

agent_parse_args "$@"
review_input=""
set -- ${AGENT_POSITIONAL[@]+"${AGENT_POSITIONAL[@]}"}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --review)
      [[ $# -ge 2 && -n "$2" ]] || fail "--review requires a planning review file."
      review_input="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done
[[ -n "$review_input" ]] || usage

root="$(git rev-parse --show-toplevel)"
branch="$(git branch --show-current)"
[[ "$branch" == planning/* ]] ||
  fail "revise-planning.sh must run in a planning worktree (branch planning/<name>). Current branch: $branch"

prompt_file="$root/.agents/prompts/planning-reviser.md"
schema_file="$root/.agents/schemas/revision.schema.json"
[[ -f "$prompt_file" ]] || fail "planning revision prompt not found: $prompt_file"
[[ -f "$schema_file" ]] || fail "revision schema not found: $schema_file"
review_data_require_jq

[[ -f "$review_input" ]] || fail "planning review not found: $review_input"
review_path="$(cd "$(dirname "$review_input")" && pwd -P)/$(basename "$review_input")"
[[ "$review_path" == "$root/.agents/reviews/"*.json && "$review_path" != *-revision.json ]] ||
  fail "the review must match .agents/reviews/*.json. Received: $review_path"
review_relative="${review_path#"$root"/}"

review_errors="$(review_artifact_errors "$review_path")"
if [[ -n "$review_errors" ]]; then
  echo "Error: invalid planning review:" >&2
  printf '%s\n' "$review_errors" | sed 's/^/  - /' >&2
  exit 1
fi
[[ "$(jq -r '.kind // "feature"' "$review_path")" == "planning" ]] ||
  fail "this is a feature review; use triage-review.sh."
[[ "$(jq -r '.branch' "$review_path")" == "$branch" ]] ||
  fail "the review belongs to $(jq -r '.branch' "$review_path"), not to $branch."
grep -Fqx "Status: Approved" "$root/docs/PROJECT_REQUIREMENTS.md" 2>/dev/null ||
  fail "the project requirements are not approved."

agent_resolve "$root" project-planner "$AGENT_CLI_PROVIDER" "$AGENT_CLI_MODEL"
agent="$AGENT_PROVIDER"
model="$AGENT_MODEL"

tmp_work="$(mktemp -d "${TMPDIR:-/tmp}/revise-planning.XXXXXX")"
trap 'rm -rf "$tmp_work"' EXIT

revision="${review_path%.json}-revision"
revision_relative="${revision#"$root"/}"

current=0
review_is_current "$root" "$tmp_work" "$review_path" || current=$?
case "$current" in
  0) ;;
  1)
    if [[ -f "$revision.json" ]]; then
      fail "this review was already revised and the planning has changed since. Run ./scripts/review-planning.sh for the next round."
    fi
    fail "the planning review is stale: a planning document changed after it was written. Run ./scripts/review-planning.sh again."
    ;;
  *)
    fail "could not compute the fingerprint of the planning documents."
    ;;
esac

if [[ "$(jq '.findings | length' "$review_path")" -eq 0 ]]; then
  echo "The planning review has no findings; there is nothing to revise."
  exit 0
fi

render_decisions() {
  jq -r '
    def group($decision; $heading):
      $heading,
      ([.[] | select(.decision == $decision)] as $items
       | if ($items | length) == 0 then "- (none)"
         else ($items[] | "- \(.finding_id) [\(.severity)] \(.title) — \(.rationale)") end),
      "";
    group("ADOPT"; "ADOPT"), group("REJECT"; "REJECT"), group("DEFER"; "DEFER"), group("ESCALATE"; "ESCALATE")
  ' "$1"
}

if [[ -f "$revision.json" ]]; then
  # Decisions were approved earlier for this unchanged review; only the
  # adopted findings remain to be applied.
  revision_errors="$(revision_artifact_errors "$revision.json" "$review_path")"
  if [[ -n "$revision_errors" ]]; then
    echo "Error: invalid revision artifact $revision_relative.json:" >&2
    printf '%s\n' "$revision_errors" | sed 's/^/  - /' >&2
    exit 1
  fi
  echo "Using the approved decisions in $revision_relative.json."
else
  context_file="$tmp_work/context.md"
  decisions_file="$tmp_work/decisions.json"
  {
    echo "# Planning review to decide on"
    echo
    echo "Source: $review_relative (round $(jq -r '.round' "$review_path"))"
    echo
    jq '{verdict, limitations, findings}' "$review_path"
  } >"$context_file"

  decide_prompt="Read and follow .agents/prompts/planning-reviser.md, phase 1 (decide).

Standard input contains the findings of the planning review ${review_relative}.
Decide exactly once per finding and return JSON that matches the supplied
schema. You have read-only access; do not modify any file."

  validate_decisions() {
    revision_decision_errors "$1" "$review_path"
  }

  echo "Starting $agent planner ($model) to decide per finding, read-only..."
  echo
  review_run_reviewer "$agent" "$model" "$root" "$decide_prompt" "$context_file" "$schema_file" \
    "$decisions_file" "$tmp_work" validate_decisions

  jq -n --slurpfile review "$review_path" --slurpfile result "$decisions_file" '
    ($result[0].decisions | map({key: .finding_id, value: .}) | from_entries) as $decision
    | [$review[0].findings[] | {
        finding_id: .id,
        severity: .severity,
        title: .title,
        decision: $decision[.id].decision,
        rationale: $decision[.id].rationale
      }]
  ' >"$tmp_work/proposal.json"

  echo
  echo "Proposed revision decisions:"
  echo
  render_decisions "$tmp_work/proposal.json"
  printf "Record these decisions and revise the planning for the adopted findings? [y/N] "
  approval=""
  read -r approval || true
  case "$approval" in
    y | Y | yes | YES) ;;
    *)
      echo "Declined; no decisions were recorded and no document was changed."
      exit 0
      ;;
  esac

  jq -n \
    --slurpfile review "$review_path" \
    --slurpfile decisions "$tmp_work/proposal.json" \
    --arg source_review "$review_relative" \
    --arg agent "$agent" \
    --arg model "$model" \
    --arg approved_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" '
    {
      schema: "revision/v1",
      source_review: $source_review,
      branch: $review[0].branch,
      review_round: $review[0].round,
      reviewed_tree: $review[0].reviewed_tree,
      planner: {agent: $agent, model: $model},
      approved_at: $approved_at,
      decisions: $decisions[0]
    }' >"$tmp_work/revision.json"

  revision_errors="$(revision_artifact_errors "$tmp_work/revision.json" "$review_path")"
  if [[ -n "$revision_errors" ]]; then
    echo "Error: the revision would be invalid; nothing was recorded:" >&2
    printf '%s\n' "$revision_errors" | sed 's/^/  - /' >&2
    exit 1
  fi
  cp "$tmp_work/revision.json" "$revision.json"
  revision_render_markdown "$revision.json" "$(basename "$revision").json" >"$revision.md"
  echo
  echo "Recorded the decisions:"
  echo "  $revision_relative.json  (source of truth)"
  echo "  $revision_relative.md    (generated report)"
fi

escalated="$(jq -r '.decisions[] | select(.decision == "ESCALATE") | "- \(.finding_id) \(.title)"' "$revision.json")"
if [[ -n "$escalated" ]]; then
  echo
  echo "Escalated findings need your decision:"
  printf '%s\n' "$escalated"
  echo "Resolve each by changing the requirements through Project Grill and approving"
  echo "them again, or by deciding that the finding does not apply. The planning"
  echo "cannot be finished while an escalated finding is unresolved."
fi

adopted="$(jq -r --slurpfile review "$review_path" '
  .decisions[] | select(.decision == "ADOPT") | . as $d
  | ($review[0].findings[] | select(.id == $d.finding_id)) as $f
  | "### \($f.id). \($f.title)\n\n- Severity: \($f.severity)\n- Evidence: \($f.evidence)\n- Impact: \($f.impact)\n- Recommended action: \($f.recommendation)\n- Your rationale: \($d.rationale)\n"
' "$revision.json")"
if [[ -z "$adopted" ]]; then
  echo
  echo "No finding was adopted; no planning document is changed."
  echo "Next: ./scripts/finish-planning.sh, once no escalated finding remains."
  exit 0
fi

# Phase 2: the planner may change only the architecture, the roadmap, and
# direct Markdown ADRs. Everything else, including the requirements, the
# description, and all review artifacts, must stay unchanged.
baseline="$tmp_work/scope-before.tsv"
scope_snapshot "$root" scope_planner_allowed "$baseline"
head_before="$(git -C "$root" rev-parse HEAD)"

revise_prompt="Read and follow .agents/prompts/planning-reviser.md, phase 2 (revise).

The human approved your decisions in ${revision_relative}.json. Resolve exactly
these adopted findings of ${review_relative}:

${adopted}
Change only docs/architecture.md, docs/roadmap.md, and direct Markdown ADRs
under docs/decisions/. Do not commit, push, open or merge a pull request,
create GitHub Issues, or deploy."

echo
echo "Starting $agent planner ($model) to revise the adopted findings..."
echo
agent_status=0
agent_run write "$agent" "$model" "$root" "$revise_prompt" || agent_status=$?

preserved() {
  echo "Error: $1" >&2
  echo "The planning worktree is preserved; inspect it with: git -C \"$root\" status --short" >&2
  exit "${2:-1}"
}

[[ "$(git -C "$root" rev-parse HEAD)" == "$head_before" ]] ||
  preserved "the planner created a commit; planning agents must leave HEAD unchanged."
scope_snapshot "$root" scope_planner_allowed "$tmp_work/scope-after.tsv"
scope_unchanged "$baseline" "$tmp_work/scope-after.tsv" ||
  preserved "the planner changed files outside the architecture, the roadmap, and the ADRs."
[[ "$agent_status" -eq 0 ]] || preserved "the planner failed with status $agent_status." "$agent_status"

for document in docs/architecture.md docs/roadmap.md; do
  [[ -f "$root/$document" && ! -L "$root/$document" && -s "$root/$document" ]] ||
    preserved "$document must remain a non-empty regular file."
  [[ ! "$(scope_file_mode "$root/$document")" =~ [1357] ]] ||
    preserved "$document must not be executable."
done
if [[ -e "$root/docs/decisions" || -L "$root/docs/decisions" ]]; then
  [[ -d "$root/docs/decisions" && ! -L "$root/docs/decisions" ]] ||
    preserved "docs/decisions must be a regular directory."
  while IFS= read -r -d '' decision; do
    name="${decision#"$root/docs/decisions/"}"
    [[ "$name" == *.md && -f "$decision" && ! -L "$decision" ]] ||
      preserved "decision records must be regular Markdown files: docs/decisions/$name"
  done < <(find "$root/docs/decisions" -mindepth 1 -maxdepth 1 -print0)
fi

# Adopted findings must lead to a change of the planning documents.
after_revision="$(fingerprint_review "$root" "$tmp_work" "$review_path")" ||
  preserved "could not compute the fingerprint of the planning documents."
[[ "$after_revision" != "$(jq -r '.reviewed_tree' "$review_path")" ]] ||
  preserved "the planner changed no planning document for the adopted findings. The approved decisions are kept; run this script again to apply them."

echo
echo "The adopted findings were revised. The planning review is now stale by design."
echo "Next: run ./scripts/review-planning.sh for the next review round."
