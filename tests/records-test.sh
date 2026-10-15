#!/usr/bin/env bash

set -euo pipefail

# The run records: what a run writes, how runs of one subject come together,
# and that recording never changes the outcome of the work.

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/records-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "records test failed: $*" >&2
  exit 1
}

# The test starts outside any run, also when a run is going on around it.
unset RECORDS_RUN_ID RECORDS_FILE RECORDS_COMMAND RECORDS_KIND RECORDS_SUBJECT RECORDS_VERIFICATION RECORDS_DISABLED

source "$source_root/tests/lib-fakes.sh"
make_fake_agents "$tmp/bin"

# A repository whose .gitignore is the template's, with the workflow.
setup_repo() {
  local repo="$tmp/$1"

  mkdir -p "$repo"
  copy_workflow "$repo"
  cp "$source_root/.gitignore" "$repo/.gitignore"
  printf 'commit: 0123456789abcdef0123456789abcdef01234567\n' >"$repo/.agents/template.conf"
  printf 'implementer: claude model-i\n' >"$repo/.agents/agents.conf"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.name "Records Test"
  git -C "$repo" config user.email "records-test@example.com"
  git -C "$repo" remote add origin "https://token@github.com/example/project.git"
  git -C "$repo" add .
  git -C "$repo" commit -qm "Seed"
  printf '%s\n' "$repo"
}

# in_repo <repo> <commands>: runs commands with the library, outside any run.
in_repo() {
  (
    cd "$1"
    unset RECORDS_RUN_ID RECORDS_FILE RECORDS_COMMAND RECORDS_KIND RECORDS_SUBJECT RECORDS_VERIFICATION RECORDS_DISABLED
    export PATH="$tmp/bin:$PATH"
    source scripts/lib/records.sh
    eval "$2"
  )
}

