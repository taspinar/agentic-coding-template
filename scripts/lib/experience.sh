#!/usr/bin/env bash

# Experience records: compact observations of a feature run, kept as an
# `experience` event in the file of the run (lib/records.sh), so that they are
# stored and copied with the run records and never published.
# Source this file; do not execute it.
#
# A record has two parts. A script derives the first, always and without an
# agent, from what the workflow already wrote during the run: the reviews and
# their triage, the verifications, why the run stopped, and the completion
# record. The second is the agent's, and optional: the notes it wrote in
# .agents/experience/<issue>.json during the run, which are checked and kept
# only when they are valid. A record is never a gate: when it cannot be made,
# that is reported and the work goes on with its own outcome.

# The jq definitions of a record: the validation of the agent's notes and of a
# record, and the removal of what looks like a secret.
# Read without a subshell and without cat: Bash 3.2 misreads a here-document
# inside $(...), and a caller may run with a minimal PATH.
EXPERIENCE_JQ=""
IFS= read -r -d '' EXPERIENCE_JQ <<'JQ' || true

def experience_kinds: ["fact", "hypothesis", "proposal"];
def observation_keys: ["id", "kind", "what", "circumstances", "tried", "result", "evidence",
                       "missing_evidence", "uncertainty", "corrects"];


