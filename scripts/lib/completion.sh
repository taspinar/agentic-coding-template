#!/usr/bin/env bash

# The completion gate of a feature. Source this file; it needs jq.
#
# A session that ends without an error is not a feature that is complete.
# The implementer therefore states where the work stands in a completion
# record, .agents/completion/<issue>.json, and the scripts go on to the
# commit and the pull request only when that record and the handoff note
# agree that the Issue is done. The record is a claim of the implementer: the
# independent review of the complete feature checks it against the code and
# the tests.
#
#   {
#     "schema": "completion/v1",
#     "status": "complete" | "partial" | "blocked",
#     "criteria": [
#       {"criterion": "<an acceptance criterion of the Issue, or a plan step>",
#        "status": "met" | "not_met" | "not_applicable",
#        "evidence": "<the test, file, or command that shows it; for
#                     not_applicable the reason>"}
#     ],
#     "remaining": ["<what is left>", ...]
#   }
#
# 'complete' needs every criterion met or not applicable and nothing
# remaining. 'partial' and 'blocked' need something that remains.

COMPLETION_DIR=".agents/completion"

# completion_record <root> <issue>
# Prints the path of the completion record of the Issue.
completion_record() {
  printf '%s/%s/%s.json' "$1" "$COMPLETION_DIR" "$2"
}

# completion_errors <record>
# Prints what is wrong with a completion record, one problem per line, and
# nothing for a valid one.
completion_errors() {
  local record="$1"

  if ! jq -e . "$record" >/dev/null 2>&1; then
    echo "it is not valid JSON"
    return 0
  fi
  jq -r '
    def text: type == "string" and test("[^[:space:]]");
    if type != "object" then "it is not a JSON object"
    else
      (if .schema != "completion/v1" then "schema must be \"completion/v1\"" else empty end),
      (if (.status | IN("complete", "partial", "blocked")) | not
       then "status must be complete, partial, or blocked" else empty end),
      (if (.criteria | type) != "array" or (.criteria | length) == 0
       then "criteria must list at least one acceptance criterion"
       else (.criteria | to_entries[] |
         (.key + 1) as $n | .value |
         if type != "object" then "criterion \($n) is not an object"
         else
           (if (.criterion | text) | not then "criterion \($n) has no text" else empty end),
           (if (.status | IN("met", "not_met", "not_applicable")) | not
            then "criterion \($n): status must be met, not_met, or not_applicable" else empty end),
           (if (.evidence | text) | not then "criterion \($n) has no evidence" else empty end)
         end)
       end),
      (if (.remaining | type) != "array" or ([.remaining[]? | text] | all | not)
       then "remaining must be a list of texts; an empty list when nothing remains" else empty end),
      (if .status == "complete" and (.criteria | type) == "array"
          and ([.criteria[]? | objects | .status] | index("not_met")) != null
       then "status is complete, but a criterion is not met" else empty end),
      (if .status == "complete" and (.remaining | type) == "array" and (.remaining | length) > 0
       then "status is complete, but work remains" else empty end),
      (if (.status == "partial" or .status == "blocked") and (.remaining | type) == "array"
          and (.remaining | length) == 0
       then "status is \(.status), but remaining does not say what is left" else empty end)
    end' "$record"
}

