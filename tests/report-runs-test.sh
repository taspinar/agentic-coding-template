#!/usr/bin/env bash

set -euo pipefail

# The report on the run records: totals without double counting, elapsed time
# apart from agent time, unknown figures that stay unknown, comparisons that
# name what differs, and a GitHub summary that holds numbers only.

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/report-runs-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "report-runs test failed: $*" >&2
  exit 1
}

source "$source_root/tests/lib-fakes.sh"

# No network: a GitHub CLI or curl that is called fails the test.
mkdir -p "$tmp/bin"
ln -sf "$(command -v jq)" "$tmp/bin/jq"
for tool in gh curl; do
  printf '#!/usr/bin/env bash\necho called >>"%s/network"\nexit 1\n' "$tmp" >"$tmp/bin/$tool"
  chmod +x "$tmp/bin/$tool"
done

setup_repo() {
  local repo="$tmp/$1"

  mkdir -p "$repo/scripts/lib" "$repo/.agents/run/records" "$repo/.agents/records"
  cp "$source_root/scripts/report-runs.sh" "$repo/scripts/"
  cp "$source_root/scripts/lib/records.sh" "$source_root/scripts/lib/report.jq" "$repo/scripts/lib/"
  git -C "$repo" init -q -b main
  printf '%s\n' "$repo"
}

# event <file> <run> <epoch> <type> <json-fields>: appends one event.
event() {
  jq -cn --arg run "$2" --argjson epoch "$3" --arg type "$4" --argjson fields "$5" \
    '{schema: "run-record/v1", run: $run, time: ($epoch | todate), epoch: $epoch, type: $type} + $fields' >>"$1"
}

# run_file <repo> <run> <issue> <command> <start> <end|-> <status> [template] [model]
# A run with one agent call that reports its tokens.
run_file() {
  local file="$1/.agents/run/records/$2.jsonl"
  local template="${8:-aaa}"
  local model="${9:-model-r}"

  event "$file" "$2" "$5" run-start "{\"kind\":\"feature\",\"subject\":\"$3\",\"command\":\"$4\",\"seq\":null,\"versions\":{\"template\":\"$template\"}}"
  event "$file" "$2" "$5" agent-call "{\"role\":\"reviewer\",\"agent\":\"codex\",\"model\":\"$model\",\"status\":0,\"seconds\":100,\"usage\":{\"source\":\"codex-events\",\"total_input\":1000,\"output_tokens\":10}}"
  [[ "$6" == "-" ]] || event "$file" "$2" "$6" run-end "{\"status\":$7}"
}

report() {
  local repo="$1"
  shift
  (cd "$repo" && PATH="$tmp/bin:/usr/bin:/bin" ./scripts/report-runs.sh "$@")
}

# Two runs side by side and one after them: the elapsed time is their union,
# the agent time the sum of the calls.
repo="$(setup_repo basic)"
run_file "$repo" r1 12 review-feature.sh 1000 1600 0
run_file "$repo" r2 12 verify.sh 1300 1900 1
run_file "$repo" r3 12 run-feature.sh 5000 5100 3
run_file "$repo" r4 12 run-feature.sh 6000 - 0
json="$(report "$repo" 12 --json)"
[[ "$(jq '.subjects[0].elapsed.seconds' <<<"$json")" -eq 1000 ]] ||
  fail "the elapsed time of runs side by side is not their union: $(jq -c '.subjects[0].elapsed' <<<"$json")"
[[ "$(jq '.subjects[0].agent_seconds' <<<"$json")" -eq 400 ]] || fail "the agent time is not the sum of the calls"
[[ "$(jq -c '.subjects[0].runs | [.completed, .failed, .blocked, .incomplete]' <<<"$json")" == "[1,1,1,1]" ]] ||
  fail "the outcome of the runs is wrong: $(jq -c '.subjects[0].runs' <<<"$json")"
[[ "$(jq '.subjects[0].elapsed.runs_without_end' <<<"$json")" -eq 1 ]] || fail "a run without an end is not named"
grep -Fq "higher than the elapsed time when work ran side by side" <<<"$(report "$repo" 12)" ||
  fail "the Markdown does not tell agent time from elapsed time"

