#!/usr/bin/env bash

set -euo pipefail

# The analysis of several runs: a reproducible input, a read-only analyst, a
# result whose conclusions rest on cited evidence, and proposals that name
# their place.

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/analyze-runs-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "analyze-runs test failed: $*" >&2
  exit 1
}

unset RECORDS_RUN_ID RECORDS_FILE RECORDS_COMMAND RECORDS_KIND RECORDS_SUBJECT RECORDS_VERIFICATION RECORDS_DISABLED

source "$source_root/tests/lib-fakes.sh"
make_fake_agents "$tmp/bin"

# A repository with two features that each ran once, with a review whose
# major finding the triage fixed.
setup_repo() {
  local repo="$tmp/$1"
  local issue

  mkdir -p "$repo"
  copy_workflow "$repo"
  cp "$source_root/scripts/lib/report.jq" "$repo/scripts/lib/"
  cp "$source_root/.gitignore" "$repo/.gitignore"
  cp "$source_root/.agents/agents.conf" "$repo/.agents/agents.conf"
  printf 'commit: 0123456789abcdef0123456789abcdef01234567\n' >"$repo/.agents/template.conf"
  git -C "$repo" init -q -b main
  git -C "$repo" add -A
  git -C "$repo" -c user.name=Test -c user.email=test@example.com commit -qm "Seed"
  for issue in 21 22; do
    (
      cd "$repo"
      source scripts/lib/records.sh
      records_begin feature "$issue" run-feature.sh
      mkdir -p .agents/reviews .agents/triage
      printf '%s\n' "{\"schema\": \"review/v1\", \"issue\": $issue, \"round\": 1, \"head\": \"h$issue\",
        \"findings\": [{\"id\": \"M1\", \"severity\": \"major\", \"title\": \"The verification was skipped\"}]}" \
        >".agents/reviews/feature-$issue-thing-review-01.json"
      records_artifact review ".agents/reviews/feature-$issue-thing-review-01.json"
      records_agent_call reviewer read-only claude model-r 30 0 "" ""
      records_end 0
    )
  done
  printf '%s\n' "$repo"
}

analyze() {
  local repo="$1"
  shift
  (
    cd "$repo"
    PATH="${EXTRA_PATH:-}$tmp/bin:/usr/bin:/bin" MOCK_AGENT_LOG="$repo.agent" ./scripts/analyze-runs.sh "$@"
  ) >"$repo.out" 2>&1
}

# latest <repo>: the directory of the last analysis, as the script named it;
# names that start in the same second do not sort in the order of the runs.
latest() {
  printf '%s/%s\n' "$1" "$(sed -n 's#^Analysis input: \(.*\)input.json$#\1#p' "$1.out" | tail -n 1)"
}

# The input names the selected runs, the versions of the sources, and the ids
# the analyst may cite; writing it calls no agent.
repo="$(setup_repo basic)"
analyze "$repo" 21 22 --input-only || { cat "$repo.out" >&2; fail "writing the input failed"; }
[[ ! -e "$repo.agent" ]] || fail "--input-only called an agent"
input="$(latest "$repo")input.json"
[[ "$(jq -c '[.schema, .selection.issues, (.selection.runs | length), .sources.template]' "$input")" == '["analysis-input/v1",["21","22"],2,"0123456789abcdef0123456789abcdef01234567"]' ]] ||
  fail "the input does not name the selection and the sources: $(jq -c '{selection, sources}' "$input")"
jq -e '.sources | (.workflow | length) == 40 and (.commit | length) == 40 and .uncommitted_changes == false' "$input" >/dev/null ||
  fail "the input lacks a source version: $(jq -c .sources "$input")"
for file in analyst.md analysis.schema.json agents.conf; do
  [[ -f "$(latest "$repo")sources/$file" ]] || fail "the snapshot lacks $file"
done
runs=($(jq -r '.selection.runs[]' "$input"))
for run in "${runs[@]}"; do
  jq -e --arg id "$run/review-1-M1" '.evidence_ids | index([$id])' "$input" >/dev/null || fail "the observation of $run cannot be cited"
