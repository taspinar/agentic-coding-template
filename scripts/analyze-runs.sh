#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 [<issue>...] [--since <date>] [--until <date>] [--last <n>]"
  echo "          [--agent <agent>] [--model <model>] [--input-only]"
  echo
  echo "Analyses the run records and the experience records of several features"
  echo "and proposes improvements of the process, in order of priority, each with"
  echo "its place: an ADR, an agent instruction, a skill, the documentation, a check"
  echo "in a script, an Issue, or the workflow template. The analyst is a read-only"
  echo "agent (role 'analyst' in .agents/agents.conf); nothing in the repository"
  echo "changes, and every proposal goes through the review that applies to it."
  echo
  echo "Select the features by Issue, by period (--since, --until: YYYY-MM-DD, UTC,"
  echo "the start of their runs), or the <n> features whose first run started last"
  echo "(--last)."
  echo
  echo "The input, the result, and the report are kept in .agents/analysis/<id>/ of"
  echo "the primary checkout, which Git ignores. The input names the selected runs"
  echo "and the versions of their sources, so that an analysis can be repeated."
  echo "--input-only writes the input and stops."
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/agent.sh"
source "$script_dir/lib/fingerprint.sh"
command -v jq >/dev/null 2>&1 || fail "jq is required."

agent_parse_args "$@"
set -- ${AGENT_POSITIONAL[@]+"${AGENT_POSITIONAL[@]}"}
issues=()
since=""
until=""
last=""
input_only=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) [[ $# -ge 2 ]] || usage; since="$2"; shift ;;
    --until) [[ $# -ge 2 ]] || usage; until="$2"; shift ;;
    --last) [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || usage; last="$2"; shift ;;
    --input-only) input_only=1 ;;
    -h | --help) usage ;;
    *)
      [[ "$1" =~ ^[0-9]+$ ]] || usage
      issues+=("$1")
      ;;
  esac
  shift