# A run is counted once: from its own file while it exists, from the copy of
# its feature when it is gone. The copy alone gives the same totals, as after
# the removal of a worktree.
cat "$repo"/.agents/run/records/*.jsonl >"$repo/.agents/records/feature-12.jsonl"
copy_and_files="$(report "$repo" 12 --json | jq -c '.subjects[0] | {runs, elapsed, input, output, rounds}')"
[[ "$copy_and_files" == "$(jq -c '.subjects[0] | {runs, elapsed, input, output, rounds}' <<<"$json")" ]] ||
  fail "a run that is both in its file and in the copy was counted twice: $copy_and_files"
mkdir "$tmp/moved" && mv "$repo"/.agents/run/records/r*.jsonl "$tmp/moved/"
[[ "$(report "$repo" 12 --json | jq -c '.subjects[0] | {runs, elapsed, input, output, rounds}')" == "$copy_and_files" ]] ||
  fail "the copy alone gives other totals than the run files"
mv "$tmp/moved"/*.jsonl "$repo/.agents/run/records/"
# A run that is only in its file, newer than the copy, is added once.
run_file "$repo" r5 12 review-feature.sh 7000 7100 0
[[ "$(report "$repo" 12 --json | jq '.subjects[0].runs.total')" -eq 5 ]] || fail "a run newer than the copy was not added once"

# Missing token figures are unknown, never zero.
repo="$(setup_repo unknown)"
file="$repo/.agents/run/records/u1.jsonl"
event "$file" u1 100 run-start '{"kind":"feature","subject":"13","command":"run-feature.sh","seq":1,"versions":{}}'
event "$file" u1 110 agent-call '{"role":"implementer","agent":"claude","model":"m","status":0,"seconds":5,"usage":{"source":"interactive"}}'
event "$file" u1 120 agent-call '{"role":"reviewer","agent":"codex","model":"m","status":0,"seconds":5,"usage":{"source":"codex-events","total_input":null,"output_tokens":7}}'
event "$file" u1 130 agent-call '{"role":"reviewer","agent":"codex","model":"m","status":0,"seconds":5,"usage":{"source":"codex-events","total_input":500,"output_tokens":3}}'
event "$file" u1 140 run-end '{"status":0}'
json="$(report "$repo" 13 --json)"
[[ "$(jq -c '.subjects[0].input' <<<"$json")" == '{"sum":500,"known":1,"partial":0,"unknown":2}' ]] ||
  fail "unknown input figures were counted: $(jq -c '.subjects[0].input' <<<"$json")"
markdown="$(report "$repo" 13)"
grep -Fq "| Input tokens | at least 500 (2 of 3 calls without figures) |" <<<"$markdown" ||
  fail "a partial sum is not marked as such"
grep -Fq "| implementer | claude | m | 1 | 5s | unknown | unknown |" <<<"$markdown" ||
  fail "a call without figures is shown as zero"

# Interventions count only when they were recorded; a run after a stopped one
# is not an intervention.
event "$file" u1 135 intervention '{"what":"approved the triage of a review"}'
event "$file" u1 136 resumed '{"after":"u0","previous_status":3,"handoff_changed":true}'
json="$(report "$repo" 13 --json)"
[[ "$(jq -c '.subjects[0].interventions' <<<"$json")" == '[{"what":"approved the triage of a review","count":1}]' ]] ||
  fail "the interventions are not the recorded ones: $(jq -c '.subjects[0].interventions' <<<"$json")"

# Partial figures, which only some turns of a call reported, count in the sum
# as a lower bound and are counted apart from complete and unknown calls.
repo="$(setup_repo partial)"
file="$repo/.agents/run/records/p1.jsonl"
event "$file" p1 100 run-start '{"kind":"feature","subject":"16","command":"run-feature.sh","seq":1,"versions":{}}'
event "$file" p1 110 agent-call '{"role":"reviewer","agent":"codex","model":"m","status":0,"seconds":5,"usage":{"source":"codex-events","total_input":null,"output_tokens":null,"partial":{"input_tokens":100,"output_tokens":5}}}'
event "$file" p1 120 agent-call '{"role":"reviewer","agent":"codex","model":"m","status":0,"seconds":5,"usage":{"source":"codex-events","total_input":1000,"output_tokens":10}}'
event "$file" p1 130 agent-call '{"role":"reviewer","agent":"codex","model":"m","status":0,"seconds":5,"usage":{"source":"unavailable"}}'
event "$file" p1 140 run-end '{"status":0}'
json="$(report "$repo" 16 --json)"
[[ "$(jq -c '.subjects[0] | [.input, .output]' <<<"$json")" == '[{"sum":1100,"known":1,"partial":1,"unknown":1},{"sum":15,"known":1,"partial":1,"unknown":1}]' ]] ||
  fail "partial figures are not a separate state: $(jq -c '.subjects[0] | [.input, .output]' <<<"$json")"
markdown="$(report "$repo" 16)"
grep -Fq "at least 1100 (1 of 3 calls with partial figures" <<<"$(grep -F "| Input tokens |" <<<"$markdown")" ||
  fail "the Markdown does not mark a partial sum as a lower bound"
summary="$(report "$repo" --github-summary 16)"
grep -Fq "| reviewer | m | 3 | ≥ 1100 | ≥ 15 |" <<<"$summary" || fail "the GitHub summary does not show a partial sum as a lower bound: $summary"
grep -Fq "| 1 / 1 / 1 | 1 / 1 / 1 |" <<<"$summary" || fail "the GitHub summary does not count complete, partial, and unknown calls apart: $summary"
# A feature with partial figures is left out of the means of tokens.
run_file "$repo" p2 17 run-feature.sh 90000 90100 0
markdown="$(report "$repo" 16 17 --split "$(jq -rn '90000 | todate | .[0:10]')")"
grep -Fq "(before: 1, after: 0)" <<<"$markdown" || fail "a feature with partial figures is in the means of tokens"
# A call whose only figure is partial is a lower bound, not unknown.
repo="$(setup_repo partial-only)"
file="$repo/.agents/run/records/q1.jsonl"
event "$file" q1 100 run-start '{"kind":"feature","subject":"18","command":"run-feature.sh","seq":1,"versions":{}}'
event "$file" q1 110 agent-call '{"role":"reviewer","agent":"codex","model":"m","status":0,"seconds":5,"usage":{"source":"codex-events","total_input":null,"output_tokens":null,"partial":{"input_tokens":100}}}'
event "$file" q1 120 run-end '{"status":0}'
json="$(report "$repo" 18 --json)"
[[ "$(jq -c '.subjects[0] | [.input, .output]' <<<"$json")" == '[{"sum":100,"known":0,"partial":1,"unknown":0},{"sum":0,"known":0,"partial":0,"unknown":1}]' ]] ||
  fail "a partial input beside an unknown output is wrong: $(jq -c '.subjects[0] | [.input, .output]' <<<"$json")"
grep -E "^\| reviewer \|.*\| at least 100 \(.*partial.*\) \| unknown \|$" <<<"$(report "$repo" 18)" >/dev/null ||
  fail "a partial figure is shown as unknown or complete"
grep -Fq "| ≥ 100 | unknown |" <<<"$(report "$repo" --github-summary 18)" ||
  fail "the GitHub summary does not tell a partial input from an unknown output"
grep -Fq "| 0 / 1 / 0 | 0 / 0 / 1 |" <<<"$(report "$repo" --github-summary 18)" ||
  fail "the GitHub summary does not count a partial input apart from an unknown output"
# A feature whose only incompleteness is a partial input is left out of the
# mean of input tokens, and stays in the mean of the complete output tokens.
repo="$(setup_repo partial-means)"
file="$repo/.agents/run/records/r1.jsonl"
event "$file" r1 90000 run-start '{"kind":"feature","subject":"19","command":"run-feature.sh","seq":1,"versions":{}}'
event "$file" r1 90010 agent-call '{"role":"reviewer","agent":"codex","model":"m","status":0,"seconds":5,"usage":{"source":"codex-events","total_input":null,"output_tokens":10,"partial":{"input_tokens":100}}}'
event "$file" r1 90020 run-end '{"status":0}'
json="$(report "$repo" 19 --split "$(jq -rn '80000 | todate | .[0:10]')" --json)"
[[ "$(jq -c '.before_after.after | [.mean_input_tokens, .mean_output_tokens, .features_with_unknown_tokens]' <<<"$json")" == "[null,10,1]" ]] ||
  fail "a partial input is in the mean of input tokens: $(jq -c '.before_after.after' <<<"$json")"

# A call or a step that started and did not finish, as in an interrupted run,
# counts with unknown figures: a total beside it is not complete.
repo="$(setup_repo interrupted)"
file="$repo/.agents/run/records/i1.jsonl"
event "$file" i1 100 run-start '{"kind":"feature","subject":"14","command":"run-feature.sh","seq":1,"versions":{}}'
event "$file" i1 101 step-start '{"id":"s1","name":"review, round 1 of at most 5"}'
event "$file" i1 102 agent-start '{"id":"a1","role":"reviewer","profile":"read-only","agent":"codex","model":"m"}'
event "$file" i1 150 agent-call '{"id":"a1","role":"reviewer","profile":"read-only","agent":"codex","model":"m","status":0,"seconds":48,"usage":{"source":"codex-events","total_input":800,"output_tokens":8}}'
event "$file" i1 151 step '{"id":"s1","name":"review, round 1 of at most 5","status":0,"seconds":50}'
event "$file" i1 152 step-start '{"id":"s2","name":"review, round 2 of at most 5"}'
event "$file" i1 153 agent-start '{"id":"a2","role":"reviewer","profile":"read-only","agent":"codex","model":"m"}'
event "$file" i1 160 run-end '{"status":130}'
json="$(report "$repo" 14 --json)"
[[ "$(jq -c '.subjects[0].input' <<<"$json")" == '{"sum":800,"known":1,"partial":0,"unknown":1}' ]] ||
  fail "an unfinished call does not make the total incomplete: $(jq -c '.subjects[0].input' <<<"$json")"
[[ "$(jq -c '.subjects[0].agents[0] | [.calls, .failed, .unfinished]' <<<"$json")" == "[2,0,1]" ]] ||
  fail "the unfinished call is not counted as one: $(jq -c '.subjects[0].agents[0]' <<<"$json")"
[[ "$(jq -c '.subjects[0].steps[0] | [.count, .unfinished]' <<<"$json")" == "[2,1]" ]] ||
  fail "the unfinished step is not counted as one: $(jq -c '.subjects[0].steps' <<<"$json")"
[[ "$(jq -c '.subjects[0].by_run[0].input' <<<"$json")" == '{"sum":800,"known":1,"partial":0,"unknown":1}' ]] ||
  fail "the run does not show its unfinished call"
markdown="$(report "$repo" 14)"
grep -Fq "| reviewer | codex | m | 2 (1 unfinished) | 48s | at least 800 (1 of 2 calls without figures) |" <<<"$markdown" ||
  fail "the Markdown does not show the unfinished call"
grep -Fq "without 1 calls that did not finish" <<<"$markdown" || fail "the agent time does not say that a call did not finish"
grep -Fq "| reviewer | m | 2 | ≥ 800 | ≥ 8 |" <<<"$(report "$repo" --github-summary 14)" ||
  fail "the GitHub summary shows an incomplete total as complete"
# A feature with an unfinished call is left out of the means of tokens.
run_file "$repo" i2 15 run-feature.sh 90000 90100 0
markdown="$(report "$repo" 14 15 --split "$(jq -rn '90000 | todate | .[0:10]')")"
grep -Fq "(before: 1, after: 0)" <<<"$markdown" || fail "a feature with an unfinished call is in the means of tokens"

# A feature in progress in a linked worktree is read from the primary
# checkout, where its runs are written, also when the report runs there.
repo="$(setup_repo linked)"
cp "$source_root/.gitignore" "$repo/.gitignore"
git -C "$repo" add -A
git -C "$repo" -c user.name=Test -c user.email=test@example.com commit -qm "Seed"
git -C "$repo" worktree add -q -b feature/40-linked "$tmp/linked-40" >/dev/null 2>&1
(
  cd "$tmp/linked-40"
  source scripts/lib/records.sh
  records_begin feature 40 run-feature.sh
  records_end 0
)
[[ "$(cd "$tmp/linked-40" && PATH="$tmp/bin:/usr/bin:/bin" ./scripts/report-runs.sh --json | jq -c '[.subjects[].subject, (.without_record | length)]')" == '["40",0]' ]] ||
  fail "a feature in progress in a worktree was not reported from the worktree"
[[ "$(report "$repo" 40 --json | jq '.subjects[0].runs.total')" -eq 1 ]] ||
  fail "a feature in progress in a worktree was not reported from the primary checkout"

# A feature without any record is named, not counted as zero.
repo="$tmp/unknown"
markdown="$(report "$repo" 13 99)"
grep -Fq "Without any record: feature 99. They are left out, not counted as zero." <<<"$markdown" ||
  fail "a feature without a record is not named"
[[ "$(report "$repo" 13 99 --json | jq -c '[(.subjects | length), .without_record]')" == '[1,[{"kind":"feature","subject":"99"}]]' ]] ||
  fail "a feature without a record was counted"

# A comparison names what differs in versions and models, and a before and
# after report claims no cause.
repo="$(setup_repo compare)"
run_file "$repo" c1 20 run-feature.sh 1000 2000 0 aaa model-old
run_file "$repo" c2 21 run-feature.sh 200000 200500 0 bbb model-new
markdown="$(report "$repo" 20 21)"
grep -Fq -- "- template: feature 20 aaa; feature 21 bbb" <<<"$markdown" || fail "the comparison does not name the template versions"
grep -Fq -- "- models: feature 20 codex/model-old; feature 21 codex/model-new" <<<"$markdown" || fail "the comparison does not name the models"
grep -Fq "no evidence that a version, a prompt, or a model caused it" <<<"$markdown" || fail "the comparison claims a cause"
split_day="$(jq -rn '100000 | todate | .[0:10]')"
markdown="$(report "$repo" --all --split "$split_day")"
grep -Fq "| before | 1 | 16m 40s |" <<<"$markdown" || fail "the series before the split is wrong"
grep -Fq "| after | 1 | 8m 20s |" <<<"$markdown" || fail "the series after the split is wrong"
grep -Fq "no evidence that a version, a prompt, or a model caused it" <<<"$markdown" || fail "the before and after report claims a cause"
# A subject with a run without an end has an elapsed time of at least its
# measured runs, in the comparison too, and is left out of the means of
# elapsed time.
run_file "$repo" c3 22 run-feature.sh 300000 300100 0 bbb model-new
run_file "$repo" c4 22 run-feature.sh 300200 - 0 bbb model-new
markdown="$(report "$repo" 20 22)"
grep -Fq "| feature 22 | at least 1m 40s (1 runs without an end) |" <<<"$markdown" ||
  fail "the comparison shows an incomplete elapsed time as complete"
markdown="$(report "$repo" --all --split "$split_day")"
grep -Fq "| after | 2 | 8m 20s |" <<<"$markdown" || fail "a feature with a run without an end is in the mean of elapsed time"
grep -Fq "Means of elapsed time leave out the features with runs without an end (before: 0, after: 1)." <<<"$markdown" ||
  fail "the features left out of the mean of elapsed time are not counted"
grep -Fq "| Elapsed time | ≥ 1m 40s (1 runs without an end) |" <<<"$(report "$repo" --github-summary 22)" ||
  fail "the GitHub summary shows an incomplete elapsed time as complete"
rm -f "$repo/.agents/run/records/c3.jsonl" "$repo/.agents/run/records/c4.jsonl"
# A period selects runs by their start.
[[ "$(report "$repo" --all --since "$split_day" --json | jq -c '[.subjects[].subject]')" == '["21"]' ]] ||
  fail "--since did not select by the start of the runs"
if report "$repo" 20 --since 2026-13-01 >/dev/null 2>&1; then fail "an invalid date was accepted"; fi

# The summary for GitHub is built from numbers only: a path, a time of day, an
# error text, and an odd model name in the records do not reach it.
repo="$(setup_repo summary)"
file="$repo/.agents/run/records/s1.jsonl"
event "$file" s1 1000 run-start '{"kind":"feature","subject":"30","command":"/home/someone/secret/run-feature.sh","seq":1,"versions":{"template":"/home/someone/secret"}}'
event "$file" s1 1010 step '{"id":"1","name":"review at 13:45:07 /home/someone/secret","status":1,"seconds":5}'
event "$file" s1 1020 note '{"step":"review","outcome":"failed","reason":"Error: token sk-SECRET expired at 13:45:07","action":"/home/someone/secret"}'
event "$file" s1 1030 agent-call '{"role":"reviewer","agent":"codex","model":"/home/someone/secret model","status":0,"seconds":5,"usage":{"source":"codex-events","total_input":900,"output_tokens":9}}'
event "$file" s1 1040 agent-call '{"role":"Error: boom","agent":"codex","model":"gpt-x","status":1,"seconds":5,"usage":{"source":"unavailable"}}'
event "$file" s1 1050 intervention '{"what":"approved at 13:45:07 in /home/someone/secret"}'
event "$file" s1 1060 run-end '{"status":0}'
summary="$(report "$repo" --github-summary 30)"
for leak in /home someone secret 13:45 Error sk-SECRET "$(jq -rn '1000 | todate')"; do
  if grep -Fq -- "$leak" <<<"$summary"; then
    printf '%s\n' "$summary" >&2
    fail "the GitHub summary holds '$leak'"
  fi
done
grep -Fq "<!-- run-records-summary -->" <<<"$summary" || fail "the summary lacks its marker"
grep -Fq "| reviewer | other | 1 | 900 | 9 |" <<<"$summary" || fail "the summary lacks the tokens of the reviewer"
grep -Fq "| other | gpt-x | 1 | unknown | unknown |" <<<"$summary" || fail "an unknown figure in the summary is not unknown"
if report "$repo" --github-summary 31 >/dev/null 2>&1; then fail "a summary of a feature without a record succeeded"; fi

# A line that is not JSON hides nothing else.
printf 'not json\n' >>"$file"
[[ "$(report "$repo" 30 --json | jq '.subjects[0].runs.total')" -eq 1 ]] || fail "a damaged line hid the report"

# Calls of an agent and model that agents.conf does not declare, such as the
# fake calls of the self-tests in old records, are named once per run and
# left out of every total: the report equals the one of the same record
# without them. A call that --agent and --model selected is declared by its
# record.
undeclared_record() {
  local file="$1/.agents/run/records/$2.jsonl"
  event "$file" "$2" 1000 run-start '{"kind":"feature","subject":"50","command":"run-feature.sh","seq":1,"versions":{}}'
  event "$file" "$2" 1010 agent-call '{"role":"implementer","agent":"claude","model":"fable","status":0,"seconds":300,"level":"high","selection":"level-line","usage":{"source":"claude-json","total_input":5000,"output_tokens":50}}'
  event "$file" "$2" 1020 agent-call '{"role":"reviewer","agent":"codex","model":"gpt-real","status":0,"seconds":100,"level":"high","selection":"plain-line","usage":{"source":"codex-events","total_input":1000,"output_tokens":10}}'
  event "$file" "$2" 1030 agent-call '{"role":"implementer","agent":"claude","model":"chosen-by-hand","status":0,"seconds":20,"level":"high","selection":"command-line","usage":{"source":"claude-json","total_input":200,"output_tokens":2}}'
  if [[ "$3" == "with-fakes" ]]; then
    event "$file" "$2" 1040 agent-call '{"role":"reviewer","agent":"codex","model":"model-a","status":0,"seconds":1,"usage":{"source":"codex-events","total_input":null,"output_tokens":null}}'
    event "$file" "$2" 1041 agent-call '{"role":"reviewer","agent":"codex","model":"model-a","status":0,"seconds":1,"level":"high","selection":"plain-line","usage":{"source":"unavailable"}}'
    event "$file" "$2" 1042 agent-call '{"role":"triage","agent":"claude","model":"model-b","status":0,"seconds":1,"usage":{"source":"unavailable"}}'
    event "$file" "$2" 1043 agent-call '{"role":"triage-implementer","agent":"claude","model":"model-b","status":0,"seconds":1,"usage":{"source":"unavailable"}}'
    # Declared model, other agent: the pair is what counts.
    event "$file" "$2" 1044 agent-call '{"role":"reviewer","agent":"claude","model":"gpt-real","status":0,"seconds":1,"usage":{"source":"unavailable"}}'
    event "$file" "$2" 1045 agent-start '{"id":"f1","role":"reviewer","profile":"read-only","agent":"codex","model":"model-a"}'
  fi
  event "$file" "$2" 1100 run-end '{"status":0}'
}
for variant in clean with-fakes; do
  repo="$(setup_repo "undeclared-$variant")"
  printf '# comment\nimplementer: claude opus\nimplementer@high: claude fable\nreviewer: codex gpt-real\n' >"$repo/.agents/agents.conf"
  undeclared_record "$repo" w1 "$variant"
done
clean="$tmp/undeclared-clean"
fakes="$tmp/undeclared-with-fakes"
json="$(report "$fakes" 50 --json)"
totals='.subjects[0] | del(.undeclared)'
[[ "$(jq -c "$totals" <<<"$json")" == "$(report "$clean" 50 --json | jq -c "$totals")" ]] ||
  fail "undeclared calls count in the totals: $(jq -c "$totals" <<<"$json")"
[[ "$(jq -c '.subjects[0] | [.agent_seconds, .rounds.review, .rounds.triage, .rounds.repair, .input.sum, .unfinished_calls]' <<<"$json")" == "[420,1,0,0,6200,0]" ]] ||
  fail "the totals without the undeclared calls are wrong: $(jq -c '.subjects[0]' <<<"$json")"
[[ "$(jq -c '.subjects[0].undeclared | [.calls, .models, (.runs | length)]' <<<"$json")" == '[6,["gpt-real","model-a","model-b"],1]' ]] ||
  fail "the JSON does not carry the undeclared calls: $(jq -c '.subjects[0].undeclared' <<<"$json")"
warning="run w1: 6 calls of undeclared models gpt-real, model-a, model-b; left out of the totals"
[[ "$(jq -c '.warnings' <<<"$json")" == "$(jq -cn --arg w "$warning" '[$w]')" ]] ||
  fail "the JSON does not carry the warning: $(jq -c '.warnings' <<<"$json")"
markdown="$(report "$fakes" 50)"
grep -Fxq -- "- $warning" <<<"$markdown" || fail "the Markdown does not show the warning of the JSON"
[[ "$(grep -c "of undeclared models" <<<"$markdown")" -eq 2 ]] || fail "the warning is not shown once per run and once in the table"
grep -Fq "| Left out | 6 calls of undeclared models gpt-real, model-a, model-b in 1 runs (see Warnings) |" <<<"$markdown" ||
  fail "the table of the feature does not note the calls left out"
[[ "$(grep -v -e "of undeclared models" -e "^Warnings: " <<<"$markdown" | cat -s)" == "$(report "$clean" 50 | cat -s)" ]] ||
  fail "the Markdown counts the undeclared calls"
[[ "$(report "$fakes" --github-summary 50)" == "$(report "$clean" --github-summary 50)" ]] ||
  fail "the GitHub summary counts the undeclared calls"
# The call selected on the command line is counted and is no warning.
[[ "$(jq -c '.subjects[0].levels | map(select(.model == "chosen-by-hand")) | map(.calls)' <<<"$json")" == "[1]" ]] ||
  fail "a call selected on the command line was left out"
if grep -Fq "chosen-by-hand" <<<"$(jq -c '.warnings, .subjects[0].undeclared' <<<"$json")"; then
  fail "a call selected on the command line is a warning"
fi
[[ "$(report "$clean" 50 --json | jq -c '[has("warnings"), (.subjects[0] | has("undeclared"))]')" == "[false,false]" ]] ||
  fail "a record without undeclared calls has a warning"
if grep -q "Warnings\|Left out" <<<"$(report "$clean" 50)"; then
  fail "a record without undeclared calls shows a warning"
fi

[[ ! -e "$tmp/network" ]] || fail "the report called the network"

echo "report-runs tests passed"
