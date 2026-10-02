#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/agent.sh"
source "$script_dir/lib/review-data.sh"
source "$script_dir/lib/fingerprint.sh"

usage() {
  echo "Usage: $0 <review-json> [--agent <agent>] [--model <model>]"
  echo
  echo "The agent and model come from role 'triage' in .agents/agents.conf"
  echo "unless --agent and --model are given."
  echo
  echo "Examples:"
  echo "  $0 .agents/reviews/feature-5-rendering-review-01.json"
  echo "  $0 .agents/reviews/feature-5-rendering-review-01.json --agent claude --model fable"
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

agent_parse_args "$@"
if [[ "${#AGENT_POSITIONAL[@]}" -ne 1 ]]; then
  usage
fi

review_input="${AGENT_POSITIONAL[0]}"

root="$(git rev-parse --show-toplevel)"
prompt_file="$root/.agents/prompts/triage-reviewer.md"
schema_file="$root/.agents/schemas/triage.schema.json"

[[ -f "$review_input" ]] || fail "review artifact not found: $review_input"

review_dir="$(cd "$(dirname "$review_input")" && pwd -P)"
review_path="$review_dir/$(basename "$review_input")"

if [[ "$review_path" != "$root/.agents/reviews/"*.json ]]; then
  fail "review artifact must match .agents/reviews/*.json (the generated .md report is not an input). Received: $review_path"
fi

[[ -f "$prompt_file" ]] || fail "triage prompt not found: $prompt_file"
[[ -f "$schema_file" ]] || fail "triage schema not found: $schema_file"
review_data_require_jq

agent_resolve "$root" triage "$AGENT_CLI_PROVIDER" "$AGENT_CLI_MODEL"
agent="$AGENT_PROVIDER"
model="$AGENT_MODEL"

command -v gh >/dev/null 2>&1 || fail "GitHub CLI 'gh' is not installed."
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated. Run: gh auth login"

review_errors="$(review_artifact_errors "$review_path")"
if [[ -n "$review_errors" ]]; then
  echo "Error: invalid review artifact:" >&2
  printf '%s\n' "$review_errors" | sed 's/^/  - /' >&2
  exit 1
fi

review_relative="${review_path#"$root"/}"
review_stem="$(basename "$review_path" .json)"
source_issue="$(jq -r '.issue' "$review_path")"
printf -v review_ref 'R%02d' "$(jq -r '.round' "$review_path")"
finding_count="$(jq '.findings | length' "$review_path")"

source_issue_context="$(gh issue view "$source_issue" \
  --json title,body \
  --template 'Title: {{.title}}{{"\n\n"}}{{.body}}')" ||
  fail "could not read GitHub Issue #$source_issue."
source_issue_title="${source_issue_context%%$'\n'*}"
source_issue_title="${source_issue_title#Title: }"

# Follow-up titles get a deterministic provenance prefix: feature ID from the
# source Issue title (or the Issue number), review round, and finding ID.
provenance="[#$source_issue]"
if [[ "$source_issue_title" =~ (^|[^[:alnum:]])(F[0-9]+)([^[:alnum:]]|$) ]]; then
  provenance="[${BASH_REMATCH[2]}]"
fi
provenance+="[$review_ref]"

tmp_work="$(mktemp -d "${TMPDIR:-/tmp}/triage-review.XXXXXX")"
trap 'rm -rf "$tmp_work"' EXIT

# Triage and fixes apply only to the content that was reviewed.
stale_status=0
review_is_current "$root" "$tmp_work" "$review_path" || stale_status=$?
case "$stale_status" in
  0) ;;
  1) fail "the review is stale: the reviewed content changed after $review_relative was written. Run a new review." ;;
  *) fail "could not compute the current fingerprint of the working tree." ;;
esac

decisions_file="$tmp_work/decisions.json"
context_file="$tmp_work/context.md"

echo "Starting independent review triage:"
echo "  Review: $review_relative"
echo "  Agent:  $agent"
echo "  Model:  $model"
echo

if [[ "$finding_count" -eq 0 ]]; then
  echo "The review has no findings; no triage agent is needed."
  echo '{"decisions": []}' >"$decisions_file"
else
  {
    echo "# Triage context"
    echo
    echo "## Source feature Issue #$source_issue"
    echo
    printf '%s\n' "$source_issue_context"
    echo
    echo "## Review findings (JSON)"
    echo
    jq '{verdict, limitations, findings}' "$review_path"
  } >"$context_file"

  start_prompt="Read and follow .agents/prompts/triage-reviewer.md.

Source review artifact: ${review_relative}
Source feature Issue: #${source_issue}

