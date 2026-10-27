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
#     "status": "complete" | "awaiting_evidence" | "partial" | "blocked",
#     "criteria": [
#       {"criterion": "<an acceptance criterion of the Issue, or a plan step>",
#        "gate": "implementation" | "pr_ci" | "owner_approval" | "post_merge",
#        "status": "met" | "not_met" | "not_applicable" | "pending",
#        "evidence": "<the test, file, or command that shows it; for
#                     not_applicable the reason, for pending the gate at
#                     which the evidence appears>"}
#     ],
#     "remaining": ["<what is left>", ...],
#     "risk": "low" | "medium" | "high"   (optional)
#   }
#
# 'risk' is the implementer's own classification of the feature (lib/risk.sh).
# It can raise the level that the scripts compute from the diff, never lower
# it: finish-feature.sh refuses a record that claims less.
#
# 'complete' needs every criterion met or not applicable and nothing
# remaining. 'partial' and 'blocked' need something that remains. The
# evidence of a criterion cannot be a partial run of the checks
# ('verify.sh --only'): such a run is not a verification. Nor can the
# evidence of a met criterion be a budget check of scripts/verify.conf or
# scripts/verify-workflow.conf ('<name> [<group>] budget: <command>'): a
# budget is a measurement that never fails the verification, so it shows
# nothing about a criterion.
#
# Evidence appears at a gate: 'implementation' (the default, before the work
# is committed), 'pr_ci' (after the pull request is published, before the
# merge), 'owner_approval' (before the merge), 'post_merge' (after the
# merge, before the Issue is closed). A criterion is 'pending' only when its
# gate is a later one than 'implementation'. When every implementation
# criterion is met and only later evidence is pending, the status is
# 'awaiting_evidence': the work is ready to commit and publish, but it is not
# 'complete' until the pending evidence exists.

COMPLETION_DIR=".agents/completion"

# completion_ready <status>
# Succeeds for a gate outcome that lets the work go on to the review, the
# commit, and the pull request.
completion_ready() {
  [[ "$1" == "complete" || "$1" == "awaiting_evidence" ]]
}

# completion_record <root> <issue>
# Prints the path of the completion record of the Issue.
completion_record() {
  printf '%s/%s/%s.json' "$1" "$COMPLETION_DIR" "$2"
}

# completion_budget_checks <root>
# Prints the names of the budget checks that the verification configuration
# of the working tree at <root> declares, one per line, and nothing without
# one. The syntax is that of scripts/verify.sh.
completion_budget_checks() {
  local file

  for file in "$1/scripts/verify.conf" "$1/scripts/verify-workflow.conf"; do
    [[ -f "$file" ]] || continue
    sed -nE 's/^([a-z0-9][a-z0-9-]*)([[:space:]]*\[[a-z0-9][a-z0-9-]*\])?[[:space:]]+budget:.*$/\1/p' "$file"
  done | sort -u
}