done
jq -e '.evidence_ids | index(["statistics/feature/21"])' "$input" >/dev/null || fail "the statistics cannot be cited"
[[ -z "$(git -C "$repo" status --porcelain)" ]] || fail "the input changed the repository"
# --last selects the features that started last.
analyze "$repo" --last 1 --input-only || fail "--last failed"
[[ "$(jq -c '.selection.issues' "$(latest "$repo")input.json")" == '["22"]' ]] || fail "--last did not select the last feature"

# result <findings-runs...>: a valid result with one finding on the given runs.
result() {
  jq -cn --arg a "$1/review-1-M1" --arg b "$2/review-1-M1" '{
    insufficient_evidence: false, summary: "Skipped verifications recur.",
    conclusions: [{id: "C1", kind: "finding", statement: "Reviews find skipped verifications",
      evidence: [$a, $b], differences_considered: "Both features are small and ran with the same model and template.",
      uncertainty: "Two runs only."}],
    contradictions: [], missing_data: ["token figures of the implementer"], consulted: [".agents/reviews/feature-21-thing-review-01.json", "../outside.txt"],
    proposals: [{priority: 1, title: "Check that a verification ran before a review", place: "template",
      concerns_workflow_scripts: true, enforceable_check: "review-feature.sh refuses a review without a recorded verification",
      rationale: "The finding recurs.", conclusions: ["C1"]}]}'
}

# A valid analysis: a read-only agent, a report with evidence and proposals,
# and nothing changed in the repository.
MOCK_OUTPUT="$(result "${runs[0]}" "${runs[1]}")" analyze "$repo" 21 22 || { cat "$repo.out" >&2; fail "a valid analysis failed"; }
grep -q "ARGS=.*--print" "$repo.agent" || fail "the analyst did not run as a read-only session"
if grep -Eq "acceptEdits|workspace-write|--permission-mode auto" "$repo.agent"; then fail "the analyst could write"; fi
report="$(latest "$repo")report.md"
grep -Fq -- "- **finding** Reviews find skipped verifications" "$report" || fail "the report lacks the conclusion"
grep -Fq "  - evidence: ${runs[0]}/review-1-M1, ${runs[1]}/review-1-M1" "$report" || fail "the report does not cite the evidence"
grep -Fq "place: template (an Issue in the template repository)" "$report" || fail "the place of the proposal is not named"
grep -Fq "enforceable check: review-feature.sh refuses" "$report" || fail "the enforceable check is not in the report"
grep -Fq -- "- token figures of the implementer" "$report" || fail "the missing data is not in the report"
[[ -f "$(latest "$repo")sources/consulted/.agents/reviews/feature-21-thing-review-01.json" ]] || fail "a consulted file was not kept"
[[ ! -e "$(latest "$repo")sources/outside.txt" && -z "$(find "$(latest "$repo")sources" -name outside.txt)" ]] || fail "a path outside the repository was copied"
[[ -z "$(git -C "$repo" status --porcelain)" ]] || fail "the analysis changed the repository: $(git -C "$repo" status --porcelain)"

# A repeated analysis marks the evidence that an earlier one used.
MOCK_OUTPUT="$(result "${runs[0]}" "${runs[1]}")" analyze "$repo" 21 22 || fail "a repeated analysis failed"
dir="$(latest "$repo")"
jq -e '.already_analysed | length == 2' "$dir/input.json" >/dev/null || fail "the input does not name the evidence used before"
[[ "$(jq -c '.conclusions[0].seen_before | length' "$dir/analysis.json")" == "2" ]] || fail "evidence used before is not marked"
grep -Fq "used by an earlier analysis:" "$dir/report.md" || fail "the report does not say what an earlier analysis used"