lines() {
  cat "$1"/.agents/run/records/*.jsonl 2>/dev/null
}

# A run: its start with the subject, the versions and the repository without
# credentials, its events, and its end.
repo="$(setup_repo basic)"
in_repo "$repo" 'records_begin feature 12 run-feature.sh; records_step "review, round 1" 0 42
  records_wait "review, round 1" 120; records_verification 0 61 false all
  records_intervention "approved the triage of a review"; records_note "implementation" "not complete" "partial" "Resuming"
  records_end 0'
[[ "$(ls "$repo/.agents/run/records" | grep -c .)" -eq 1 ]] || fail "a run did not write exactly one file"
lines "$repo" | jq -e -s 'all(.schema == "run-record/v1" and (.run | length > 0) and (.time | test("Z$")) and (.epoch | type) == "number")' >/dev/null ||
  fail "an event lacks its common fields"
[[ "$(lines "$repo" | jq -r -s 'map(.type) | join(",")')" == "run-start,step,wait,verification,intervention,note,experience,run-end" ]] ||
  fail "the events of a run are not in order: $(lines "$repo" | jq -r -s 'map(.type) | join(",")')"
start="$(lines "$repo" | jq -c 'select(.type == "run-start")')"
[[ "$(jq -r '.kind, .subject, .command' <<<"$start" | tr '\n' ' ')" == "feature 12 run-feature.sh " ]] || fail "the start does not name the subject: $start"
[[ "$(jq -r '.repository' <<<"$start")" == "example/project" ]] || fail "the repository is not owner/name: $start"
if grep -q "token" <<<"$start"; then fail "the credentials of the remote reached the record"; fi
[[ "$(jq -r '.versions.template' <<<"$start")" == "0123456789abcdef0123456789abcdef01234567" ]] || fail "the template version is missing"
[[ "$(jq -r '.versions.prompts | length' <<<"$start")" -eq 40 ]] || fail "the version of the prompts is missing"
[[ "$(jq -r '.versions.agents_conf | length' <<<"$start")" -eq 40 ]] || fail "the version of agents.conf is missing"
[[ "$(jq -r '.previous' <<<"$start")" == "null" ]] || fail "a first run names a previous one"
[[ "$(lines "$repo" | jq -r 'select(.type == "run-end") | .status')" == "0" ]] || fail "the end does not carry the status"
[[ "$(lines "$repo" | jq -r 'select(.type == "verification") | "\(.status) \(.seconds) \(.reused) \(.groups)"')" == "0 61 false all" ]] ||
  fail "the verification is not recorded"

# A second run of the same subject names the first; it gets a file of its
# own and nothing of the first is overwritten.
first_run="$(jq -r '.run' <<<"$start")"
in_repo "$repo" 'records_begin feature 12 start-feature.sh; records_end 1'
[[ "$(ls "$repo/.agents/run/records" | grep -c .)" -eq 2 ]] || fail "a second run did not get its own file"
[[ "$(lines "$repo" | jq -r -s '[.[] | select(.type == "run-start" and .command == "start-feature.sh")][0].previous')" == "$first_run" ]] ||
  fail "a resumed run does not name the run before it"
# A command inside a run belongs to it: no run of its own, nothing counted twice.
in_repo "$repo" 'records_begin feature 12 run-feature.sh; records_begin feature 12 review-feature.sh
  records_step inner 0 1; records_end 0'
[[ "$(ls "$repo/.agents/run/records" | grep -c .)" -eq 3 ]] || fail "a command inside a run started a run of its own"
# Outside a run nothing is written.
in_repo "$repo" 'records_step outside 0 1; records_intervention outside'
if lines "$repo" | grep -q '"outside"'; then fail "an event outside a run was written"; fi

# A planning cycle is recorded like a feature, by its name.
in_repo "$repo" 'records_begin planning final-curriculum review-planning.sh; records_end 0'
[[ "$(lines "$repo" | jq -r 'select(.type == "run-start" and .kind == "planning") | .subject')" == "final-curriculum" ]] ||
  fail "a planning run is not recorded by its name"

# The runs of a subject come together in .agents/records/, in the order in
# which they were written, without the runs of another subject. A later copy
# replaces the file and loses no run of an earlier one.
in_repo "$repo" 'records_begin feature 13 run-feature.sh; records_end 0'
in_repo "$repo" 'records_consolidate feature 12'
copy="$repo/.agents/records/feature-12.jsonl"
[[ "$(jq -r -s '[.[] | select(.type == "run-start")] | length' "$copy")" -eq 3 ]] || fail "the copy does not hold the three runs of the feature"
if jq -e -s 'any(.subject? == "13")' "$copy" >/dev/null; then fail "the copy holds a run of another feature"; fi
jq -e -s '[.[].epoch] == ([.[].epoch] | sort)' "$copy" >/dev/null || fail "the copy is not in the order of writing"
in_repo "$repo" 'records_begin feature 12 publish-feature.sh; records_end 0; records_consolidate feature 12'
[[ "$(jq -r -s '[.[] | select(.type == "run-start")] | length' "$copy")" -eq 4 ]] || fail "a later copy lost a run"
git -C "$repo" check-ignore -q ".agents/records/feature-12.jsonl" || fail "Git does not ignore the copy"
git -C "$repo" check-ignore -q ".agents/run/records/x.jsonl" || fail "Git does not ignore the run files"
# A run whose file is gone stays in the copy, and a later run is added to it.
# A copy that cannot be read is left as it is.
mkdir "$tmp/gone" && cp "$repo"/.agents/run/records/*.jsonl "$tmp/gone/"
rm -f "$repo"/.agents/run/records/*.jsonl
in_repo "$repo" 'records_consolidate feature 12'
[[ "$(jq -r -s '[.[] | select(.type == "run-start")] | length' "$copy")" -eq 4 ]] || fail "a copy without the run files lost runs"
in_repo "$repo" 'records_begin feature 12 publish-feature.sh; records_end 0; records_consolidate feature 12'
[[ "$(jq -r -s '[.[] | select(.type == "run-start")] | length' "$copy")" -eq 5 ]] || fail "a later run was not added to a copy of runs without files"
[[ "$(jq -r -s '[.[] | select(.type == "run-start") | .run] | unique | length' "$copy")" -eq 5 ]] || fail "a run is twice in the copy"
cp "$copy" "$tmp/copy-before"
printf 'not json\n' >>"$copy"
cp "$copy" "$tmp/copy-damaged"
if in_repo "$repo" 'records_consolidate feature 12' 2>/dev/null; then fail "a copy that cannot be read was replaced"; fi
cmp -s "$copy" "$tmp/copy-damaged" || fail "a copy that cannot be read was changed"
cp "$tmp/copy-before" "$copy"
cp "$tmp/gone"/*.jsonl "$repo/.agents/run/records/"
in_repo "$repo" 'records_consolidate planning final-curriculum'
[[ -s "$repo/.agents/records/planning-final-curriculum.jsonl" ]] || fail "a planning was not copied by its name"

# From a worktree the runs go to the primary checkout, so that they survive
# the removal of the worktree.
git -C "$repo" worktree add -q -b feature/14-thing "$tmp/basic-14" >/dev/null 2>&1
in_repo "$tmp/basic-14" 'records_begin feature 14 run-feature.sh; records_end 0'
[[ ! -d "$tmp/basic-14/.agents/run/records" ]] || fail "a run in a worktree wrote into the worktree"
lines "$repo" | jq -e -s 'any(.type == "run-start" and .subject == "14")' >/dev/null || fail "a run in a worktree did not reach the primary checkout"
in_repo "$tmp/basic-14" 'records_consolidate feature 14'
[[ -s "$repo/.agents/records/feature-14.jsonl" ]] || fail "a copy made from a worktree is not in the primary checkout"

# Parallel runs, and parallel writers in one run, lose nothing.
repo="$(setup_repo parallel)"
for n in 1 2 3 4 5 6 7 8; do
  in_repo "$repo" "records_begin feature $n run-feature.sh
    for i in \$(seq 1 25); do records_step \"step \$i\" 0 1 & done; wait; records_end 0" &
done
wait
[[ "$(ls "$repo/.agents/run/records" | grep -c .)" -eq 8 ]] || fail "parallel runs did not get a file each"
[[ "$(lines "$repo" | grep -c .)" -eq $((8 * 28)) ]] || fail "parallel writers lost events: $(lines "$repo" | grep -c .) of $((8 * 28))"
lines "$repo" | jq -e . >/dev/null || fail "parallel writers produced a line that is not JSON"

# Runs of one subject that start in the same second follow each other by
# their sequence number, not by their ids, which a random part orders by
# chance; runs that start at once still get a number each.
mkdir -p "$tmp/same-second"
cat >"$tmp/same-second/date" <<'DATE'
#!/usr/bin/env bash
case "$*" in
  *%s*) echo 1700000000 ;;
  *%Y%m%dT*) echo 20231114T221320Z ;;
  *) echo 2023-11-14T22:13:20Z ;;
esac
DATE
chmod +x "$tmp/same-second/date"
repo="$(setup_repo same-second)"
for n in 1 2 3 4 5 6 7 8; do
  in_repo "$repo" 'export PATH="'"$tmp/same-second"':$PATH"; records_begin feature 12 run-feature.sh; records_end 1'
done
chain() {
  lines "$1" | jq -r -s '[.[] | select(.type == "run-start")] | sort_by(.seq)
    | [range(1; length) as $i | .[$i].previous == .[$i - 1].run] | all'
}
[[ "$(lines "$repo" | jq -r -s '[.[] | select(.type == "run-start") | .seq] | sort | map(tostring) | join(",")')" == "1,2,3,4,5,6,7,8" ]] ||
  fail "runs in the same second did not get successive sequence numbers"
[[ "$(chain "$repo")" == "true" ]] || fail "a run in the same second does not name the run just before it"
repo="$(setup_repo same-second-parallel)"
for n in 1 2 3 4 5 6; do
  in_repo "$repo" 'export PATH="'"$tmp/same-second"':$PATH"; records_begin feature 12 run-feature.sh; records_end 0' &
done
wait
[[ "$(lines "$repo" | jq -r -s '[.[] | select(.type == "run-start") | .seq] | sort | map(tostring) | join(",")')" == "1,2,3,4,5,6" ]] ||
  fail "runs that start at once got the same sequence number"
[[ "$(chain "$repo")" == "true" ]] || fail "runs that start at once do not form one line of runs"
# A run that was killed right after it took its number leaves only its link,
# no lock: the next run takes the next number and names it.
ln -s killed-run "$repo/.agents/run/records/.sequence/feature-12/7"
in_repo "$repo" 'records_begin feature 12 run-feature.sh; records_end 0'
[[ "$(lines "$repo" | jq -r -s '[.[] | select(.type == "run-start")] | max_by(.seq) | "\(.seq) \(.previous)"')" == "8 killed-run" ]] ||
  fail "a run after a killed start did not take the next number"
# Without a number the run is still recorded, names no previous run, and
# the failure is reported.
repo="$(setup_repo no-sequence)"
mkdir -p "$repo/.agents/run/records/.sequence"
chmod 0555 "$repo/.agents/run/records/.sequence"
in_repo "$repo" 'records_begin feature 12 run-feature.sh 2>"'"$tmp/no-sequence.err"'"; records_end 0'
chmod 0755 "$repo/.agents/run/records/.sequence"
[[ "$(lines "$repo" | jq -r 'select(.type == "run-start") | "\(.seq) \(.previous)"')" == "null null" ]] ||
  fail "a run without a number is not recorded as one"
grep -Fq "got no number" "$tmp/no-sequence.err" || fail "a run without a number was not reported"

# A script that records itself: the end carries its status; an interrupted
# one ends with 130; one that is killed has no end and stays incomplete.
repo="$(setup_repo wrapped)"
cat >"$repo/scripts/sample.sh" <<'SAMPLE'
#!/usr/bin/env bash
set -euo pipefail
records_arguments=("$@")
source "$(dirname "$0")/lib/records.sh"
records_wrap feature 21 "$0" ${records_arguments[@]+"${records_arguments[@]}"}
records_intervention "saw: $*"
case "${1:-}" in
  fail) exit 7 ;;
  sleep) sleep 30 ;;
esac
SAMPLE
chmod +x "$repo/scripts/sample.sh"
status=0
(cd "$repo" && unset RECORDS_RUN_ID && ./scripts/sample.sh fail "two words") || status=$?
[[ "$status" -eq 7 ]] || fail "a script that records itself did not keep its exit status ($status)"
lines "$repo" | jq -e -s 'any(.type == "intervention" and .what == "saw: fail two words")' >/dev/null ||
  fail "the script did not get its arguments as given"
[[ "$(lines "$repo" | jq -r 'select(.type == "run-end") | .status')" == "7" ]] || fail "the end does not carry the status of the script"
rm -rf "$repo/.agents/run/records"
(cd "$repo" && unset RECORDS_RUN_ID && exec ./scripts/sample.sh sleep) &
runner=$!
for _ in $(seq 1 50); do lines "$repo" | grep -q '"intervention"' && break; sleep 0.1; done
# A background job ignores SIGINT, so the test interrupts with SIGTERM, which
# the run treats the same.
pkill -TERM -f "scripts/sample.sh sleep" 2>/dev/null || true
wait "$runner" 2>/dev/null || true
[[ "$(lines "$repo" | jq -r 'select(.type == "run-end") | .status')" == "130" ]] || fail "an interrupted run does not end with 130"
rm -rf "$repo/.agents/run/records"
(cd "$repo" && unset RECORDS_RUN_ID && exec ./scripts/sample.sh sleep) &
runner=$!
for _ in $(seq 1 50); do lines "$repo" | grep -q '"intervention"' && break; sleep 0.1; done
kill -KILL "$runner" 2>/dev/null || true
pkill -KILL -f "scripts/sample.sh sleep" 2>/dev/null || true
wait "$runner" 2>/dev/null || true
if lines "$repo" | jq -e -s 'any(.type == "run-end")' >/dev/null 2>&1; then fail "a killed run has an end"; fi
lines "$repo" | jq -e -s 'any(.type == "run-start")' >/dev/null || fail "a killed run lost its start"

# Recording never changes the outcome: an unwritable directory gives a
# warning and the script goes on with its own status.
repo="$(setup_repo unwritable)"
mkdir -p "$repo/.agents/run/records"
chmod 500 "$repo/.agents/run/records"
status=0
(cd "$repo" && unset RECORDS_RUN_ID && ./scripts/sample.sh fail 2>"$tmp/warn" || exit $?) 2>/dev/null || status=$?
cp "$tmp/wrapped/scripts/sample.sh" "$repo/scripts/sample.sh"
status=0
(cd "$repo" && unset RECORDS_RUN_ID && ./scripts/sample.sh fail) 2>"$tmp/warn" || status=$?
chmod 700 "$repo/.agents/run/records"
[[ "$status" -eq 7 ]] || fail "an unwritable record changed the exit status ($status)"
grep -Fq "the run record could not be written" "$tmp/warn" || fail "an unwritable record was not reported"

# A primary checkout that ignores .agents/run/ but not yet .agents/records/,
# as before a sync: the runs are recorded, but the copy cannot be made safely,
# so it fails, which keeps a worktree in cleanup-worktree.sh. A subject without
# a run needs no copy.
repo="$(setup_repo half-ignored)"
grep -Ev '^\.agents/records/$' "$repo/.gitignore" >"$tmp/gitignore" && cp "$tmp/gitignore" "$repo/.gitignore"
in_repo "$repo" 'records_begin feature 12 run-feature.sh; records_end 0'
status=0
in_repo "$repo" 'records_consolidate feature 12' 2>"$tmp/half" || status=$?
[[ "$status" -ne 0 ]] || fail "a copy that cannot be made safely was reported as made"
grep -Fq "cannot be copied to .agents/records/" "$tmp/half" || fail "the reason was not given"
[[ ! -e "$repo/.agents/records/feature-12.jsonl" ]] || fail "a copy was written that Git does not ignore"
in_repo "$repo" 'records_consolidate feature 99' || fail "a subject without a run failed its copy"

# A run file that cannot be read leaves an existing copy as it was.
repo="$(setup_repo unreadable-run)"
in_repo "$repo" 'records_begin feature 12 run-feature.sh; records_end 0; records_consolidate feature 12'
before="$(cat "$repo/.agents/records/feature-12.jsonl")"
printf '{"type": "run-start", broken\n' >"$repo/.agents/run/records/other.jsonl"
status=0
in_repo "$repo" 'records_consolidate feature 12' 2>"$tmp/unreadable" || status=$?
[[ "$status" -ne 0 ]] || fail "a copy over a malformed run file was reported as made"
[[ "$(cat "$repo/.agents/records/feature-12.jsonl")" == "$before" ]] || fail "a malformed run file changed the existing copy"
grep -Fq "other.jsonl cannot be read" "$tmp/unreadable" || fail "the malformed run file was not named"
rm "$repo/.agents/run/records/other.jsonl"
printf '{"type": "run-start"}\n' >"$repo/.agents/run/records/locked.jsonl"
chmod 000 "$repo/.agents/run/records/locked.jsonl"
status=0
in_repo "$repo" 'records_consolidate feature 12' 2>/dev/null || status=$?
chmod 644 "$repo/.agents/run/records/locked.jsonl"
[[ "$status" -ne 0 ]] || fail "a copy over an unreadable run file was reported as made"
[[ "$(cat "$repo/.agents/records/feature-12.jsonl")" == "$before" ]] || fail "an unreadable run file changed the existing copy"

# Without the ignore rule nothing is recorded or copied: a record must never
# become part of what is committed.
repo="$(setup_repo not-ignored)"
grep -Ev '^\.agents/(run|records)/$' "$repo/.gitignore" >"$tmp/gitignore" && cp "$tmp/gitignore" "$repo/.gitignore"
in_repo "$repo" 'records_begin feature 12 run-feature.sh 2>"'"$tmp/note"'"; records_end 0; records_consolidate feature 12 2>>"'"$tmp/note"'"'
[[ ! -d "$repo/.agents/run/records" && ! -d "$repo/.agents/records" ]] || fail "records were written although Git does not ignore them"
grep -Fq "no run record is kept" "$tmp/note" || fail "the missing ignore rule was not reported"

# Usage, as each provider reports it. A figure it did not report is null,
# never zero; cache fields keep their meaning and are not counted twice.
repo="$(setup_repo usage)"
out="$tmp/claude.md"
printf '%s\n' '{"type": "result", "is_error": false, "result": "done", "usage": {"input_tokens": 10, "output_tokens": 200, "cache_creation_input_tokens": 1000, "cache_read_input_tokens": 5000}}' >"$out.envelope"
usage="$(in_repo "$repo" "records_usage claude unattended '$out'")"
[[ "$(jq -r '.source, .input_tokens, .output_tokens, .cache_creation_input_tokens, .cache_read_input_tokens, .total_input' <<<"$usage" | tr '\n' ' ')" == "claude-result 10 200 1000 5000 6010 " ]] ||
  fail "the Claude usage was not read as the provider reports it: $usage"
printf '%s\n' '{"type": "result", "is_error": false, "result": "done", "usage": {"input_tokens": 10, "output_tokens": 20}}' >"$out.envelope"
usage="$(in_repo "$repo" "records_usage claude read-only '$out'")"
[[ "$(jq -r '.cache_read_input_tokens' <<<"$usage")" == "null" ]] || fail "a cache figure Claude did not report is not null: $usage"
out="$tmp/codex.md"
printf '%s\n' '{"type": "thread.started"}' '{"type": "turn.completed", "usage": {"input_tokens": 1000, "cached_input_tokens": 800, "output_tokens": 50}}' \
  '{"type": "turn.completed", "usage": {"input_tokens": 500, "cached_input_tokens": 400, "output_tokens": 25}}' >"$out.events"
usage="$(in_repo "$repo" "records_usage codex read-only '$out'")"
[[ "$(jq -r '.source, .input_tokens, .cached_input_tokens, .output_tokens, .total_input' <<<"$usage" | tr '\n' ' ')" == "codex-events 1500 1200 75 1500 " ]] ||
  fail "the Codex usage was not added up as the provider reports it: $usage"
# A line that is not JSON among the events does not hide the usage.
printf '%s\n' 'warning: something on the way' '{"type": "turn.completed", "usage": {"input_tokens": 7, "cached_input_tokens": 0, "output_tokens": 3}}' >"$out.events"
[[ "$(in_repo "$repo" "records_usage codex unattended '$out'" | jq -r '.input_tokens, .output_tokens' | tr '\n' ' ')" == "7 3 " ]] ||
  fail "a line that is not JSON hid the usage of a Codex session"
# A completed turn without usage, or with null usage, counts as a turn that
# reported nothing: the call has no totals, only partial sums.
for missing in '{"type": "turn.completed"}' '{"type": "turn.completed", "usage": null}'; do
  printf '%s\n' '{"type": "turn.completed", "usage": {"input_tokens": 100, "cached_input_tokens": 10, "output_tokens": 5}}' "$missing" >"$out.events"
  usage="$(in_repo "$repo" "records_usage codex read-only '$out'")"
  [[ "$(jq -r '.turns, .turns_without_usage, .input_tokens, .output_tokens, .partial.input_tokens, .partial.output_tokens' <<<"$usage" | tr '\n' ' ')" == "2 1 null null 100 5 " ]] ||
    fail "a turn without usage was left out of the totals: $missing: $usage"
done
[[ "$(in_repo "$repo" "records_usage claude write /nonexistent" | jq -r '.source')" == "interactive" ]] ||
  fail "a session in the human's terminal is not recorded as interactive"
[[ "$(in_repo "$repo" "records_usage codex read-only '$tmp/none.md'" | jq -c .)" == '{"source":"unavailable"}' ]] ||
  fail "missing usage is not unavailable"
for broken in 'not json' '{"usage": "many"}'; do
  printf '%s\n' "$broken" >"$tmp/broken.md.envelope"
  [[ "$(in_repo "$repo" "records_usage claude unattended '$tmp/broken.md'" | jq -r '.source')" == "unavailable" ]] ||
    fail "usage that cannot be read is not unavailable: $broken"
done

# An unattended Codex call through the adapter: its events go apart from what
# it writes on standard error, so a diagnostic there does not hide the usage.
in_repo "$repo" 'rm -rf .agents/run/records; records_begin feature 12 start-feature.sh
  source scripts/lib/agent.sh
  agent_resolve . implementer codex model-c
  MOCK_AGENT_LOG="'"$tmp/codex.log"'" MOCK_OUTPUT="done" MOCK_AGENT_ACTION="echo \"warning: a diagnostic\" >&2; echo \"{\\\"type\\\": \\\"turn.completed\\\", \\\"usage\\\": {\\\"input_tokens\\\": 11, \\\"cached_input_tokens\\\": 1, \\\"output_tokens\\\": 2}}\"" \
    agent_run unattended codex model-c . "a prompt" "'"$tmp/codex-final.md"'" || true
  records_end 0'
call="$(lines "$repo" | jq -c 'select(.type == "agent-call" and .agent == "codex")')"
[[ "$(jq -r '.usage.source, .usage.input_tokens, .usage.output_tokens' <<<"$call" | tr '\n' ' ')" == "codex-events 11 2 " ]] ||
  fail "a diagnostic on standard error hid the usage of a Codex call: $call"
grep -Fq "warning: a diagnostic" "$tmp/codex-final.md.log" || fail "the diagnostic of a Codex call is not in its log"

# An agent call through the adapter: its role, agent, model, duration, and
# status, and nothing of the prompt or the answer.
in_repo "$repo" 'records_begin feature 12 start-feature.sh
  source scripts/lib/agent.sh
  agent_resolve . implementer "" ""
  MOCK_AGENT_LOG="'"$tmp/agent.log"'" MOCK_OUTPUT="ANSWER-TEXT" agent_run unattended claude model-i . "PROMPT-SECRET-TEXT" "'"$tmp/final.md"'" || true
  records_end 0'
call="$(lines "$repo" | jq -c 'select(.type == "agent-call" and .agent == "claude")')"
[[ "$(jq -r '.role, .profile, .agent, .model, .status, (.seconds | type), .usage.source' <<<"$call" | tr '\n' ' ')" == "implementer unattended claude model-i 0 number unavailable " ]] ||
  fail "the agent call is not recorded as expected: $call"
if lines "$repo" | grep -Eq "PROMPT-SECRET-TEXT|ANSWER-TEXT"; then fail "a prompt or an answer reached the record"; fi

# Usage that some turns of a call did not report: the field is null, never an
# incomplete sum, and what the other turns reported is kept under "partial".
repo="$(setup_repo usage-partial)"
out="$tmp/mixed.md"
printf '%s\n' '{"type": "turn.completed", "usage": {"input_tokens": 100, "cached_input_tokens": 10, "output_tokens": 5}}' \
  '{"type": "turn.completed", "usage": {"input_tokens": 200, "cached_input_tokens": 20}}' >"$out.events"
usage="$(in_repo "$repo" "records_usage codex read-only '$out'")"
[[ "$(jq -r '.input_tokens, .output_tokens, .partial.output_tokens, .turns' <<<"$usage" | tr '\n' ' ')" == "300 null 5 2 " ]] ||
  fail "an output figure that one turn did not report became a total: $usage"
[[ "$(jq -r '.partial | has("input_tokens")' <<<"$usage")" == "false" ]] || fail "a complete field is marked partial: $usage"
out="$tmp/claude-partial.md"
printf '%s\n' '{"type": "result", "is_error": false, "result": "done", "usage": {"input_tokens": 10, "output_tokens": 20, "cache_read_input_tokens": 5}}' >"$out.envelope"
[[ "$(in_repo "$repo" "records_usage claude unattended '$out'" | jq -r '.total_input')" == "null" ]] ||
  fail "a Claude total was computed although a cache figure is missing"

# Overlapping copies of one feature, while a run appends, leave a copy that
# holds every run and only whole lines, and no temporary file or lock.
repo="$(setup_repo overlapping)"
for n in 1 2 3; do in_repo "$repo" "records_begin feature 12 run-feature.sh; records_step 'step $n' 0 1; records_end 0"; done
in_repo "$repo" 'records_begin feature 12 run-feature.sh
  for i in $(seq 1 40); do records_step "late $i" 0 1; done
  records_end 0' &
writer=$!
for _ in 1 2 3 4 5 6; do in_repo "$repo" 'records_consolidate feature 12' & done
wait
wait "$writer" 2>/dev/null || true
in_repo "$repo" 'records_consolidate feature 12'
copy="$repo/.agents/records/feature-12.jsonl"
jq -e . "$copy" >/dev/null || fail "overlapping copies left a line that is not JSON"
[[ "$(jq -r -s '[.[] | select(.type == "run-start")] | length' "$copy")" -eq 4 ]] || fail "overlapping copies lost a run"
[[ "$(jq -r -s '[.[] | select(.type == "step" and (.name | startswith("late")))] | length' "$copy")" -eq 40 ]] ||
  fail "the last copy does not hold every event of the run that was appending"
[[ -z "$(find "$repo/.agents/records" -name '.*' -mindepth 1)" ]] || fail "a copy left a temporary file or a lock"

# The copy that a step of a run made is brought up to date at the end of the
# run, with its status.
repo="$(setup_repo copy-at-end)"
in_repo "$repo" 'records_begin feature 12 publish-feature.sh; records_consolidate feature 12; records_step "after the copy" 0 1; records_end 3'
[[ "$(jq -r -s 'map(.type) | join(",")' "$repo/.agents/records/feature-12.jsonl")" == "run-start,step,experience,run-end" ]] ||
  fail "the copy was not brought up to date at the end of the run"
[[ "$(jq -r -s '.[-1].status' "$repo/.agents/records/feature-12.jsonl")" == "3" ]] || fail "the copy lacks the status of the run"

# An agent call or a step that is interrupted leaves its start without its
# end, so that the record says what was going on.
repo="$(setup_repo interrupted-call)"
in_repo "$repo" 'records_begin feature 12 run-feature.sh; records_step_start s1 "review, round 1 of at most 5"
  records_agent_start c1 reviewer read-only codex model-r'
in_repo "$repo" 'export RECORDS_RUN_ID="$(basename .agents/run/records/*.jsonl .jsonl)" RECORDS_FILE="$(ls .agents/run/records/*.jsonl)"
  records_verification_start v1 all'
starts="$(lines "$repo" | jq -r -s '[.[] | select(.type == "agent-start" or .type == "step-start" or .type == "verification-start") | "\(.type):\(.id)"] | join(",")')"
[[ "$starts" == "step-start:s1,agent-start:c1,verification-start:v1" ]] || fail "the starts of a step, a call, and a verification are not recorded: $starts"
lines "$repo" | jq -e -s 'all(.type != "agent-call" and .type != "step")' >/dev/null || fail "an interrupted call has an end"
call="$(lines "$repo" | jq -c 'select(.type == "agent-start")')"
[[ "$(jq -r '.role, .agent, .model' <<<"$call" | tr '\n' ' ')" == "reviewer codex model-r " ]] || fail "the start of a call does not name it: $call"

# A verification run on its own, in a feature worktree, is a run of that
# feature; inside a run it belongs to that run.
# And a check that a verification runs is not part of that run: a workflow
# script that the check starts makes no event in it.
repo="$(setup_repo verify-alone)"
printf 'marker: true\n' >"$repo/scripts/verify.conf"
git -C "$repo" add scripts/verify.conf && git -C "$repo" commit -qm "A check"
git -C "$repo" switch -q -c feature/15-thing
(cd "$repo" && unset RECORDS_RUN_ID RECORDS_FILE && ./scripts/verify.sh >/dev/null) || fail "verification on its own failed"
[[ "$(lines "$repo" | jq -r -s 'map(.type) | join(",")')" == "run-start,verification-start,verification,run-end" ]] ||
  fail "a verification on its own is not a run of its feature: $(lines "$repo" | jq -r -s 'map(.type) | join(",")')"
[[ "$(lines "$repo" | jq -r 'select(.type == "run-start") | "\(.kind) \(.subject) \(.command)"')" == "feature 15 verify.sh" ]] ||
  fail "the verification run does not name its feature"
rm -rf "$repo/.agents/run/records"
in_repo "$repo" 'records_begin feature 15 review-feature.sh; ./scripts/verify.sh >/dev/null; records_end 0'
[[ "$(ls "$repo/.agents/run/records" | grep -c .)" -eq 1 ]] || fail "a verification inside a run started a run of its own"
lines "$repo" | jq -e -s 'any(.type == "verification" and .status == 0 and .groups == "all")' >/dev/null ||
  fail "a verification inside a run is not recorded in it"
rm -rf "$repo/.agents/run/records"
printf 'marker: true\nnested: ./scripts/sample-nested.sh\n' >"$repo/scripts/verify.conf"
printf '#!/usr/bin/env bash\nsource "$(dirname "$0")/lib/records.sh"\nrecords_intervention "from inside a check"\n' >"$repo/scripts/sample-nested.sh"
chmod +x "$repo/scripts/sample-nested.sh"
in_repo "$repo" 'records_begin feature 15 review-feature.sh; ./scripts/verify.sh >/dev/null; records_end 0'
if lines "$repo" | grep -q "from inside a check"; then fail "a check wrote into the run of the verification"; fi
printf 'marker: true\n' >"$repo/scripts/verify.conf"
# When its recording cannot be prepared, the verification runs all the same.
mkdir -p "$tmp/no-mktemp"
printf '#!/usr/bin/env bash\ncase "$*" in *verify-reused*) exit 1 ;; esac\nexec %s "$@"\n' "$(command -v mktemp)" >"$tmp/no-mktemp/mktemp"
chmod +x "$tmp/no-mktemp/mktemp"
rm -rf "$repo/.agents/run/records"
status=0
in_repo "$repo" 'export PATH="'"$tmp/no-mktemp"':$PATH"; records_begin feature 15 review-feature.sh; ./scripts/verify.sh >/dev/null; s=$?; records_end $s; exit $s' || status=$?
[[ "$status" -eq 0 ]] || fail "a verification whose recording could not be prepared did not pass ($status)"
in_repo "$repo" 'export PATH="'"$tmp/no-mktemp"':$PATH"; records_begin feature 15 review-feature.sh; ./scripts/verify.sh >/dev/null 2>"'"$tmp/verify-warn"'"; records_end 0' || true
grep -Fq "the record of this verification could not be prepared" "$tmp/verify-warn" ||
  fail "a verification whose recording could not be prepared did not say so"

# Recording and copying call GitHub for nothing: with a GitHub command that
# fails, a run and its copy are complete.
repo="$(setup_repo offline)"
mkdir -p "$tmp/offline-bin"
printf '#!/usr/bin/env bash\necho "gh: offline" >&2\nexit 1\n' >"$tmp/offline-bin/gh"
chmod +x "$tmp/offline-bin/gh"
in_repo "$repo" 'export PATH="'"$tmp/offline-bin"':$PATH"; records_begin feature 12 run-feature.sh
  records_step "review, round 1 of at most 5" 0 3; records_end 0; records_consolidate feature 12'
[[ "$(jq -r -s 'map(.type) | join(",")' "$repo/.agents/records/feature-12.jsonl")" == "run-start,step,experience,run-end" ]] ||
  fail "a run without GitHub is not complete"

echo "records tests passed"