Standard input contains the Issue and the review findings as JSON. Classify
every finding exactly once, using its 'id' as 'finding_id', and return JSON
that matches the supplied schema."

  review_hash_before="$(git hash-object "$review_path")"
  artifacts_before="$(fingerprint_artifacts "$root")"
  status_before="$(git -C "$root" status --porcelain=v1 --untracked-files=all)"

  # Invalid output is retried once; a failed agent or a modified tree is not.
  attempt_prompt="$start_prompt"
  for attempt in 1 2; do
    : >"$decisions_file"
    set +e
    agent_run read-only "$agent" "$model" "$root" "$attempt_prompt" "$decisions_file" "$context_file" "$schema_file"
    agent_status=$?
    set -e

    if [[ "$(git hash-object "$review_path")" != "$review_hash_before" ]]; then
      fail "triage agent modified the source review artifact."
    fi
    if [[ "$(git -C "$root" status --porcelain=v1 --untracked-files=all)" != "$status_before" ||
          "$(fingerprint_artifacts "$root")" != "$artifacts_before" ]]; then
      echo "Error: triage agent modified the working tree." >&2
      git -C "$root" status --short >&2
      exit 1
    fi
    [[ "$agent_status" -eq 0 ]] || fail "triage agent failed with status $agent_status."

    decision_errors="$(triage_decision_errors "$decisions_file" "$review_path")"
    [[ -n "$decision_errors" ]] || break

    echo "The triage agent returned invalid decisions (attempt $attempt of 2):" >&2
    printf '%s\n' "$decision_errors" | sed 's/^/  - /' >&2
    [[ "$attempt" -lt 2 ]] || fail "triage decisions are invalid. No artifact or GitHub Issues were created."
    echo "Retrying once..." >&2
    attempt_prompt="$start_prompt

Your previous result was rejected for these reasons:
$decision_errors

Return a corrected result."
  done
fi

# Combine the validated decisions with the findings they refer to, in the
# order of the review, and prefix follow-up titles with their provenance.
proposal_file="$tmp_work/proposal.json"
jq -n \
  --slurpfile review "$review_path" \
  --slurpfile result "$decisions_file" \
  --arg provenance "$provenance" '
  ($result[0].decisions | map({key: .finding_id, value: .}) | from_entries) as $decision
  | [ $review[0].findings[] | . as $finding | $decision[.id] as $d
      | {
          finding_id: .id,
          severity: .severity,
          title: .title,
          decision: $d.decision,
          rationale: $d.rationale,
          followup: (if $d.followup == null then null else {
              title: "\($provenance)[\($finding.id)] \($d.followup.title)",
              recommended_action: $d.followup.recommended_action,
              acceptance_criteria: $d.followup.acceptance_criteria,
              issue_number: null,
              issue_url: null
            } end)
        } ]' >"$proposal_file"

render_proposal() {
  jq -r '
    def group($decision):
      $decision,
      ([.[] | select(.decision == $decision)] as $items
       | if ($items | length) == 0 then "- (none)"
         else ($items[] |
           "- \(.finding_id) \(.title) — \(.rationale)",
           (if .followup != null then
              "  Follow-up Issue: \(.followup.title)" +
              (if .followup.issue_number != null then " → #\(.followup.issue_number)" else "" end),
              "  Recommended action: \(.followup.recommended_action)",
              "  Acceptance criteria:",
              (.followup.acceptance_criteria[] | "    - \(.)")
            else empty end))
         end),
      "";
    group("FIX_NOW"), group("DEFER"), group("ACCEPT")
  ' "$1"
}

echo
echo "Proposed triage:"
echo
render_proposal "$proposal_file"

deferred_count="$(jq '[.[] | select(.decision == "DEFER")] | length' "$proposal_file")"
if [[ "$deferred_count" -gt 0 ]]; then
  echo "Approval will create $deferred_count follow-up GitHub issue(s)."
fi

printf "Proceed with this triage? [y/N] "
approval=""
read -r approval || true
case "$approval" in
  y | Y | yes | YES) ;;
  *)
    echo "Triage declined; no artifact or GitHub issues were created."
    exit 0
    ;;
esac

triage_dir="$root/.agents/triage"
mkdir -p "$triage_dir"
artifact="$triage_dir/${review_stem}-triage"
artifact_number=2
while [[ -e "$artifact.json" || -e "$artifact.md" ]]; do
  artifact="$triage_dir/${review_stem}-triage-$(printf '%02d' "$artifact_number")"
  artifact_number=$((artifact_number + 1))
done
artifact_relative="${artifact#"$root"/}"

# Issues that earlier triage rounds of this review created, by finding.
previous_mappings="$tmp_work/previous-mappings.json"
shopt -s nullglob
previous_artifacts=("$triage_dir/${review_stem}-triage"*.json)
shopt -u nullglob
if [[ "${#previous_artifacts[@]}" -gt 0 ]]; then
  jq -s '[.[].decisions[]? | select(.followup != null and .followup.issue_url != null)
          | {key: .finding_id, value: .followup.issue_url}] | from_entries' \
    "${previous_artifacts[@]}" >"$previous_mappings"