# invalid <label> <result> <message>: a result that is rejected twice.
invalid() {
  local before

  before="$(find "$repo/.agents/analysis" -name analysis.json | wc -l)"
  if MOCK_OUTPUT="$2" analyze "$repo" 21 22; then fail "$1 was accepted"; fi
  grep -Fq "$3" "$repo.out" || { cat "$repo.out" >&2; fail "$1 was not reported as such"; }
  [[ "$(find "$repo/.agents/analysis" -name analysis.json | wc -l)" -eq "$before" ]] || fail "$1 was kept"
  [[ ! -e "$(latest "$repo")analysis.json" ]] || fail "$1 was kept in its directory"
}
invalid "a finding on one run" "$(result "${runs[0]}" "${runs[0]}")" "is a finding with fewer than two runs behind it"
invalid "unknown evidence" "$(result "${runs[0]}" "made-up-run")" "cites made-up-run/review-1-M1, which is not in the input"
invalid "a workflow proposal outside the template" "$(result "${runs[0]}" "${runs[1]}" | jq -c '.proposals[0].place = "documentation"')" \
  "concerns the workflow scripts but is not placed in the template"
invalid "a conclusion without the differences" "$(result "${runs[0]}" "${runs[1]}" | jq -c '.conclusions[0].differences_considered = " "')" \
  "does not say which differences it considered"
invalid "no conclusion without saying so" '{"insufficient_evidence": false, "summary": "", "conclusions": [], "contradictions": [], "missing_data": [], "proposals": [], "consulted": []}' \
  "the result does not say that the evidence is insufficient"

# Two analyses of the same input in the same second keep a directory each: a
# date that always gives the same second names their directories.
mkdir -p "$tmp/same-second"
cat >"$tmp/same-second/date" <<'DATE'
#!/usr/bin/env bash
if [[ "$*" == "-u +%Y%m%dT%H%M%SZ" ]]; then echo 20260101T000000Z; else exec /bin/date "$@"; fi
DATE
chmod +x "$tmp/same-second/date"
EXTRA_PATH="$tmp/same-second:" analyze "$repo" 21 22 --input-only && first="$(latest "$repo")"
EXTRA_PATH="$tmp/same-second:" analyze "$repo" 21 22 --input-only && second="$(latest "$repo")"
[[ "$first" != "$second" && -f "${first}input.json" && -f "${second}input.json" ]] ||
  fail "two analyses of the same input share a directory: $first $second"

# A directory that cannot be made is a failure, not a loop.
chmod 0555 "$repo/.agents/analysis"
status=0
(analyze "$repo" 21 22 --input-only) & pid=$!
for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$pid" 2>/dev/null; then kill "$pid"; chmod 0755 "$repo/.agents/analysis"; fail "an analysis kept trying to make its directory"; fi
wait "$pid" || status=$?
chmod 0755 "$repo/.agents/analysis"
[[ "$status" -ne 0 ]] || fail "an analysis without a directory succeeded"
grep -Fq "could not create" "$repo.out" || fail "the failure to make the directory was not reported"

# An invalid first result is corrected once.
rm -f "$repo.agent.called"
MOCK_OUTPUT_FIRST="$(result "${runs[0]}" "${runs[0]}")" MOCK_OUTPUT="$(result "${runs[0]}" "${runs[1]}")" analyze "$repo" 21 22 ||
  { cat "$repo.out" >&2; fail "a corrected result was not accepted"; }

# Not enough evidence is a valid outcome.
MOCK_OUTPUT='{"insufficient_evidence": true, "summary": "Two runs show no pattern.", "conclusions": [], "contradictions": [], "missing_data": ["more runs"], "proposals": [], "consulted": []}' \
  analyze "$repo" 21 22 || { cat "$repo.out" >&2; fail "an analysis without enough evidence failed"; }
grep -Fq "**The evidence is not sufficient for a conclusion.**" "$(latest "$repo")report.md" || fail "insufficient evidence is not reported"

# An analyst that changes the working tree fails, and nothing is kept.
if MOCK_AGENT_ACTION='printf "x\n" >changed.txt' MOCK_OUTPUT="$(result "${runs[0]}" "${runs[1]}")" analyze "$repo" 21 22; then
  fail "an analyst that changed the tree succeeded"