# completion_errors <record> [<root>]
# Prints what is wrong with a completion record, one problem per line, and
# nothing for a valid one. With <root>, the evidence of a met criterion may
# not name a budget check of that working tree.
completion_errors() {
  local record="$1"
  local budget_checks=""

  if ! jq -e . "$record" >/dev/null 2>&1; then
    echo "it is not valid JSON"
    return 0
  fi
  [[ -z "${2:-}" ]] || budget_checks="$(completion_budget_checks "$2")"
  jq -r --arg budget_checks "$budget_checks" '
    def text: type == "string" and test("[^[:space:]]");
    # A budget check named as a whole word in a text: not a word that merely
    # contains the name, such as a test or a path named after it.
    def budget_cited: . as $text
      | [$budget_checks | split("\n")[] | select(length > 0)
         | select(. as $name | $text | test("(^|[^a-z0-9_-])" + ($name | gsub("-"; "[-]")) + "($|[^a-z0-9_-])"))]
      | first // "";
    if type != "object" then "it is not a JSON object"
    else
      (if .schema != "completion/v1" then "schema must be \"completion/v1\"" else empty end),
      (if (.status | IN("complete", "awaiting_evidence", "partial", "blocked")) | not
       then "status must be complete, awaiting_evidence, partial, or blocked" else empty end),
      (if (.criteria | type) != "array" or (.criteria | length) == 0
       then "criteria must list at least one acceptance criterion"
       else (.criteria | to_entries[] |
         (.key + 1) as $n | .value |
         if type != "object" then "criterion \($n) is not an object"
         else
           (if (.criterion | text) | not then "criterion \($n) has no text" else empty end),
           (if (.status | IN("met", "not_met", "not_applicable", "pending")) | not
            then "criterion \($n): status must be met, not_met, not_applicable, or pending" else empty end),
           (if has("gate") and (.gate | IN("implementation", "pr_ci", "owner_approval", "post_merge") | not)
            then "criterion \($n): gate must be implementation, pr_ci, owner_approval, or post_merge" else empty end),
           (if .gate == "owner_approval" and (.status == "met")
            then "criterion \($n): owner_approval cannot be met in a record the implementer writes; it stays pending until the owner approves on GitHub" else empty end),
           (if .status == "pending" and ((.gate // "implementation") == "implementation")
            then "criterion \($n): pending is only for evidence of a later gate (pr_ci, owner_approval, or post_merge)" else empty end),
           (if (.evidence | text) | not then "criterion \($n) has no evidence" else empty end),
           (if (.evidence | type) == "string" and (.evidence | test("verify\\.sh([[:space:]]+-[^[:space:]]*)*[[:space:]]+--only([[:space:]]|$)"))
            then "criterion \($n) cites a partial run of the checks (verify.sh --only) as evidence, which is not a verification" else empty end),
           (if .status == "met" and (.evidence | type) == "string" and (.evidence | budget_cited) != ""
            then "criterion \($n) cites the budget check \u0027\(.evidence | budget_cited)\u0027 as evidence of a met criterion; a budget is a measurement that never fails the verification, so it shows nothing about the criterion" else empty end)
         end)
       end),
      (if (.remaining | type) != "array" or ([.remaining[]? | text] | all | not)
       then "remaining must be a list of texts; an empty list when nothing remains" else empty end),
      (if has("risk") and ((.risk | IN("low", "medium", "high")) | not)
       then "risk, when given, must be low, medium, or high" else empty end),
      (if (.status == "complete" or .status == "awaiting_evidence") and (.criteria | type) == "array"
          and ([.criteria[]? | objects | .status] | index("not_met")) != null
       then "status is \(.status), but a criterion is not met" else empty end),
      (if .status == "complete" and (.criteria | type) == "array"
          and ([.criteria[]? | objects | .status] | index("pending")) != null
       then "status is complete, but a criterion is pending; the status is awaiting_evidence until its evidence exists" else empty end),
      (if .status == "awaiting_evidence" and (.criteria | type) == "array"
          and ([.criteria[]? | objects | .status] | index("pending")) == null
       then "status is awaiting_evidence, but no criterion is pending" else empty end),
      (if (.status == "complete" or .status == "awaiting_evidence") and (.remaining | type) == "array" and (.remaining | length) > 0
       then "status is \(.status), but work remains" else empty end),
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
#   awaiting_evidence
#             the same, and only evidence of a later gate is pending: the
#             work may be reviewed, committed, and published, but is not
#             complete yet. The reasons name what is pending.
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
  errors="$(completion_errors "$record" "$root")"
  if [[ -n "$errors" ]]; then
    echo "invalid"
    printf '%s\n' "$errors" | sed "s|^|the completion record ($COMPLETION_DIR/$issue.json): |"
    return 0
  fi

  status="$(jq -r '.status' "$record")"
  if ! completion_ready "$status"; then
    echo "$status"
    jq -r '.criteria[] | select(.status == "not_met") | "not met: \(.criterion)"' "$record"
    jq -r '.remaining[] | "remaining: \(.)"' "$record"
    return 0
  fi

  left="$(handoff_remaining "$root/.agents/handoffs/$issue.md")"
  if [[ -n "$left" ]]; then
    echo "partial"
    echo "the completion record says $status, but the handoff note (.agents/handoffs/$issue.md) lists remaining work:"
    printf '%s\n' "$left" | sed 's/^/remaining: /'
    return 0
  fi
  echo "$status"
  jq -r '.criteria[] | select(.status == "pending") | "pending at \(.gate): \(.criterion)"' "$record"
}

# completion_pending_gates <root> <issue>
# Prints the gates (pr_ci, owner_approval, post_merge) at which a criterion
# of the record is still pending, once each, and nothing when none is.
completion_pending_gates() {
  jq -r '[.criteria[] | select(.status == "pending") | .gate] | unique[]' "$(completion_record "$1" "$2")"
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
# the status, the criteria with their evidence, and what remains. A criterion
# that is pending at the post_merge gate also gets one line
# 'Post-merge criterion: "<criterion as a JSON string>"', which
# record-post-merge.sh reads: exact, whatever the criterion or its evidence
# contain.
completion_commit_lines() {
  local record

  record="$(completion_record "$1" "$2")"
  jq -r '
    "Completion: \(.status)",
    (.criteria[] | "- \(.status | gsub("_"; " "))\(if .status == "pending" then " at \(.gate)" else "" end): \(.criterion) (\(.evidence))"),
    (.remaining[] | "- remaining: \(.)"),
    (.criteria[] | select(.status == "pending" and .gate == "post_merge") | "Post-merge criterion: \(.criterion | tojson)")' "$record"
}