# handoff_remaining <handoff-note>
# Prints the work that a handoff note lists under 'Remaining', one line per
# line of the note, and nothing when there is none. The implementer reduces
# the note to one line when the Issue is complete, so text here means that
# work is left, whatever the completion record says.
handoff_remaining() {
  [[ -f "$1" ]] || return 0
  awk '
    function emit(text) {
      gsub(/^[[:space:]*:>-]+|[[:space:]]+$/, "", text)
      if (text == "") return
      if (tolower(text) ~ /^(none|nothing|n\/a|no remaining|nothing remains|-)[[:space:].!]*$/) return
      print text
    }
    # Another part of the note ends the list.
    found && (/^#/ || tolower($0) ~ /^[[:space:]]*([-*][[:space:]]*)?\**(done|in progress|tried and rejected|open questions?)\**[[:space:]]*:/) {
      found = 0
    }
    tolower($0) ~ /^[[:space:]]*(#+[[:space:]]*|[-*][[:space:]]*)?\**remaining( work)?\**[[:space:]]*:?\**[[:space:]]*/ &&
      tolower($0) !~ /^[[:space:]]*(#+[[:space:]]*|[-*][[:space:]]*)?\**remaining( work)?[a-z]/ {
      found = 1
      line = $0
      sub(/^[[:space:]]*(#+[[:space:]]*|[-*][[:space:]]*)?\**[Rr][Ee][Mm][Aa][Ii][Nn][Ii][Nn][Gg]( [Ww][Oo][Rr][Kk])?\**[[:space:]]*:?\**/, "", line)
      emit(line)
      next
    }
    found { emit($0) }' "$1"
}

# completion_summary_present <root> <issue>
# Succeeds when the implementer wrote the summary of the changes that the
# commit message is made from. An unattended run needs it: nobody edits the
# message there.
completion_summary_present() {
  local summary="$1/.agents/summaries/$2.md"

  [[ -f "$summary" ]] && grep -q '^[[:space:]]*- [^[:space:]]' "$summary"
}

# completion_gate <root> <issue>
# Decides whether the feature is complete. Prints the outcome on the first
# line and the reasons after it, one per line:
#
#   complete  the record is valid and says so, and the handoff note lists
#             no remaining work
#   partial   work remains, by the record or by the handoff note
#   blocked   the implementer cannot go on without the human
#   missing   there is no record
#   invalid   the record cannot be used
completion_gate() {
  local root="$1"
  local issue="$2"
  local record
  local errors
  local status
  local left

  record="$(completion_record "$root" "$issue")"
  if [[ ! -f "$record" ]]; then
    echo "missing"
    echo "the implementer wrote no completion record ($COMPLETION_DIR/$issue.json)"
    return 0
  fi
  errors="$(completion_errors "$record")"
  if [[ -n "$errors" ]]; then
    echo "invalid"
    printf '%s\n' "$errors" | sed "s|^|the completion record ($COMPLETION_DIR/$issue.json): |"
    return 0
  fi

  status="$(jq -r '.status' "$record")"
  if [[ "$status" != "complete" ]]; then
    echo "$status"
    jq -r '.criteria[] | select(.status == "not_met") | "not met: \(.criterion)"' "$record"
    jq -r '.remaining[] | "remaining: \(.)"' "$record"
    return 0
  fi

  left="$(handoff_remaining "$root/.agents/handoffs/$issue.md")"
  if [[ -n "$left" ]]; then
    echo "partial"
    echo "the completion record says complete, but the handoff note (.agents/handoffs/$issue.md) lists remaining work:"
    printf '%s\n' "$left" | sed 's/^/remaining: /'
    return 0
  fi
  echo "complete"
}

# completion_closing_pattern <issue>
# Prints an extended regular expression, to be matched without regard to
# case, for a keyword with which GitHub closes that Issue on a merge: in a
# pull request description, and in the message of a commit that reaches the
# default branch.
completion_closing_pattern() {
  printf '%s' "(^|[^[:alnum:]])(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)[[:space:]]*:?[[:space:]]+(#|[[:alnum:]_.-]+/[[:alnum:]_.-]+#|https?://github\\.com/[^[:space:]]+/issues/)$1([^0-9]|\$)"
}

# completion_neutralize_closing <issue>
# Copies standard input and turns every closing keyword for the Issue into
# 'Refs', so that text taken over from a commit message cannot close an Issue
# whose completion gate did not pass.
completion_neutralize_closing() {
  awk -v pattern="$(completion_closing_pattern "$1")" '
    {
      line = $0
      out = ""
      while (match(tolower(line), pattern)) {
        found = substr(line, RSTART, RLENGTH)
        # Keep what stands before the keyword and after the reference.
        lead = (tolower(found) ~ /^[^a-z]/) ? substr(found, 1, 1) : ""
        rest = substr(found, length(lead) + 1)
        sub(/^[A-Za-z]+([[:space:]]*:)?/, "Refs", rest)
        out = out substr(line, 1, RSTART - 1) lead rest
        line = substr(line, RSTART + RLENGTH)
      }
      print out line
    }'
}

# completion_commit_lines <root> <issue>
# Prints the completion statement of a commit message from a valid record:
# the status, the criteria with their evidence, and what remains.
completion_commit_lines() {
  local record

  record="$(completion_record "$1" "$2")"
  jq -r '
    "Completion: \(.status)",
    (.criteria[] | "- \(.status | gsub("_"; " ")): \(.criterion) (\(.evidence))"),
    (.remaining[] | "- remaining: \(.)")' "$record"
}