fi
grep -Fq "the analyst changed the working tree" "$repo.out" || fail "the change of the tree was not reported"
rm -f "$repo/changed.txt"
# Also a change to a file that was changed already before the analysis.
printf '# a local change\n' >>"$repo/scripts/lib/report.jq"
if MOCK_AGENT_ACTION='printf "# more\n" >>scripts/lib/report.jq' MOCK_OUTPUT="$(result "${runs[0]}" "${runs[1]}")" analyze "$repo" 21 22; then
  fail "an analyst that changed an already changed file succeeded"
fi
grep -Fq "the analyst changed the working tree" "$repo.out" || fail "the change of an already changed file was not reported"
git -C "$repo" checkout -q -- scripts/lib/report.jq
# And a change to a review artifact, which Git ignores.
if MOCK_AGENT_ACTION='printf " " >>.agents/reviews/feature-21-thing-review-01.json' MOCK_OUTPUT="$(result "${runs[0]}" "${runs[1]}")" analyze "$repo" 21 22; then
  fail "an analyst that changed a review artifact succeeded"
fi
grep -Fq "the analyst changed the working tree" "$repo.out" || fail "the change of a review artifact was not reported"

# A changed prompt is part of the input: the input says that the workflow has
# uncommitted changes, and the snapshot holds the prompt as it was used.
printf '\nA local instruction.\n' >>"$repo/.agents/prompts/analyst.md"
analyze "$repo" 21 22 --input-only || fail "the input with a changed prompt failed"
jq -e '.sources.uncommitted_changes == true' "$(latest "$repo")input.json" >/dev/null || fail "uncommitted changes of the workflow are not named"
[[ "$(jq -r '.sources.workflow' "$(latest "$repo")input.json")" != "$(jq -r '.sources.workflow' "$input")" ]] || fail "the changed prompt has the same workflow version"
grep -Fq "A local instruction." "$(latest "$repo")sources/analyst.md" || fail "the snapshot does not hold the prompt as it was used"
git -C "$repo" checkout -q -- .agents/prompts/analyst.md

# A period selects runs, not features: a run of feature 21 before the period
# and its observation are not in the input.
repo="$(setup_repo period)"
mkdir -p "$tmp/old-date"
cat >"$tmp/old-date/date" <<'DATE'
#!/usr/bin/env bash
epoch=1577880000
if [[ "$*" == *%s* ]]; then echo "$epoch"; exit 0; fi
format="${@: -1}"
/bin/date -u -d "@$epoch" "$format" 2>/dev/null || /bin/date -u -r "$epoch" "$format"
DATE
chmod +x "$tmp/old-date/date"
(
  cd "$repo"
  export PATH="$tmp/old-date:$PATH"
  source scripts/lib/records.sh
  records_begin feature 21 run-feature.sh
  records_artifact review .agents/reviews/feature-21-thing-review-01.json
  records_end 0
)
old_run="$(cat "$repo"/.agents/run/records/*.jsonl | jq -r 'select(.type == "run-start" and .epoch == 1577880000) | .run')"
[[ -n "$old_run" ]] || fail "the test did not make a run before the period"
analyze "$repo" --since 2021-01-01 --input-only || { cat "$repo.out" >&2; fail "a period selection failed"; }
input="$(latest "$repo")input.json"
if jq -e --arg run "$old_run" '(.selection.runs | index([$run])) or ([.evidence_ids[] | startswith($run)] | any) or ([.experiences[].records[].run] | index([$run]))' "$input" >/dev/null; then
  fail "a run before the period is in the input"
fi
[[ "$(jq '.selection.runs | length' "$input")" == "2" ]] || fail "the runs in the period are not all in the input"

# Without the ignore rule nothing is written.
repo="$(setup_repo unignored)"
grep -v '^.agents/analysis/$' "$repo/.gitignore" >"$repo/.gitignore.new" && mv "$repo/.gitignore.new" "$repo/.gitignore"
if analyze "$repo" 21 --input-only; then fail "an analysis ran without the ignore rule"; fi
grep -Fq "Git does not ignore .agents/analysis/" "$repo.out" || fail "the missing ignore rule was not named"

echo "analyze-runs tests passed"
