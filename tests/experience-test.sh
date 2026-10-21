#!/usr/bin/env bash

set -euo pipefail

# Experience records: what a script derives from a run without an agent, the
# optional notes of the agent and their validation, and that a record never
# changes the outcome of the work.

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/experience-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "experience test failed: $*" >&2
  exit 1
}

unset RECORDS_RUN_ID RECORDS_FILE RECORDS_COMMAND RECORDS_KIND RECORDS_SUBJECT RECORDS_VERIFICATION RECORDS_DISABLED

# Agents and the network that are called fail the test: a record costs no
# agent and no tokens.
mkdir -p "$tmp/bin"
for tool in claude codex gh curl; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"%s/called"\nexit 1\n' "$tool" "$tmp" >"$tmp/bin/$tool"
  chmod +x "$tmp/bin/$tool"
done

setup_repo() {
  local repo="$tmp/$1"

  mkdir -p "$repo/scripts/lib" "$repo/.agents/reviews" "$repo/.agents/triage" "$repo/docs/decisions"
  cp "$source_root/.gitignore" "$repo/.gitignore"
  cp "$source_root/scripts/show-experience.sh" "$repo/scripts/"
  cp "$source_root/scripts/lib/records.sh" "$source_root/scripts/lib/experience.sh" "$source_root/scripts/lib/fingerprint.sh" "$repo/scripts/lib/"
  printf '# ADR 001\n' >"$repo/docs/decisions/001-example.md"
  git -C "$repo" init -q -b feature/12-thing
  git -C "$repo" add -A
  git -C "$repo" -c user.name=Test -c user.email=test@example.com commit -qm "Seed"
  printf '%s\n' "$repo"
}

# in_run <repo> <status> <commands>: runs the commands as a run of feature 12
# that ends with the status.
in_run() {
  (
    cd "$1"
    export PATH="$tmp/bin:$PATH"
    source scripts/lib/records.sh
    records_begin feature 12 run-feature.sh
    eval "$3"
    records_end "$2"
  )
}