# observation_errors($where): what is wrong with one observation. A fact
# names its evidence, or says that evidence is missing.
def observation_errors($where):
  if type != "object" then ["\($where) is not an object"] else
    [ (keys - observation_keys | .[] | "\($where) has an unknown field: \(.)"),
      (if (.kind as $k | experience_kinds | index([$k])) == null then "\($where) has no kind of \(experience_kinds | join(", "))" else empty end),
      (if (.what | type) != "string" or (.what | test("\\S") | not) then "\($where) says nothing in what" else empty end),
      (to_entries[] | select((.value | type) == "string" and (.value | length) > 1000) | "\($where): \(.key) is longer than 1000 characters"),
      ((["circumstances", "tried", "result", "missing_evidence", "uncertainty", "corrects", "id"])[] as $field
        | select(has($field) and (.[$field] | type) != "string") | "\($where): \($field) is not text"),
      (if has("evidence") and ((.evidence | type) != "array"
            or (.evidence | any(type != "object" or (keys - ["type", "ref"] | length) > 0
                                or (.type | type) != "string" or (.ref | type) != "string"
                                or (.type | test("\\S") | not) or (.ref | test("\\S") | not)
                                or (.type | length) > 40 or (.ref | length) > 300)))
       then "\($where): every evidence has only a type and a ref, not blank, of at most 40 and 300 characters" else empty end),
      (if .kind == "fact" and ((.evidence // []) | length) == 0
          and ((.missing_evidence // "") | if type == "string" then test("\\S") | not else true end)
       then "\($where) is a fact without evidence and without saying that evidence is missing" else empty end) ]
  end;

# observations_errors($where; $limit): the limit applies to the notes of an
# agent; what a script derives is as long as the run was.
def observations_errors($where; $limit):
  if type != "array" then ["\($where) is not a list"]
  elif $limit != null and length > $limit then ["\($where) has more than \($limit) observations"]
  else [to_entries[] | .key as $i | .value | observation_errors("\($where)[\($i)]")] | flatten
  end;

# notes_errors: what is wrong with the agent's notes,
# .agents/experience/<issue>.json.
def notes_errors:
  if type != "object" then ["the notes are not a JSON object"] else
    [ (if .schema != "experience-notes/v1" then "the notes do not say schema experience-notes/v1" else empty end),
      (if (.none | type) != "boolean" and has("none") then "none is not true or false" else empty end),
      (if .none == true and ((.observations // []) | length) > 0 then "the notes say none and hold observations" else empty end),
      (if .none != true and (has("observations") | not) then "the notes hold no observations and do not say none" else empty end),
      (if has("observations") then (.observations | observations_errors("observations"; 20)) else [] end)[] ]
  end;

# record_errors: what is wrong with an experience record. An invalid record
# is reported, never used as a source.
def record_errors:
  if type != "object" then ["the record is not a JSON object"] else
    [ (if .schema != "experience/v1" then "the record does not say schema experience/v1" else empty end),
      (if (.run | type) != "string" then "the record names no run" else empty end),
      (if (.issue | type) != "number" then "the record names no Issue" else empty end),
      (if (.code_version | type) != "object" then "the record names no code version" else
         ((if (.code_version.commit | type) != "string" then "the record names no commit" else empty end),
          (if (.code_version.content | type) != "string" and .code_version.content != null then "the content version is not text" else empty end),
          (if (.code_version.reviewed_trees | type) != "array" then "the record names no reviewed contents" else empty end))
       end),
      (if (.none_relevant | type) != "boolean" then "the record does not say whether it has observations" else empty end),
      (.derived as $d
       | if ($d | type) != "object" then "the derived part is not an object" else
           ((["review_rounds"][] | select(($d[.] | type) != "number") | "derived.\(.) is not a number"),
            (["findings", "decisions"][] | select(($d[.] | type) != "object" or ($d[.] | any(.[]; type != "number"))) | "derived.\(.) is not a count per kind"),
            (if ($d.verification | type) != "object" or ([$d.verification.runs, $d.verification.failed, $d.verification.repaired] | any(type != "number"))
             then "derived.verification is not a count of runs, failures, and repairs" else empty end),
            (if $d.stop != null and (($d.stop | type) != "object" or ($d.stop.status | type) != "number") then "derived.stop has no status" else empty end),
            (if ($d.completion_gates | type) != "array" or ($d.completion_gates | any(type != "object" or (.status | type) != "string" or (.check | type) != "number"))
             then "derived.completion_gates is not a list of outcomes" else empty end),
            (if $d.completion != null and (($d.completion | type) != "object" or ($d.completion.status | type) != "string") then "derived.completion has no status" else empty end))
         end),
      (if .none_relevant == true and ((.observations // []) | type) == "array" and ((.observations // []) | length) > 0 then "the record says none relevant and holds observations" else empty end),
      ((.observations // null) | observations_errors("observations"; null)[]),
      (if (.agent | type) != "object" or ((.agent.status as $s | ["absent", "valid", "invalid"] | index([$s])) == null)
       then "the agent part has no status" else empty end),
      (if (.agent | type) == "object" and .agent.status == "valid" then ((.agent.observations // []) | observations_errors("agent.observations"; 20)[]) else empty end) ]
  end;
JQ

# experience_artifacts <kind>: the reviews or the triage that the current run
# recorded as written (records_artifact), as one JSON array of their objects
# with the path of each under "_path"; one that is gone or not JSON is left
# out.
experience_artifacts() {
  local path

  jq -r -s --arg kind "$1" '[.[] | select(.type == "artifact" and .kind == $kind) | .path] | unique | .[]' "$RECORDS_FILE" 2>/dev/null |
    while IFS= read -r path; do
      [[ -f "$EXPERIENCE_ROOT/$path" ]] || continue
      jq -c --arg path "$path" 'objects | . + {_path: $path}' "$EXPERIENCE_ROOT/$path" 2>/dev/null || true
    done | jq -cs '.'
}

# experience_notes_hash <worktree>: the hash of the agent's notes of the
# current feature, or nothing when there are none.
experience_notes_hash() {
  local file="$1/.agents/experience/${RECORDS_SUBJECT:-}.json"

  [[ "${RECORDS_KIND:-}" == "feature" && -f "$file" ]] || return 0
  git hash-object -- "$file" 2>/dev/null || true
}

# experience_notes_written <worktree> <hash-before> <call>: after a session of
# the implementer or the triage implementer, records that it changed the
# notes, by their hash only, so that the notes count for this run and for no
# other.
experience_notes_written() {
  local after

  [[ "${AGENT_ROLE:-}" == "implementer" || "${AGENT_ROLE:-}" == "triage-implementer" ]] || return 0
  after="$(experience_notes_hash "$1")"
  [[ -n "$after" && "$after" != "$2" ]] || return 0
  records_emit experience-notes --arg call "$3" --arg hash "$after" '{call: $call, hash: $hash}'
}

# experience_record <status>: derives the record of the current feature run,
# which ends with the status, and appends it to the file of the run.
experience_record() {
  local status="$1"
  local issue="${RECORDS_SUBJECT:-}"
  local start
  local commit
  local notes_file
  local notes="null"
  local completion="null"

  [[ -n "${RECORDS_FILE:-}" && -f "$RECORDS_FILE" && "$issue" =~ ^[0-9]+$ ]] || return 0
  # The artifacts are in the worktree of the feature, also when the run was
  # started from the primary checkout.
  EXPERIENCE_ROOT="$(records_feature_worktree "$issue")"
  [[ -n "$EXPERIENCE_ROOT" && -d "$EXPERIENCE_ROOT" ]] || EXPERIENCE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  start="$(jq -s 'map(select(.type == "run-start")) | first | .epoch // 0' "$RECORDS_FILE")" || return 1
  commit="$(git -C "$EXPERIENCE_ROOT" rev-parse HEAD 2>/dev/null)" || commit=""
  # The content at the end of the run, uncommitted changes included: two runs
  # on one commit can judge different code.
  local content=""
  local scratch
  if declare -F fingerprint_worktree >/dev/null && scratch="$(mktemp -d "${TMPDIR:-/tmp}/experience.XXXXXX" 2>/dev/null)"; then
    content="$(fingerprint_worktree "$EXPERIENCE_ROOT" "$scratch" 2>/dev/null)" || content=""
    rm -rf "$scratch"
  fi

  # The notes of the agent count for this run when a session of the run wrote
  # them, and only while the file still holds what that session left.
  notes_file="$EXPERIENCE_ROOT/.agents/experience/$issue.json"
  local notes_hash
  notes_hash="$(jq -r -s 'map(select(.type == "experience-notes")) | last | .hash // empty' "$RECORDS_FILE")" || notes_hash=""
  if [[ -n "$notes_hash" ]]; then
    if [[ -f "$notes_file" && "$(git hash-object -- "$notes_file" 2>/dev/null)" == "$notes_hash" ]]; then
      notes="$(jq -c '.' "$notes_file" 2>/dev/null)" || notes='"not JSON"'
    else
      notes='"changed"'
    fi
  fi
  if [[ -f "$EXPERIENCE_ROOT/.agents/completion/$issue.json" ]]; then
    completion="$(jq -c '.' "$EXPERIENCE_ROOT/.agents/completion/$issue.json" 2>/dev/null)" || completion='"not JSON"'
  fi

  local record
  record="$(jq -cn \
    --slurpfile events "$RECORDS_FILE" \
    --argjson reviews "$(experience_artifacts review)" \
    --argjson triage "$(experience_artifacts triage)" \
    --argjson notes "$notes" --argjson completion "$completion" \
    --arg run "$RECORDS_RUN_ID" --argjson issue "$issue" --arg commit "$commit" --arg content "$content" \
    --argjson status "$status" --argjson start "$start" \
    --arg handoff "$([[ -f "$EXPERIENCE_ROOT/.agents/handoffs/$issue.md" ]] && echo ".agents/handoffs/$issue.md")" \
    "$RECORDS_REDACT_JQ$EXPERIENCE_JQ"'
    # The reviews and triage that this run wrote.
    $reviews as $round_reviews
    | $triage as $round_triage
    | ($round_triage | map(.decisions[]? + {_triage: ._path}) ) as $decisions
    | ($events | map(select(.type == "verification"))) as $verifications
    | ($verifications | to_entries | map(select(.value.status != 0)) | map(.key)) as $failed
    # A failure counts as repaired only when a later verification passed that
    # covered what failed: all checks, or the same groups.
    | ($failed | map(. as $i | $verifications[$i].groups as $groups
        | select($verifications[$i + 1:] | any(.status == 0 and (.groups == "all" or .groups == $groups))))
        | length) as $repaired
    | ($events | map(select(.type == "note")) | last) as $note
    | ($events | map(select(.type == "completion-gate"))) as $gates
    | [ ($round_reviews[] as $review | ($review.findings // [])[] as $finding
         | ($decisions | map(select(.finding_id == $finding.id and (._triage | contains("review-\($review.round | tostring | if length < 2 then "0" + . else . end)")))) | first) as $decision
         | {id: "review-\($review.round)-\($finding.id)", kind: "fact",
            what: "Review round \($review.round) found a \($finding.severity) finding: \($finding.title)",
            evidence: ([{type: "review", ref: "\($review._path)#\($finding.id)"}]
                       + (if $decision == null then [] else [{type: "triage", ref: "\($decision._triage)#\($finding.id)"}] end)),
            result: (if $decision == null then "not triaged during this run" else "triage decided \($decision.decision)" end)}
         | if $decision == null then . + {missing_evidence: "no triage of this finding during the run"} else . end),
        (if ($failed | length) > 0 then
          {id: "verification", kind: "fact",
           what: "Verification failed \($failed | length) times during the run; for \($repaired) of those failures a later verification of the same checks passed",
           evidence: [{type: "run-record", ref: "\($run)#verification"}]} else empty end),
        (if $status != 0 then
          {id: "stop", kind: "fact",
           what: "The run stopped with status \($status)\(if $status == 3 then ", for a decision of the human" elif $status == 130 then ", interrupted" else "" end)",
           evidence: ([{type: "run-record", ref: "\($run)#run-end"}]
                      + (if $status == 3 and $handoff != "" then [{type: "handoff", ref: $handoff}] else [] end))}
          + (if $note != null and ($note.reason // "") != "" then {circumstances: "\($note.step): \($note.reason)"} else {} end)
         else empty end),
        ($gates | to_entries[] | .key as $i | .value as $gate
         | ($gate.check // ($i + 1)) as $check
         | {id: "completion-gate-\($check)", kind: "fact",
            what: "Check \($check) of the completion gate in the run, after \($gate.sessions // "an unknown number of") implementing sessions of the run, said \($gate.status)",
            evidence: ([{type: "run-record", ref: "\($run)#completion-gate-\($check)"}]
                       + (if $gate.session == null then [] else [{type: "agent-call", ref: "\($run)#\($gate.session)"}] end)
                       + (if $gate.content == null then [] else [{type: "content", ref: $gate.content}] end))}
         + (if ($gate.reasons // []) | length > 0 then {circumstances: ($gate.reasons | join("; "))} else {} end)),
        (if ($completion | type) == "object" and $completion.status != "complete" then
          {id: "completion", kind: "fact",
           what: "The completion record says \($completion.status): \(($completion.criteria // []) | map(select(.status != "met")) | length) of \(($completion.criteria // []) | length) criteria not met",
           evidence: [{type: "completion", ref: ".agents/completion/\($issue).json"}]}
         else empty end) ] as $observations
    | {schema: "experience/v1", run: $run, issue: $issue,
       code_version: {commit: $commit, content: (if $content == "" then null else $content end),
                      reviewed: ($round_reviews | map(.head) | map(select(. != null)) | unique),
                      reviewed_trees: ($round_reviews | map(.reviewed_tree) | map(select(. != null)) | unique)},
       derived: {
         review_rounds: ($round_reviews | length),
         findings: ($round_reviews | map(.findings[]?.severity) | group_by(.) | map({key: .[0], value: length}) | from_entries),
         decisions: ($decisions | map(.decision) | group_by(.) | map({key: .[0], value: length}) | from_entries),
         verification: {runs: ($verifications | length), failed: ($failed | length), repaired: $repaired},
         stop: (if $status == 0 then null else {status: $status, step: $note.step?, reason: $note.reason?} end),
         completion_gates: ($gates | to_entries | map(.key as $i | .value | {check: (.check // ($i + 1)), sessions, session, status, content})),
         completion: (if ($completion | type) == "object" then
           {status: $completion.status, criteria: (($completion.criteria // []) | length),
            met: (($completion.criteria // []) | map(select(.status == "met")) | length),
            remaining: (($completion.remaining // []) | length)}
           elif $completion == null then null else {status: "invalid"} end)},
       observations: $observations,
       none_relevant: ($observations | length == 0),
       agent: (if $notes == null then {status: "absent"}
               elif $notes == "changed" then {status: "invalid", errors: ["the notes changed after the session of this run that wrote them; they are not attributed to it"]}
               else ($notes | notes_errors) as $errors
                 | if ($errors | length) > 0 then {status: "invalid", errors: $errors}
                   else {status: "valid", none: ($notes.none == true), observations: ($notes.observations // [])} end
               end)}
    | redact_all')" || return 1
  records_emit experience --argjson record "$record" '{record: $record}'
  if [[ "$(jq -r '.agent.status' <<<"$record")" == "invalid" ]]; then
    echo "Warning: the experience notes in .agents/experience/$issue.json are invalid and were not kept:" >&2
    jq -r '.agent.errors[] | "  - " + .' <<<"$record" >&2
  fi
}

# The content version of a record needs the fingerprint of the worktree.
if ! declare -F fingerprint_worktree >/dev/null && [[ -f "${BASH_SOURCE[0]%/*}/fingerprint.sh" ]]; then
  source "${BASH_SOURCE[0]%/*}/fingerprint.sh"
fi
