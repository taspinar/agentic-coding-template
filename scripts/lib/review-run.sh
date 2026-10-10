#!/usr/bin/env bash

# Running a read-only reviewer and storing its result. Shared by
# review-feature.sh and review-planning.sh.
# Source this file after agent.sh, review-data.sh, and fingerprint.sh.

# review_run_reviewer <agent> <model> <root> <prompt> <context-file> <schema-file> <result-file> <scratch-dir> [validator]
# Runs a read-only agent that returns structured output. The validator prints
# the rule violations of a result file and defaults to review_result_errors.
# An invalid result is retried once, with the reasons for the rejection. Exits
# the calling script when the agent fails, changes the working tree or the
# review artifacts, creates a commit, or returns an invalid result twice.
review_run_reviewer() {
  local agent="$1"
  local model="$2"
  local root="$3"
  local prompt="$4"
  local context_file="$5"
  local schema_file="$6"
  local result_file="$7"
  local scratch="$8/review-run"
  local validator="${9:-review_result_errors}"
  local head_before
  local tree_before
  local artifacts_before
  local attempt_prompt="$prompt"
  local attempt
  local agent_status
  local result_errors

  mkdir -p "$scratch"
  head_before="$(git -C "$root" rev-parse HEAD)"
  tree_before="$(fingerprint_worktree "$root" "$scratch")" || {
    echo "Error: could not compute the fingerprint of the working tree." >&2
    exit 1
  }
  artifacts_before="$(fingerprint_artifacts "$root")"

  for attempt in 1 2; do
    : >"$result_file"
    agent_status=0
    agent_run read-only "$agent" "$model" "$root" "$attempt_prompt" "$result_file" "$context_file" "$schema_file" ||
      agent_status=$?

    if [[ "$(git -C "$root" rev-parse HEAD)" != "$head_before" ||
          "$(fingerprint_worktree "$root" "$scratch")" != "$tree_before" ||
          "$(fingerprint_artifacts "$root")" != "$artifacts_before" ]]; then
      echo "Error: the reviewer modified the working tree or created a commit. No review was stored." >&2
      git -C "$root" status --short >&2
      exit 1
    fi

    if [[ "$agent_status" -ne 0 ]]; then
      echo "Error: reviewer failed with status $agent_status. No review was stored." >&2
      exit 1
    fi

    result_errors="$("$validator" "$result_file")"
    [[ -n "$result_errors" ]] || return 0

    echo "The reviewer returned an invalid result (attempt $attempt of 2):" >&2
    printf '%s\n' "$result_errors" | sed 's/^/  - /' >&2
    if [[ "$attempt" -eq 2 ]]; then
      echo "Error: the reviewer's result is invalid. No review was stored." >&2
      exit 1
    fi
    echo "Retrying once..." >&2
    attempt_prompt="$prompt

Your previous result was rejected for these reasons:
$result_errors

Return a corrected result."
  done
}

# review_store <result-file> <artifact-base> <metadata-json>
# Stores <artifact-base>.json from the script-owned metadata and the validated
# result, renders <artifact-base>.md, and prints a summary. Exits the calling
# script, storing nothing, when the artifact would be invalid.
review_store() {
  local result_file="$1"
  local out="$2"
  local metadata="$3"
  local artifact_errors

  mkdir -p "$(dirname "$out")"
  review_result_with_ids "$result_file" | jq --argjson metadata "$metadata" '
    $metadata + {verdict: .verdict, limitations: .limitations, findings: .findings}
    + (if has("architecture_impact") then {architecture_impact} else {} end)
  ' >"$out.json"

  artifact_errors="$(review_artifact_errors "$out.json")"
  if [[ -n "$artifact_errors" ]]; then
    rm -f "$out.json"
    echo "Error: the stored review would be invalid; nothing was stored:" >&2
    printf '%s\n' "$artifact_errors" | sed 's/^/  - /' >&2
    exit 1
  fi
  review_render_markdown "$out.json" "$(basename "$out").json" >"$out.md"

  echo "Review completed: $(jq -r '.verdict | gsub("_"; " ")' "$out.json") ($(jq '.findings | length' "$out.json") findings)"
}