records() {
  cat "$1"/.agents/run/records/*.jsonl | jq -c 'select(.type == "experience") | .record'
}

# latest_record <repo>: the record of the run with the highest number; run
# ids that start in one second do not sort in the order of the runs.
latest_record() {
  cat "$1"/.agents/run/records/*.jsonl | jq -c -s '
    (map(select(.type == "run-start")) | max_by(.seq) | .run) as $run
    | map(select(.type == "experience" and .run == $run)) | first | .record'
}

show() {
  local repo="$1"
  shift
  (cd "$repo" && PATH="$tmp/bin:$PATH" ./scripts/show-experience.sh "$@")
}

# A review with a major finding that the triage fixed, and a minor finding
# without a triage; a verification that failed and then passed; the
# completion record. All written during the run.
write_round() {
  mkdir -p .agents/reviews .agents/triage
  cat >.agents/reviews/feature-12-thing-review-01.json <<'JSON'
{"schema": "review/v1", "issue": 12, "round": 1, "head": "abc123", "verdict": "CHANGES_REQUIRED",
 "findings": [
   {"id": "M1", "severity": "major", "title": "The parser drops the last line; token ghp_abcdefghijklmnopqrstuvwxyz0123", "evidence": "x", "impact": "y", "recommendation": "z"},
   {"id": "MIN1", "severity": "minor", "title": "A name is unclear", "evidence": "x", "impact": "y", "recommendation": "z"}]}
JSON
  cat >.agents/triage/feature-12-thing-review-01-triage.json <<'JSON'
{"schema": "triage/v1", "decisions": [{"finding_id": "M1", "severity": "major", "title": "The parser drops the last line", "decision": "FIX_NOW", "rationale": "r"}]}
JSON
  records_artifact review .agents/reviews/feature-12-thing-review-01.json
  records_artifact triage .agents/triage/feature-12-thing-review-01-triage.json
  records_verification 1 30 false all
  records_verification 0 30 false all
  mkdir -p .agents/completion
  printf '%s\n' '{"schema": "completion/v1", "status": "complete", "criteria": [{"criterion": "c", "status": "met", "evidence": "e"}], "remaining": []}' \
    >.agents/completion/12.json
}

# A completed run: the script derives its record, without an agent.
repo="$(setup_repo completed)"
in_run "$repo" 0 'write_round'
record="$(records "$repo")"
[[ "$(jq -c '[.schema, .issue, (.run | length > 0), (.code_version.commit | length == 40)]' <<<"$record")" == '["experience/v1",12,true,true]' ]] ||
  fail "the record is not linked to its run, Issue, and code version: $record"
[[ "$(jq -r '.run' <<<"$record")" == "$(cat "$repo"/.agents/run/records/*.jsonl | jq -r 'select(.type == "run-start") | .run')" ]] ||
  fail "the record names another run"
[[ "$(jq -c '.code_version.reviewed' <<<"$record")" == '["abc123"]' ]] || fail "the reviewed code version is missing"
[[ "$(jq -c '.derived | [.review_rounds, .findings, .decisions, .verification]' <<<"$record")" == '[1,{"major":1,"minor":1},{"FIX_NOW":1},{"runs":2,"failed":1,"repaired":1}]' ]] ||
  fail "the derived part is wrong: $(jq -c '.derived' <<<"$record")"
# Every fact has its evidence, or says that it is missing.
[[ "$(jq -c '.observations[] | select(.id == "review-1-M1") | [.kind, .evidence[].type, .result]' <<<"$record")" == '["fact","review","triage","triage decided FIX_NOW"]' ]] ||
  fail "a triaged finding lacks its evidence: $record"
[[ "$(jq -r '.observations[] | select(.id == "review-1-MIN1") | .missing_evidence' <<<"$record")" == "no triage of this finding during the run" ]] ||
  fail "a finding without a triage does not say that the evidence is missing"
jq -e '.observations | all(.kind != "fact" or ((.evidence | length) > 0) or (.missing_evidence != null))' <<<"$record" >/dev/null ||
  fail "a fact has no evidence"
jq -e '.observations | any(.id == "verification")' <<<"$record" >/dev/null || fail "the repaired verification is not observed"
jq -e '.agent.status == "absent"' <<<"$record" >/dev/null || fail "an absent agent part is not said so"
# What looks like a secret is not copied.
if grep -Fq "ghp_abcdefghij" <<<"$record"; then fail "a token reached the record"; fi
grep -Fq "[redacted]" <<<"$record" || fail "the token was not replaced"
[[ ! -e "$tmp/called" ]] || fail "deriving the record called an agent or the network: $(cat "$tmp/called")"
# Records change nothing of the repository: no ADR, prompt, or rule.
[[ -z "$(git -C "$repo" status --porcelain)" ]] || fail "making the record changed the repository: $(git -C "$repo" status --porcelain)"

# A blocked run gives a valid record too, with why it stopped.
repo="$(setup_repo blocked)"
in_run "$repo" 3 'printf "**Open questions:** which ADR?\n" >"$PWD/handoff.tmp"; mkdir -p .agents/handoffs; mv handoff.tmp .agents/handoffs/12.md
  records_note "implementation" "blocked" "the Issue contradicts ADR 001" "stopped"
  mkdir -p .agents/completion; printf "%s\n" "{\"schema\": \"completion/v1\", \"status\": \"blocked\", \"criteria\": [{\"criterion\": \"c\", \"status\": \"not_met\", \"evidence\": \"e\"}], \"remaining\": [\"all\"]}" >.agents/completion/12.json'
record="$(records "$repo")"
[[ "$(jq -c '.observations[] | select(.id == "stop") | [.what, .circumstances, [.evidence[].type]]' <<<"$record")" == '["The run stopped with status 3, for a decision of the human","implementation: the Issue contradicts ADR 001",["run-record","handoff"]]' ]] ||
  fail "the stop of a blocked run is not observed: $record"
jq -e '.observations | any(.id == "completion")' <<<"$record" >/dev/null || fail "a completion record that is not complete is not observed"
[[ "$(show "$repo" 12 --json | jq -c '[(.valid | length), (.invalid | length)]')" == "[1,0]" ]] || fail "the record of a blocked run is not valid"
if grep -Fq "which ADR" <<<"$record"; then fail "the handoff note was copied into the record"; fi

# A record that awaits evidence of a later gate counts it as waiting, not as
# a criterion that is not met: the analysis must not read it as a failure.
repo="$(setup_repo awaiting)"
in_run "$repo" 0 'mkdir -p .agents/completion; printf "%s\n" "{\"schema\": \"completion/v1\", \"status\": \"awaiting_evidence\", \"criteria\": [{\"criterion\": \"c\", \"status\": \"met\", \"evidence\": \"e\"}, {\"criterion\": \"d\", \"gate\": \"post_merge\", \"status\": \"pending\", \"evidence\": \"later\"}], \"remaining\": []}" >.agents/completion/12.json'
record="$(records "$repo")"
[[ "$(jq -r '.observations[] | select(.id == "completion") | .what' <<<"$record")" == "The completion record says awaiting_evidence: 1 of 2 criteria wait for evidence of a later gate" ]] ||
  fail "a record that awaits evidence is not described as waiting: $record"
if grep -Fq "not met" <<<"$(jq -r '.observations[] | select(.id == "completion") | .what' <<<"$record")"; then
  fail "pending evidence is counted as not met"
fi

# A run with nothing to observe says so.
repo="$(setup_repo quiet)"
in_run "$repo" 0 ':'
jq -e '.none_relevant == true and (.observations | length) == 0' <<<"$(records "$repo")" >/dev/null ||
  fail "a run without observations does not say so"
grep -Fq "No relevant observation was derived." <<<"$(show "$repo" 12)" || fail "the absence of observations is not shown"

# The notes of the agent: facts, hypotheses, and proposals apart, kept when
# valid; a correction is one; "none" is a valid answer.
repo="$(setup_repo notes)"
in_run "$repo" 0 'mkdir -p .agents/experience; cat >.agents/experience/12.json <<JSON
{"schema": "experience-notes/v1", "observations": [
  {"kind": "fact", "what": "The test timed out twice", "evidence": [{"type": "check", "ref": "pytest run 2"}], "tried": "cached the fixture", "result": "passed"},
  {"kind": "hypothesis", "what": "The network call is slow", "uncertainty": "not measured"},
  {"kind": "proposal", "what": "Cache fixtures by default", "corrects": "20261001T000000Z-1-1/2"}]}
JSON
  AGENT_ROLE=implementer experience_notes_written "$PWD" "" call-1'
record="$(records "$repo")"
[[ "$(jq -c '[.agent.status, [.agent.observations[].kind]]' <<<"$record")" == '["valid",["fact","hypothesis","proposal"]]' ]] ||
  fail "valid notes were not kept apart by kind: $record"
markdown="$(show "$repo" 12)"
grep -Fq -- "- hypothesis: The network call is slow" <<<"$markdown" || fail "a hypothesis is not shown as one"
grep -Fq -- "  - corrects: 20261001T000000Z-1-1/2" <<<"$markdown" || fail "a correction is not recognisable"
repo="$(setup_repo none)"
in_run "$repo" 0 'mkdir -p .agents/experience; printf "%s\n" "{\"schema\": \"experience-notes/v1\", \"none\": true}" >.agents/experience/12.json; AGENT_ROLE=implementer experience_notes_written "$PWD" "" call-1'
jq -e '.agent == {status: "valid", none: true, observations: []}' <<<"$(records "$repo")" >/dev/null || fail "notes that say none are not valid"

# Invalid notes are reported and not kept; the run keeps its outcome.
repo="$(setup_repo invalid-notes)"
status=0
in_run "$repo" 0 'mkdir -p .agents/experience; printf "%s\n" "{\"schema\": \"experience-notes/v1\", \"observations\": [{\"kind\": \"fact\", \"what\": \"It works\"}, {\"kind\": \"guess\", \"what\": \"x\", \"transcript\": \"...\"}]}" >.agents/experience/12.json; AGENT_ROLE=implementer experience_notes_written "$PWD" "" call-1' \
  2>"$tmp/invalid.err" || status=$?
[[ "$status" -eq 0 ]] || fail "invalid notes changed the outcome of the run"
record="$(records "$repo")"
[[ "$(jq -r '.agent.status' <<<"$record")" == "invalid" ]] || fail "invalid notes were kept"
jq -e '.agent | has("observations") | not' <<<"$record" >/dev/null || fail "invalid notes reached the record"
grep -Fq "a fact without evidence" "$tmp/invalid.err" || fail "a fact without evidence was not reported"
grep -Fq "unknown field: transcript" "$tmp/invalid.err" || fail "an unknown field was not reported"
# Notes and reviews of an earlier run, also one in the same second, are not
# this run's: a run claims what it wrote, not what changed recently.
in_run "$repo" 0 ':' 2>/dev/null
[[ "$(latest_record "$repo" | jq -r '.agent.status')" == "absent" ]] || fail "notes of an earlier run were taken for this one"
repo="$(setup_repo same-second)"
in_run "$repo" 0 'write_round'
in_run "$repo" 0 ':'
[[ "$(latest_record "$repo" | jq -c '.derived | [.review_rounds, .findings]')" == '[0,{}]' ]] ||
  fail "a run took the review of the run before it: $(latest_record "$repo" | jq -c '.derived')"
# Two runs side by side: each names what it wrote.
repo="$(setup_repo overlapping)"
(
  cd "$repo"
  export PATH="$tmp/bin:$PATH"
  source scripts/lib/records.sh
  records_begin feature 12 run-feature.sh
  first="$RECORDS_FILE"
  (
    unset RECORDS_RUN_ID RECORDS_FILE
    records_begin feature 12 review-feature.sh
    write_round
    records_end 0
  )
  records_end 0
  jq -c 'select(.type == "experience") | .record.derived.review_rounds' "$first" >"$tmp/overlapping-first"
)
[[ "$(cat "$tmp/overlapping-first")" == "0" ]] || fail "a run took the review of a run beside it"
# Notes that changed after the session that wrote them are not attributed.
repo="$(setup_repo notes-changed)"
in_run "$repo" 0 'mkdir -p .agents/experience; printf "%s\n" "{\"schema\": \"experience-notes/v1\", \"none\": true}" >.agents/experience/12.json
  AGENT_ROLE=implementer experience_notes_written "$PWD" "" call-1
  printf "%s\n" "{\"schema\": \"experience-notes/v1\", \"none\": false, \"observations\": []}" >.agents/experience/12.json' 2>/dev/null
[[ "$(latest_record "$repo" | jq -r '.agent.errors[0]')" == "the notes changed after the session of this run that wrote them; they are not attributed to it" ]] ||
  fail "notes that changed after their session were attributed"

# A record that cannot be made, or one that is damaged, changes no outcome
# and is never shown as valid.
repo="$(setup_repo failing)"
status=0
(
  cd "$repo"
  source scripts/lib/records.sh
  experience_record() { return 1; }
  records_begin feature 12 run-feature.sh
  records_end 4
  echo "end returned $?"
) >"$tmp/failing.out" 2>&1 || status=$?
grep -Fq "end returned 0" "$tmp/failing.out" || fail "a failing record changed the end of the run"
grep -Fq "the experience record of the run could not be made" "$tmp/failing.out" || fail "a failing record was not reported"
cat "$repo"/.agents/run/records/*.jsonl | jq -e -s 'any(.type == "run-end" and .status == 4)' >/dev/null || fail "the run lost its end"
file="$(ls "$repo"/.agents/run/records/*.jsonl)"
run="$(jq -r 'select(.type == "run-start") | .run' "$file")"
jq -cn --arg run "$run" '{schema: "run-record/v1", run: $run, time: "2026-10-01T00:00:00Z", epoch: 1, type: "experience",
  record: {schema: "experience/v1", run: $run, issue: 12, observations: [{kind: "fact", what: "Unproven"}]}}' >>"$file"
json="$(show "$repo" 12 --json)"
[[ "$(jq -c '[(.valid | length), (.invalid | length)]' <<<"$json")" == "[0,1]" ]] || fail "a damaged record was not reported as invalid: $json"
grep -Fq "These are not a source for an analysis." <<<"$(show "$repo" 12)" || fail "the invalid record is not marked as such"

# A run started from the primary checkout reads the artifacts of the feature
# worktree, and the record names its commit and its content.
repo="$(setup_repo primary)"
git -C "$repo" worktree add -q -b feature/12-thing-wt "$tmp/primary-12" >/dev/null 2>&1
git -C "$repo" checkout -q -b main
printf 'work in progress\n' >"$tmp/primary-12/work.txt"
(
  cd "$repo"
  export PATH="$tmp/bin:$PATH"
  source scripts/lib/records.sh
  records_begin feature 12 run-feature.sh
  (cd "$tmp/primary-12" && write_round)
  records_end 0
)
record="$(records "$repo")"
[[ "$(jq -r '.derived.review_rounds' <<<"$record")" == "1" ]] || fail "a run from the primary checkout did not read the reviews of the feature worktree"
[[ "$(jq -r '.code_version.commit' <<<"$record")" == "$(git -C "$tmp/primary-12" rev-parse HEAD)" ]] || fail "the record names another commit"
content_one="$(jq -r '.code_version.content' <<<"$record")"
[[ "$content_one" =~ ^[0-9a-f]{40}$ ]] || fail "the record names no content version: $record"
# Another uncommitted version on the same commit is another content version.
printf 'more work\n' >>"$tmp/primary-12/work.txt"
(cd "$repo" && source scripts/lib/records.sh && records_begin feature 12 run-feature.sh && records_end 0)
content_two="$(latest_record "$repo" | jq -r '.code_version.content')"
[[ "$content_two" =~ ^[0-9a-f]{40}$ && "$content_two" != "$content_one" ]] ||
  fail "two uncommitted versions on one commit have the same content version"

# The completion gate after each session is recorded with the content it
# judged, and becomes an observation, apart from the final completion record.
repo="$(setup_repo gates)"
in_run "$repo" 0 'source scripts/lib/fingerprint.sh 2>/dev/null || true
  records_agent_start s1 implementer write claude model-i
  records_gate "$PWD" partial "the handoff note lists remaining work"
  printf "next\n" >step.txt
  records_gate "$PWD" complete ""
  records_agent_start s2 triage-implementer write codex model-f
  records_gate "$PWD" complete ""'
record="$(records "$repo")"
[[ "$(jq -c '.derived.completion_gates | map([.check, .sessions, .session, .status])' <<<"$record")" == '[[1,1,"s1","partial"],[2,1,"s1","complete"],[3,2,"s2","complete"]]' ]] ||
  fail "the gates of the sessions are not recorded: $(jq -c '.derived' <<<"$record")"
[[ "$(jq -r '.observations[] | select(.id == "completion-gate-1") | .circumstances' <<<"$record")" == "the handoff note lists remaining work" ]] ||
  fail "the reasons of a gate are not observed"
[[ "$(jq -r '.observations[] | select(.id == "completion-gate-2") | .what' <<<"$record")" == "Check 2 of the completion gate in the run, after 1 implementing sessions of the run, said complete" ]] ||
  fail "a second check after the same session is taken for another session"
[[ "$(jq -r '[.derived.completion_gates[].content] | unique | length' <<<"$record")" -ge 2 ]] ||
  fail "the gates do not name the content each judged"
[[ "$(show "$repo" 12 --json | jq '.valid | length')" == "1" ]] || fail "a record with gates is not valid"

# A run with many findings gives a valid record: the limit of 20 is for the
# notes of an agent.
repo="$(setup_repo many)"
in_run "$repo" 0 'jq -n "{schema: \"review/v1\", issue: 12, round: 1, head: \"h\", findings: [range(25) | {id: \"MIN\(.)\", severity: \"minor\", title: \"Finding \(.)\"}]}" >.agents/reviews/feature-12-thing-review-01.json; records_artifact review .agents/reviews/feature-12-thing-review-01.json'
[[ "$(records "$repo" | jq '.observations | length')" == "25" ]] || fail "the findings of a run were not all observed"
[[ "$(show "$repo" 12 --json | jq -c '[(.valid | length), (.invalid | length)]')" == "[1,0]" ]] || fail "a record with many findings is invalid"

# A private key in the notes is removed whole.
repo="$(setup_repo private-key)"
in_run "$repo" 0 'mkdir -p .agents/experience; jq -n "{schema: \"experience-notes/v1\", observations: [{kind: \"hypothesis\", what: \"The key was\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAA\nQyNTUxOQAAACDtopsecret\n-----END OPENSSH PRIVATE KEY-----\nin the log\"}]}" >.agents/experience/12.json; AGENT_ROLE=implementer experience_notes_written "$PWD" "" call-1'
record="$(records "$repo")"
if grep -Eq "b3BlbnNzaC1rZXktdjEAAAA|topsecret|END OPENSSH" <<<"$record"; then fail "key material reached the record"; fi
[[ "$(jq -r '.agent.observations[0].what' <<<"$record")" == $'The key was\n[redacted]\nin the log' ]] || fail "the private key was not replaced: $record"

# A record whose derived part is damaged is invalid, and the valid records
# beside it are still shown.
repo="$(setup_repo derived)"
in_run "$repo" 0 ':'
file="$(ls "$repo"/.agents/run/records/*.jsonl)"
jq -c 'select(.type == "experience") | .record.derived = "corrupt" | .record.run = "other"' "$file" >>"$file"
json="$(show "$repo" 12 --json)"
[[ "$(jq -c '[(.valid | length), (.invalid | length)]' <<<"$json")" == "[1,1]" ]] || fail "a damaged derived part is not invalid: $json"
jq -e '.invalid[0].errors | any(. == "the derived part is not an object")' <<<"$json" >/dev/null || fail "the damaged derived part is not named"

# Blank evidence is no evidence: a fact with an empty or a blank reference,
# or with a blank reason for missing evidence, makes notes invalid, and a
# stored record with one is invalid.
for observation in '{"kind": "fact", "what": "x", "evidence": [{"type": "", "ref": ""}]}' \
  '{"kind": "fact", "what": "x", "evidence": [{"type": "check", "ref": "   "}]}' \
  '{"kind": "fact", "what": "x", "missing_evidence": "  "}' '{"kind": "hypothesis", "what": " "}'; do
  repo="$(setup_repo "blank-${#observation}-$RANDOM")"
  in_run "$repo" 0 "mkdir -p .agents/experience; printf '%s\\n' '{\"schema\": \"experience-notes/v1\", \"observations\": [$observation]}' >.agents/experience/12.json
    AGENT_ROLE=implementer experience_notes_written \"\$PWD\" '' call-1" 2>/dev/null
  [[ "$(latest_record "$repo" | jq -r '.agent.errors | map(select(test("JSON object|schema"))) | length')" == "0" && "$(latest_record "$repo" | jq -r '.agent.status')" == "invalid" ]] || fail "blank evidence was accepted, or the notes were not read: $observation $(latest_record "$repo" | jq -c .agent)"
done
file="$(ls "$repo"/.agents/run/records/*.jsonl)"
jq -c 'select(.type == "experience") | .record.observations = [{kind: "fact", what: "x", evidence: [{type: " ", ref: ""}]}] | .record.none_relevant = false' "$file" | head -n 1 >>"$file"
[[ "$(show "$repo" 12 --json | jq '.invalid | length')" -ge 1 ]] || fail "a stored record with blank evidence is valid"

# A record that cannot even be checked, or that names another run or Issue,
# is invalid, and hides no valid record beside it.
repo="$(setup_repo isolated)"
in_run "$repo" 0 ':'
file="$(ls "$repo"/.agents/run/records/*.jsonl)"
jq -c 'select(.type == "experience") | .record.code_version = "corrupt"' "$file" >>"$file"
jq -c 'select(.type == "experience") | .record.agent = "corrupt"' "$file" | head -n 1 >>"$file"
jq -c 'select(.type == "experience") | .record.run = "another-run"' "$file" | head -n 1 >>"$file"
jq -c 'select(.type == "experience") | .record.issue = 13' "$file" | head -n 1 >>"$file"
json="$(show "$repo" 12 --json)"
[[ "$(jq -c '[(.valid | length), (.invalid | length)]' <<<"$json")" == "[1,4]" ]] || fail "damaged records were not isolated: $json"
jq -e '[.invalid[].errors[]] | any(. == "the record names another run than the one it is in") and any(. == "the record names another Issue")' <<<"$json" >/dev/null ||
  fail "a record of another run or Issue was not named as such: $json"

# A line that is not JSON in the file of a run of the feature is reported as
# invalid, with its file and line, and hides no valid record.
printf '{"type":"experience","record":{"schema":"exp\n' >>"$file"
json="$(show "$repo" 12 --json)"
[[ "$(jq -c '[(.valid | length), (.invalid | length)]' <<<"$json")" == "[1,5]" ]] || fail "a line that is not JSON was not reported: $json"
jq -e --arg f "${file##*/}" '.invalid | any(.errors[] | startswith("line ") and endswith(" of " + $f + " is not JSON"))' <<<"$json" >/dev/null ||
  fail "the line that is not JSON is not named with its file and line: $json"