else
  echo '{}' >"$previous_mappings"
fi

# The triage is completed in a working file and stored only when every
# deferred finding has its follow-up Issue. If creating an Issue fails, nothing
# is stored; Issues created so far carry a trace token and are reused by the
# next triage of this review.
pending="$tmp_work/triage.json"
jq -n \
  --slurpfile review "$review_path" \
  --slurpfile decisions "$proposal_file" \
  --arg source_review "$review_relative" \
  --arg agent "$agent" \
  --arg model "$model" \
  --arg approved_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" '
  {
    schema: "triage/v1",
    source_review: $source_review,
    issue: $review[0].issue,
    reviewed_tree: $review[0].reviewed_tree,
    review_verdict: $review[0].verdict,
    triage: {agent: $agent, model: $model},
    approved_at: $approved_at,
    decisions: $decisions[0]
  }' >"$pending"

record_issue() {
  local finding_id="$1"
  local issue_url="$2"
  local issue_number="${issue_url##*/}"

  [[ "$issue_number" =~ ^[0-9]+$ ]] ||
    fail "could not determine the Issue number from: $issue_url"

  jq --arg id "$finding_id" --arg url "$issue_url" --argjson number "$issue_number" '
    (.decisions[] | select(.finding_id == $id) | .followup) |= (. + {issue_number: $number, issue_url: $url})
  ' "$pending" >"$pending.tmp"
  mv "$pending.tmp" "$pending"
}

while IFS= read -r finding_id; do
  [[ -n "$finding_id" ]] || continue
  trace_token="triage-source:${review_relative}#${finding_id}"

  existing_issue_url="$(jq -r --arg id "$finding_id" '.[$id] // empty' "$previous_mappings")"
  if [[ -z "$existing_issue_url" ]]; then
    existing_issue_url="$(gh issue list \
      --state all \
      --limit 100 \
      --search "\"$trace_token\" in:body" \
      --json url \
      --jq '.[0].url // empty' </dev/null)"
  fi

  if [[ -n "$existing_issue_url" ]]; then
    record_issue "$finding_id" "$existing_issue_url"
    echo "Reusing existing follow-up Issue #${existing_issue_url##*/} for $finding_id."
    continue
  fi

  issue_title="$(jq -r --arg id "$finding_id" '.decisions[] | select(.finding_id == $id) | .followup.title' "$pending")"
  issue_body_file="$tmp_work/${finding_id}-issue.md"
  jq -r \
    --slurpfile review "$review_path" \
    --arg id "$finding_id" \
    --arg trace "$trace_token" \
    --arg source_review "$review_relative" '
    (.decisions[] | select(.finding_id == $id)) as $d
    | ($review[0].findings[] | select(.id == $id)) as $f
    | "<!-- \($trace) -->\n\n" +
      "# \($d.followup.title)\n\n" +
      "## Context\n\n" +
      "Deferred finding from the independent review of Issue #\(.issue).\n\n" +
      "Original finding: \($f.id) (\($f.severity))\n\n" +
      "## Finding\n\n\($f.title)\n\n" +
      "## Evidence\n\n\($f.evidence)\n\nSource: `\($source_review)`\n\n" +
      "## Why it matters\n\n\($f.impact)\n\nTriage rationale: \($d.rationale)\n\n" +
      "## Recommended action\n\n\($d.followup.recommended_action)\n\n" +
      "## Acceptance criteria\n\n" +
      ($d.followup.acceptance_criteria | map("- \(.)\n") | join("")) +
      "- `./scripts/verify.sh` passes."
  ' "$pending" >"$issue_body_file"

  echo "Creating follow-up Issue for $finding_id..."
  issue_url="$(gh issue create --title "$issue_title" --body-file "$issue_body_file" </dev/null | tail -n 1)" ||
    fail "creating the follow-up Issue for $finding_id failed. No triage artifact was stored; run the triage again, and Issues created so far are reused."
  record_issue "$finding_id" "$issue_url"
done < <(jq -r '.decisions[] | select(.decision == "DEFER") | .finding_id' "$pending")

artifact_errors="$(triage_artifact_errors "$pending" "$review_path")"
if [[ -n "$artifact_errors" ]]; then
  echo "Error: the triage artifact would be invalid; nothing was stored:" >&2
  printf '%s\n' "$artifact_errors" | sed 's/^/  - /' >&2
  exit 1
fi

cp "$pending" "$artifact.json"
triage_render_markdown "$artifact.json" "$(basename "$artifact").json" >"$artifact.md"

echo
echo "Triage completed:"
echo "  $artifact_relative.json  (source of truth)"
echo "  $artifact_relative.md    (generated report)"
echo
jq '.decisions' "$artifact.json" >"$tmp_work/final.json"
render_proposal "$tmp_work/final.json"
