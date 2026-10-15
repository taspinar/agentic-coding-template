#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 [<issue>] [--json]"
  echo
  echo "Shows the experience records of a feature: per run what a script derived"
  echo "from the reviews, the triage, the verifications, the stops, and the"
  echo "completion record, and the notes of the agent when they were valid. An"
  echo "invalid record is shown as invalid, with what is wrong, and never as a"
  echo "source. Without an Issue, in a feature worktree, it shows that feature."
  echo "Reads the run records of the primary checkout; needs no network."
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/records.sh"
command -v jq >/dev/null 2>&1 || fail "jq is required."

issue=""
mode="markdown"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) mode="json" ;;
    -h | --help) usage ;;
    *)
      [[ "$1" =~ ^[0-9]+$ && -z "$issue" ]] || usage
      issue="$1"
      ;;
  esac
  shift
done
[[ -n "$issue" ]] || issue="$(records_branch_issue)"
[[ -n "$issue" ]] || usage

primary="$(records_primary)" || fail "not inside a Git repository."

# events <file>...: the events as one array. A line that is not JSON is kept
# as such, with its file and line, so that a damaged record is reported and
# hides nothing else.
events() {
  local file

  for file in "$@"; do
    [[ -f "$file" ]] || continue
    jq -cR --arg file "${file##*/}" \
      'try (fromjson | objects | . + {_file: $file}) catch {_unparsed: true, _file: $file, _line: input_line_number}' "$file"
  done | jq -cs '.'
}

# A run is read from its own file while it exists, and from the copy of the
# feature otherwise.
work="$(mktemp -d "${TMPDIR:-/tmp}/show-experience.XXXXXX")"
trap 'rm -rf "$work"' EXIT
events "$primary"/.agents/run/records/*.jsonl >"$work/active.json"
events "$primary/.agents/records/feature-$issue.jsonl" >"$work/copies.json"
result="$(jq -n -r \
  --slurpfile active "$work/active.json" --slurpfile copies "$work/copies.json" \
  --arg issue "$issue" --arg mode "$mode" \
  "$EXPERIENCE_JQ"'
  $active[0] as $active | $copies[0] as $copies |
  def runs_of($events): $events | map(select(.type == "run-start" and .kind == "feature" and ((.subject | tostring) == $issue)) | .run);
  runs_of($active) as $from_active
  | (runs_of($copies) - $from_active) as $from_copy
  | (($active | map(select(.run as $r | $from_active | index([$r])))) + ($copies | map(select(.run as $r | $from_copy | index([$r]))))) as $events
  | ($events | map(select(.type == "run-start")) | map({key: .run, value: .command}) | from_entries) as $commands
  # Every record is checked on its own: one that cannot be checked is invalid
  # and hides no other. A record must name the run it is in and this Issue.
  | ($events | map(select(.type == "experience")) | map(.run as $event_run | .record as $record
      | ((try ($record | record_errors) catch ["the record cannot be checked"])
         + (if ($record | type) == "object" and ($record.run | type) == "string" and $record.run != $event_run then ["the record names another run than the one it is in"] else [] end)
         + (if ($record | type) == "object" and ($record.issue | type) == "number" and ($record.issue | tostring) != $issue then ["the record names another Issue"] else [] end)) as $errors
      | {run, time, command: $commands[.run], valid: ($errors | length == 0), errors: $errors, record: $record})) as $records
  # Lines that are not JSON in a file of this feature: the file of one of its
  # runs, or its copy.
  | ([$active[], $copies[]]
     | map(select(._unparsed == true))
     | map(select((._file | rtrimstr(".jsonl")) as $f
                  | ((($from_active + $from_copy) | index([$f])) != null) or ($f == "feature-\($issue)")))
     | map({run: (._file | rtrimstr(".jsonl") | if startswith("feature-") then null else . end),
            time: null, command: null, errors: ["line \(._line) of \(._file) is not JSON"]})) as $unparsed
  | {issue: ($issue | tonumber), valid: ($records | map(select(.valid)) | map(.record + {command, time})),
     invalid: (($records | map(select(.valid | not)) | map({run, time, command, errors})) + $unparsed)}
  | if $mode == "json" then . else
      def observation: "- \(.kind): \(.what)"
        + (if .circumstances then "\n  - circumstances: \(.circumstances)" else "" end)
        + (if .tried then "\n  - tried: \(.tried)" else "" end)
        + (if .result then "\n  - result: \(.result)" else "" end)
        + (if (.evidence // []) | length > 0 then "\n  - evidence: \(.evidence | map("\(.type) \(.ref)") | join(", "))" else "" end)
        + (if .missing_evidence then "\n  - missing evidence: \(.missing_evidence)" else "" end)
        + (if .uncertainty then "\n  - uncertainty: \(.uncertainty)" else "" end)
        + (if .corrects then "\n  - corrects: \(.corrects)" else "" end)
        + "\n";
      "# Experience of feature #\(.issue)\n\n"
      + (if (.valid | length) == 0 and (.invalid | length) == 0 then "No experience record was made for this feature.\n" else "" end)
      + (.valid | map(
          "## Run \(.run) (\(.command // "unknown command"))\n\n"
          + "Code version \(.code_version.commit | if . == "" then "unknown" else .[0:12] end). "
          + "Review rounds \(.derived.review_rounds), verification \(.derived.verification.runs) (\(.derived.verification.failed) failed)"
          + (if .derived.stop then ", stopped with status \(.derived.stop.status)" else "" end) + ".\n\n"
          + (if .none_relevant then "No relevant observation was derived.\n" else (.observations | map(observation) | add) end)
          + (if .agent.status == "valid" then
               "\nThe agent:\n\n" + (if .agent.none then "No relevant observations, it says.\n" else (.agent.observations | map(observation) | add) end)
             elif .agent.status == "invalid" then
               "\nThe notes of the agent were invalid and are not kept:\n\n" + (.agent.errors | map("- \(.)\n") | add)
             else "" end)
          + "\n") | add // "")
      + (if (.invalid | length) == 0 then "" else
          "## Invalid records\n\nThese are not a source for an analysis.\n\n"
          + (.invalid | map("- \(if .run then "run \(.run)" else "the copy of the feature" end): \(.errors | join("; "))\n") | add) end)
    end')"
printf '%s\n' "$result"