# Recording that is not available changes no outcome of a session.
repo="$(setup_repo unavailable)"
(
  cd "$repo"
  unset RECORDS_COMMAND
  source scripts/lib/records.sh
  session_test() { local records_command="${RECORDS_COMMAND:-}"; [[ "${records_command##*/}" == "start-feature.sh" ]] || echo "no gate recorded"; }
  set -u
  session_test
) >"$tmp/unavailable.out" 2>&1 || fail "an unset RECORDS_COMMAND failed: $(cat "$tmp/unavailable.out")"

# Evidence holds a type and a reference only: a transcript inside it makes
# the notes invalid.
repo="$(setup_repo evidence)"
in_run "$repo" 0 'mkdir -p .agents/experience; printf "%s\n" "{\"schema\": \"experience-notes/v1\", \"observations\": [{\"kind\": \"fact\", \"what\": \"x\", \"evidence\": [{\"type\": \"check\", \"ref\": \"r\", \"transcript\": \"the whole session\"}]}]}" >.agents/experience/12.json; AGENT_ROLE=implementer experience_notes_written "$PWD" "" call-1' 2>/dev/null
record="$(records "$repo")"
[[ "$(jq -r '.agent.status' <<<"$record")" == "invalid" ]] || fail "a transcript inside evidence was kept"
if grep -Fq "the whole session" <<<"$record"; then fail "the transcript inside evidence reached the record"; fi