done
[[ ${#issues[@]} -gt 0 || -n "$since$until$last" ]] || usage

primary="$(records_primary)" || fail "not inside a Git repository."
root="$(git rev-parse --show-toplevel)"
git -C "$primary" check-ignore -q ".agents/analysis/x" ||
  fail "Git does not ignore .agents/analysis/ in $primary, so an analysis would be committed. Take over the template's .gitignore with ./scripts/sync-template.sh."
if [[ "$input_only" -eq 0 ]]; then
  agent_resolve "$root" analyst "$AGENT_CLI_PROVIDER" "$AGENT_CLI_MODEL"
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/analyze-runs.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# ------------------------------------------------------------- the selection
period=()
[[ -z "$since" ]] || period+=(--since "$since")
[[ -z "$until" ]] || period+=(--until "$until")
"$script_dir/report-runs.sh" --all ${period[@]+"${period[@]}"} --json >"$work/all.json" ||
  fail "the run records could not be read."
if [[ ${#issues[@]} -eq 0 ]]; then
  # Every feature with a run in the period, or the <n> that ran last.
  while IFS= read -r issue; do
    [[ -n "$issue" ]] && issues+=("$issue")
  done < <(jq -r --argjson last "${last:-0}" '
    .subjects | map(select(.kind == "feature")) | sort_by(.first_start)
    | if $last > 0 then .[-$last:] else . end | .[].subject' "$work/all.json")
fi
[[ ${#issues[@]} -gt 0 ]] || fail "no feature has a run record in the selection."
"$script_dir/report-runs.sh" "${issues[@]}" ${period[@]+"${period[@]}"} --json >"$work/statistics.json" ||
  fail "the run records could not be read."

# The experience records, valid and invalid apart; an invalid one is no
# source and is only counted.
for issue in "${issues[@]}"; do
  "$script_dir/show-experience.sh" "$issue" --json
done | jq -cs '.' >"$work/experiences.json" || fail "the experience records could not be read."

# The evidence that earlier analyses used is no new evidence.
already='[]'
if compgen -G "$primary/.agents/analysis/*/analysis.json" >/dev/null; then
  already="$(jq -cs '[.[] | .evidence_used[]?] | unique' "$primary"/.agents/analysis/*/analysis.json 2>/dev/null)" || already='[]'
fi

# The versions of the sources, so that the input can be repeated.
template="$(sed -n 's/^commit:[[:space:]]*//p' "$root/.agents/template.conf" 2>/dev/null | head -n 1)"
[[ -n "$template" ]] || template="$(git -C "$root" rev-parse HEAD 2>/dev/null || true)"
# The workflow as it is in the working tree, uncommitted changes included: a
# content hash of the scripts, the prompts, the schemas, and agents.conf, and
# whether it differs from the commit.
workflow_paths=(scripts .agents/prompts .agents/schemas .agents/agents.conf)
workflow="$(fingerprint_files "$root" "$work" "${workflow_paths[@]}" 2>/dev/null)" || workflow=""
committed="$(git -C "$root" rev-parse HEAD 2>/dev/null || true)"
if [[ -n "$(git -C "$root" status --porcelain -- "${workflow_paths[@]}" 2>/dev/null)" ]]; then
  workflow_changed=true
else
  workflow_changed=false
fi

jq -n --slurpfile statistics "$work/statistics.json" --slurpfile experiences "$work/experiences.json" \
  --argjson already "$already" --arg since "$since" --arg until "$until" --arg last "$last" \
  --arg template "$template" --arg workflow "$workflow" --arg committed "$committed" --argjson changed "$workflow_changed" '
  $statistics[0] as $stats | $experiences[0] as $exp
  # Observations get an id that holds their run, so that a later analysis
  # recognises them.
  | ($stats.subjects | map(.by_run[].run)) as $selected
  # Only the records of the selected runs: a period leaves out the others.
  | ($exp | map({issue,
      records: (.valid | map(select(.run as $r | $selected | index([$r]))) | map(.run as $run | {run, command, code_version, derived,
        observations: (.observations | to_entries | map(.value + {id: "\($run)/\(.value.id // "observation-\(.key + 1)")"})),
        agent: (if .agent.status == "valid"
                then .agent + {observations: (.agent.observations | to_entries
                  | map(.value + {id: "\($run)/agent/\(.value.id // "\(.key + 1)")"}))}
                else .agent end)})),
      invalid: (.invalid | map(select(.run == null or (.run as $r | $selected | index([$r])))) | length)})) as $experiences
  | {schema: "analysis-input/v1",
     selection: {issues: ($stats.subjects | map(.subject)) , since: (if $since == "" then null else $since end),
                 until: (if $until == "" then null else $until end), last: (if $last == "" then null else ($last | tonumber) end),
                 runs: ($stats.subjects | map(.by_run[].run) | unique), without_record: $stats.without_record},
     sources: {template: $template, commit: $committed, workflow: $workflow, uncommitted_changes: $changed,
               snapshot: "sources/"},
     statistics: $stats,
     experiences: $experiences,
     already_analysed: $already}
  | .evidence_ids = ((.selection.runs)
      + ($stats.subjects | map("statistics/\(.kind)/\(.subject)"))
      + ([$experiences[].records[] | (.observations[].id), (.agent.observations? // [] | .[].id)]) | unique)' >"$work/input.json"

input_id="$(git hash-object "$work/input.json" | cut -c1-12)"
# Every analysis gets a directory of its own, also when two with the same
# input start in the same second: mkdir is atomic, and a taken name gets a
# number.
mkdir -p "$primary/.agents/analysis"
dir="$primary/.agents/analysis/$(date -u +'%Y%m%dT%H%M%SZ')-$input_id"
number=1
until mkdir "$dir" 2>/dev/null; do
  # Only a name that is taken is tried again; another failure is reported.
  [[ -e "$dir" ]] || fail "could not create $dir."
  number=$((number + 1))
  dir="$primary/.agents/analysis/$(date -u +'%Y%m%dT%H%M%SZ')-$input_id-$number"
done
cp "$work/input.json" "$dir/input.json"
# What the analyst gets besides the input, as it is now: its instructions, the
# schema of its result, and the configuration.
mkdir -p "$dir/sources"
cp "$root/.agents/prompts/analyst.md" "$root/.agents/schemas/analysis.schema.json" "$dir/sources/" 2>/dev/null || true
cp "$root/.agents/agents.conf" "$dir/sources/" 2>/dev/null || true
echo "Analysis input: ${dir#"$primary"/}/input.json"
echo "  Features: $(jq -r '.selection.issues | join(", ")' "$dir/input.json")"
echo "  Runs:     $(jq -r '.selection.runs | length' "$dir/input.json")"
echo "  Workflow: $(jq -r '.sources | "\(.workflow[0:12])\(if .uncommitted_changes then ", with uncommitted changes" else "" end)"' "$dir/input.json")"
echo "  Experience records: $(jq -r '[.experiences[].records[]] | length' "$dir/input.json") valid, $(jq -r '[.experiences[].invalid] | add // 0' "$dir/input.json") invalid (not used)"
[[ "$input_only" -eq 0 ]] || exit 0

# ------------------------------------------------------------ the analysis
# analysis_errors <result> <input>: what is wrong with the analyst's result.
analysis_errors() {
  jq -r --slurpfile input "$2" '
    $input[0] as $in | ($in.evidence_ids | map({key: ., value: true}) | from_entries) as $known
    | def runs_of: map(split("/")[0]) | unique | map(select(startswith("statistics") | not));
    [ (if (.conclusions | type) != "array" then "conclusions is not a list" else empty end),
      (.conclusions[]? | . as $c
        | (if (.evidence | length) == 0 then "conclusion \($c.id) cites no evidence" else empty end),
          (.evidence[] | select($known[.] | not) | "conclusion \($c.id) cites \(.), which is not in the input"),
          (if $c.kind == "finding" and ((.evidence | runs_of | length) < 2) then "conclusion \($c.id) is a finding with fewer than two runs behind it" else empty end),
          (if (.differences_considered | test("\\S") | not) then "conclusion \($c.id) does not say which differences it considered" else empty end)),
      (.contradictions[]?.evidence[]? | select($known[.] | not) | "a contradiction cites \(.), which is not in the input"),
      (.proposals[]? | . as $p
        | (if $p.concerns_workflow_scripts and $p.place != "template" then "proposal \($p.title) concerns the workflow scripts but is not placed in the template" else empty end),
          (if ($p.conclusions | length) == 0 then "proposal \($p.title) follows from no conclusion" else empty end)),
      (([.proposals[]?.conclusions[]] - [.conclusions[]?.id])[] | "a proposal names conclusion \(.), which does not exist"),
      (if .insufficient_evidence == false and (.conclusions | length) == 0 then "no conclusion, and the result does not say that the evidence is insufficient" else empty end) ]
    | .[]' "$1" 2>/dev/null || echo "the result is not the expected JSON"
}

prompt="$(cat "$root/.agents/prompts/analyst.md")

Standard input contains the analysis input as JSON. Return JSON that matches the supplied schema."
schema="$root/.agents/schemas/analysis.schema.json"
status_before="$(git -C "$root" status --porcelain=v1 --untracked-files=all)"
content_before="$(fingerprint_worktree "$root" "$work")"
artifacts_before="$(fingerprint_artifacts "$root")"
attempt_prompt="$prompt"
for attempt in 1 2; do
  : >"$work/result.json"
  set +e
  agent_run read-only "$AGENT_PROVIDER" "$AGENT_MODEL" "$root" "$attempt_prompt" "$work/result.json" "$dir/input.json" "$schema"
  agent_status=$?
  set -e
  if [[ "$(git -C "$root" status --porcelain=v1 --untracked-files=all)" != "$status_before" ||
    "$(fingerprint_worktree "$root" "$work")" != "$content_before" ||
    "$(fingerprint_artifacts "$root")" != "$artifacts_before" ]]; then
    git -C "$root" status --short >&2
    fail "the analyst changed the working tree; nothing of its result is kept."
  fi
  [[ "$agent_status" -eq 0 ]] || fail "the analyst failed with status $agent_status. The input is in ${dir#"$primary"/}/input.json."
  errors="$(analysis_errors "$work/result.json" "$dir/input.json")"
  [[ -n "$errors" ]] || break
  if [[ "$attempt" -eq 2 ]]; then
    printf 'Error: the analysis is invalid; nothing of it is kept:\n' >&2
    printf '%s\n' "$errors" | sed 's/^/  - /' >&2
    exit 1
  fi
  attempt_prompt="$prompt

Your previous result was invalid:
$errors
Return a corrected result."
done

# The files the analyst read besides the input, as they were, so that the
# analysis can be repeated; only files inside the repository.
jq -r '.consulted[]?' "$work/result.json" | while IFS= read -r path; do
  case "$path" in /* | *..*) continue ;; esac
  [[ -f "$root/$path" ]] || continue
  mkdir -p "$dir/sources/consulted/$(dirname "$path")"
  cp "$root/$path" "$dir/sources/consulted/$path"
done

# The result, with the evidence it used, so that a later analysis does not
# count it again; and which of it an earlier analysis had used already.
jq --arg input "$input_id" --slurpfile in "$dir/input.json" '
  . + {schema: "analysis/v1", input: $input,
       evidence_used: ([.conclusions[].evidence[], .contradictions[].evidence[]] | unique)}
  | .conclusions |= map(. + {seen_before: ([.evidence[] | select(. as $e | $in[0].already_analysed | index([$e]))])})' \
  "$work/result.json" >"$dir/analysis.json"

jq -r --slurpfile in "$dir/input.json" '
  def list(f): if length == 0 then "None.\n" else map(f) | join("") end;
  "# Run analysis\n\n"
  + "Features \($in[0].selection.issues | join(", ")); \($in[0].selection.runs | length) runs. "
  + "Template \($in[0].sources.template[0:12]), workflow content \($in[0].sources.workflow[0:12])\(if $in[0].sources.uncommitted_changes then " with uncommitted changes" else "" end); the sources are in sources/.\n\n"
  + (if .insufficient_evidence then "**The evidence is not sufficient for a conclusion.**\n\n" else "" end)
  + "\(.summary)\n\n## Conclusions\n\n"
  + (.conclusions | list("- **\(.kind)** \(.statement)\n  - evidence: \(.evidence | join(", "))\n"
      + (if (.seen_before | length) > 0 then "  - used by an earlier analysis: \(.seen_before | join(", "))\n" else "" end)
      + "  - differences considered: \(.differences_considered)\n  - uncertainty: \(.uncertainty)\n"))
  + "\n## Contradictions\n\n" + (.contradictions | list("- \(.statement) (\(.evidence | join(", ")))\n"))
  + "\n## Missing data\n\n" + (.missing_data | list("- \(.)\n"))
  + "\n## Proposals\n\n"
  + (.proposals | sort_by(.priority) | list("\(.priority). **\(.title)**, place: \(.place)\(if .concerns_workflow_scripts then " (an Issue in the template repository)" else "" end)\n"
      + "   - \(.rationale)\n   - follows from: \(.conclusions | join(", "))\n"
      + (if .enforceable_check then "   - enforceable check: \(.enforceable_check)\n" else "" end)))
  + "\nNothing was changed. A proposal goes through the review and approval that apply to its place.\n"' \
  "$dir/analysis.json" >"$dir/report.md"

echo
echo "Analysis: ${dir#"$primary"/}/report.md"
echo "  Conclusions: $(jq '.conclusions | length' "$dir/analysis.json"), proposals: $(jq '.proposals | length' "$dir/analysis.json")$(jq -r 'if .insufficient_evidence then "; the evidence is not sufficient" else "" end' "$dir/analysis.json")"