# No event of the run copies a secret: not the reasons of a gate, not a note,
# also not in the copy of the feature.
repo="$(setup_repo secrets)"
in_run "$repo" 3 'records_note "implementation" "blocked" "the token ghp_abcdefghijklmnopqrstuvwxyz0123 expired" "stopped"
  records_gate "$PWD" partial "remaining: rotate sk-live1234567890abcdef"
  records_consolidate feature 12'
if grep -Eq "ghp_abcdefghij|sk-live1234567890" "$repo"/.agents/run/records/*.jsonl "$repo"/.agents/records/feature-12.jsonl; then
  fail "a secret reached the run file or the copy"
fi
grep -Fq "the token [redacted] expired" "$repo"/.agents/run/records/*.jsonl || fail "the note lost more than the secret"

# A failed verification of all checks is not repaired by a later pass of
# some of them; a later pass of all checks repairs it.
repo="$(setup_repo partial-pass)"
in_run "$repo" 0 'records_verification 1 30 false all; records_verification 0 5 false docs'
[[ "$(latest_record "$repo" | jq -c '.derived.verification')" == '{"runs":2,"failed":1,"repaired":0}' ]] ||
  fail "a partial verification counted as a repair: $(latest_record "$repo" | jq -c '.derived.verification')"
in_run "$repo" 0 'records_verification 1 30 false docs; records_verification 0 60 false all'
[[ "$(latest_record "$repo" | jq -c '.derived.verification')" == '{"runs":2,"failed":1,"repaired":1}' ]] ||
  fail "a later verification of all checks did not count as a repair"

# A verification on its own makes no record.
repo="$(setup_repo verify-only)"
(cd "$repo" && source scripts/lib/records.sh && records_begin feature 12 verify.sh && records_end 0)
[[ -z "$(records "$repo")" ]] || fail "a verification on its own made an experience record"

echo "experience tests passed"
