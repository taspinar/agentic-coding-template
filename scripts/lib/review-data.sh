#!/usr/bin/env bash

# Validation and rendering of review and triage data.
# Source this file; do not execute it. Requires jq.
#
# Review and triage artifacts are JSON. The Markdown next to them is rendered
# from that JSON for reading and is never parsed.
#
# Every *_errors function prints one line per violated rule and prints nothing
# when its input is valid. Agent results and stored artifacts are checked with
# the same rules, so an edited artifact cannot bypass them.

review_data_require_jq() {
  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required. Install it: 'brew install jq' or 'sudo apt-get install jq'." >&2
    exit 1
  }
}

# review_data_is_json <file>: succeeds when the file holds exactly one JSON value.
review_data_is_json() {
  [[ -s "$1" ]] && jq -es 'length == 1' "$1" >/dev/null 2>&1
}

# Rules shared by agent results and stored artifacts.
_review_data_rules='
  def nonempty: type == "string" and test("\\S");

  def positive_integer: type == "number" and . >= 1 and . == floor;

  def unexpected($allowed; $where):
    (keys - $allowed) as $extra
    | if ($extra | length) > 0 then "\($where) has unexpected fields: \($extra | join(", "))" else empty end;

  def missing($required; $where):
    ($required - keys) as $absent
    | if ($absent | length) > 0 then "\($where) lacks required fields: \($absent | join(", "))" else empty end;

  # Input: {verdict, findings, limitations}.
  def review_result_rules:
    if type != "object" then
      "the result is not a JSON object"
    else
      unexpected(["findings", "limitations", "verdict"]; "the result"),
      (if (.verdict | IN("PASS", "PASS_WITH_MINOR_FINDINGS", "CHANGES_REQUIRED")) then empty
       else "verdict must be PASS, PASS_WITH_MINOR_FINDINGS, or CHANGES_REQUIRED" end),
      (if (.limitations | type) == "string" then empty
       else "limitations must be a string" end),
      (if (.findings | type) != "array" then
         "findings must be an array"
       else
         (.findings | to_entries[] | (.key + 1) as $n | .value as $f |
           if ($f | type) != "object" then
             "finding \($n) is not an object"
           else
             ($f | unexpected(["evidence", "impact", "recommendation", "severity", "title"]; "finding \($n)")),
             (if ($f.severity | IN("critical", "major", "minor", "suggestion")) then empty
              else "finding \($n) has an invalid severity" end),
             (("title", "evidence", "impact", "recommendation") as $field |
               if ($f[$field] | nonempty) then empty
               else "finding \($n) has an empty \($field)" end)
           end),
         ([.findings[] | objects | .severity] as $severities
          | ($severities | map(select(. == "critical" or . == "major")) | length) as $blocking
          | if .verdict == "PASS" and ($severities | length) > 0 then
              "verdict PASS requires that there are no findings"
            elif .verdict == "PASS_WITH_MINOR_FINDINGS" and (($severities | length) == 0 or $blocking > 0) then
              "verdict PASS_WITH_MINOR_FINDINGS requires at least one finding and no critical or major finding"
            elif .verdict == "CHANGES_REQUIRED" and $blocking == 0 then
              "verdict CHANGES_REQUIRED requires a critical or major finding; state anything unverified under limitations"
            else empty end)
       end)
    end;

  # Input: {decisions}. $severity maps each finding id of the review to its severity.
  def triage_decision_rules($severity):
    if type != "object" or (.decisions | type) != "array" then
      "the result must be an object with a decisions array"
    else
      unexpected(["decisions"]; "the result"),
      ([.decisions[] | objects | .finding_id] as $decided
       | ($severity | keys[]) as $id
       | ($decided | map(select(. == $id)) | length) as $count
       | if $count == 0 then "finding \($id) was not classified"
         elif $count > 1 then "finding \($id) was classified more than once"
         else empty end),
      (.decisions | to_entries[] | (.key + 1) as $n | .value as $d |
        if ($d | type) != "object" then
          "decision \($n) is not an object"
        elif ($d.finding_id | type) != "string" or ($severity | has($d.finding_id) | not) then
          "decision \($n) refers to an unknown finding: \($d.finding_id | tostring)"
        else
          ($d | unexpected(["decision", "finding_id", "followup", "rationale"]; "decision \($n)")),
          ($d | missing(["decision", "finding_id", "followup", "rationale"]; "decision \($n)")),
          (if ($d.decision | IN("FIX_NOW", "DEFER", "ACCEPT")) then empty
           else "finding \($d.finding_id) has an invalid decision" end),
          (if ($d.rationale | nonempty) then empty
           else "finding \($d.finding_id) has no rationale" end),
          (if ($severity[$d.finding_id] | IN("critical", "major")) and $d.decision != "FIX_NOW" then
             "\($severity[$d.finding_id]) finding \($d.finding_id) must be FIX_NOW"
           else empty end),
          (if $d.decision == "DEFER" then
             (if ($d.followup | type) != "object" then
                "deferred finding \($d.finding_id) needs a follow-up"
              else
                ($d.followup | unexpected(["acceptance_criteria", "recommended_action", "title"];
                  "the follow-up of finding \($d.finding_id)")),
                (if ($d.followup.title | nonempty) then empty
                 else "deferred finding \($d.finding_id) needs a follow-up title" end),
                (if ($d.followup.recommended_action | nonempty) then empty
                 else "deferred finding \($d.finding_id) needs a recommended action" end),
                (if (($d.followup.acceptance_criteria | type) == "array")
                    and (($d.followup.acceptance_criteria | length) > 0)
                    and ($d.followup.acceptance_criteria | all(nonempty)) then empty
                 else "deferred finding \($d.finding_id) needs acceptance criteria" end)
              end)
           elif $d.followup != null then
             "finding \($d.finding_id) is not deferred and must not have a follow-up"
           else empty end)
        end)
    end;
'

# review_result_errors <result-file>: rules for a reviewer's result.
review_result_errors() {
  review_data_is_json "$1" || {
    echo "the result is not exactly one JSON value"
    return 0
  }

  jq -r "$_review_data_rules"' review_result_rules' "$1"
}

# review_result_with_ids <result-file>
# Prints the validated result, reduced to its known fields, with a stable
# identifier per finding: C1, M1, MIN1, S1.
review_result_with_ids() {
  jq '
    def prefix: {"critical": "C", "major": "M", "minor": "MIN", "suggestion": "S"}[.];
    {
      verdict,
      limitations,
      findings: (
        reduce .findings[] as $f ({count: {}, out: []};
          .count[$f.severity] = ((.count[$f.severity] // 0) + 1)
          | .out += [{
              id: (($f.severity | prefix) + (.count[$f.severity] | tostring)),
              severity: $f.severity,
              title: $f.title,
              evidence: $f.evidence,
              impact: $f.impact,
              recommendation: $f.recommendation
            }]
        ) | .out
      )
    }
  ' "$1"
}

# review_artifact_errors <review-json>: rules for a stored review artifact.
review_artifact_errors() {
  review_data_is_json "$1" || {
    echo "the review is not exactly one JSON value"
    return 0
  }

  jq -r "$_review_data_rules"'
    if type != "object" or .schema != "review/v1" then
      "the file is not a review/v1 artifact"
    else
      unexpected(["base", "branch", "created_at", "findings", "head", "issue", "limitations",
                  "merge_base", "reviewed_tree", "reviewer", "round", "schema", "verdict"]; "the review"),
      (if (.issue | positive_integer) then empty else "issue must be a positive integer" end),
      (if (.round | positive_integer) then empty else "round must be a positive integer" end),
      (("branch", "base", "merge_base", "head", "reviewed_tree", "created_at") as $field |
        if (.[$field] | nonempty) then empty else "\($field) is missing" end),
      (if (.reviewer | type) == "object" and (.reviewer.agent | nonempty) and (.reviewer.model | nonempty) then empty
       else "reviewer must name its agent and model" end),
      (if (.findings | type) == "array" and (.findings | all(type == "object")) then
         (.findings[] |
           if (.id | type) == "string" and (.id | test("^(C|M|MIN|S)[1-9][0-9]*$"))
              and ((.id | sub("[0-9]+$"; "")) == ({"critical": "C", "major": "M", "minor": "MIN", "suggestion": "S"}[.severity])) then empty
           else "finding id \(.id | tostring) does not match its severity \(.severity | tostring)" end),
         ([.findings[] | .id] as $ids
          | if ($ids | unique | length) != ($ids | length) then "finding ids must be unique" else empty end)
       else empty end),
      ({
        verdict,
        limitations,
        findings: (if (.findings | type) == "array"
                   then (.findings | map(if type == "object" then del(.id) else . end))
                   else .findings end)
      } | review_result_rules)
    end
  ' "$1"
}

# review_render_markdown <review-json> <source-name>
review_render_markdown() {
  jq -r --arg source "$2" '
    def section($severity; $heading):
      "## \($heading)\n\n" +
      ([.findings[] | select(.severity == $severity)] as $items
       | if ($items | length) == 0 then "None.\n"
         else ($items | map(
           "### \(.id). \(.title)\n\n" +
           "**Evidence:** \(.evidence)\n\n" +
           "**Impact:** \(.impact)\n\n" +
           "**Recommended action:** \(.recommendation)\n"
         ) | join("\n")) end);
    "<!-- Generated from \($source). Do not edit; this file is never read by the scripts. -->\n\n" +
    "# Independent Review — \(.branch)\n\n" +
    "Issue: #\(.issue)\n\n" +
    "Round: \(.round)\n\n" +
    "Base: \(.base) (\(.merge_base))\n\n" +
    "HEAD at review start: \(.head)\n\n" +
    "Reviewed tree: \(.reviewed_tree)\n\n" +
    "Reviewer: \(.reviewer.agent) (\(.reviewer.model)), read-only\n\n" +
    section("critical"; "Critical") + "\n" +
    section("major"; "Major") + "\n" +
    section("minor"; "Minor") + "\n" +
    section("suggestion"; "Suggestions") + "\n" +
    "## Verdict\n\n\(.verdict | gsub("_"; " "))\n" +
    (if (.limitations | test("\\S")) then "\n## Limitations\n\n\(.limitations)\n" else "" end)
  ' "$1"
}

# triage_decision_errors <decisions-file> <review-json>: rules for a triage
# agent's decisions about the findings of a review.
triage_decision_errors() {
  review_data_is_json "$1" || {
    echo "the decisions are not exactly one JSON value"
    return 0
  }

  jq -r --slurpfile review "$2" "$_review_data_rules"'
    triage_decision_rules($review[0].findings | map({key: .id, value: .severity}) | from_entries)
  ' "$1"
}

# triage_source_review <triage-json>
# Prints the source review path of a triage/v1 artifact; prints nothing when
# the file is not such an artifact.
triage_source_review() {
  review_data_is_json "$1" || return 0
  jq -r 'if type == "object" and .schema == "triage/v1" and (.source_review | type) == "string"
         then .source_review else empty end' "$1"
}

# triage_artifact_errors <triage-json> <review-json>: rules for a stored,
# approved triage artifact, checked against its valid source review. A triage
# is complete only when every deferred finding has its follow-up Issue.
triage_artifact_errors() {
  review_data_is_json "$1" || {
    echo "the triage artifact is not exactly one JSON value"
    return 0
  }

  jq -r --slurpfile review "$2" "$_review_data_rules"'
    if type != "object" or .schema != "triage/v1" then
      "the file is not a triage/v1 artifact"
    else
      unexpected(["approved_at", "decisions", "issue", "review_verdict", "reviewed_tree",
                  "schema", "source_review", "triage"]; "the triage"),
      (if (.approved_at | type) == "string"
          and (.approved_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) then empty
       else "the triage has no valid UTC approval timestamp" end),
      (if .issue == $review[0].issue then empty
       else "triage and review reference different source Issues" end),
      (if (.triage | type) == "object" and (.triage.agent | nonempty) and (.triage.model | nonempty) then empty
       else "triage must name its agent and model" end),
      (if .review_verdict == $review[0].verdict and .reviewed_tree == $review[0].reviewed_tree then empty
       else "the triage does not describe the stored state of its source review" end),
      ($review[0].findings | map({key: .id, value: {severity, title}}) | from_entries) as $source
      | (if (.decisions | type) == "array" then
           (.decisions[] | objects | select($source[.finding_id] != null)
            | if {severity, title} == $source[.finding_id] then empty
              else "the decision for \(.finding_id) does not match the severity and title in the review" end)
         else empty end),
      (if (.decisions | type) == "array" then
         (.decisions[] | objects |
           unexpected(["decision", "finding_id", "followup", "rationale", "severity", "title"];
             "the decision for \(.finding_id | tostring)"),
           missing(["decision", "finding_id", "followup", "rationale", "severity", "title"];
             "the decision for \(.finding_id | tostring)"),
           (if (.followup | type) == "object" then
              (.followup |
                unexpected(["acceptance_criteria", "issue_number", "issue_url", "recommended_action", "title"];
                  "a follow-up"),
                (if (.issue_number | positive_integer)
                    and (.issue_url | type) == "string"
                    and (.issue_url | test("^https://[^ ]+/issues/[0-9]+$"))
                    and ((.issue_url | sub("^.*/"; "")) == (.issue_number | tostring)) then empty
                 else "a deferred finding has no valid follow-up Issue reference" end))
            else empty end))
       else empty end),
      ({
        decisions: (if (.decisions | type) == "array" then
          (.decisions | map(if type == "object" then {
            finding_id,
            decision,
            rationale,
            followup: (if (.followup | type) == "object"
                       then (.followup | del(.issue_number, .issue_url)) else .followup end)
          } else . end))
        else .decisions end)
      } | triage_decision_rules($review[0].findings | map({key: .id, value: .severity}) | from_entries))
    end
  ' "$1"
}

# triage_render_markdown <triage-json> <source-name>
triage_render_markdown() {
  jq -r --arg source "$2" '
    def group($decision; $heading):
      "## \($heading)\n\n" +
      ([.decisions[] | select(.decision == $decision)] as $items
       | if ($items | length) == 0 then "None.\n"
         else ($items | map(
           "### \(.finding_id). \(.title)\n\n" +
           "- Severity: \(.severity)\n" +
           "- Rationale: \(.rationale)\n" +
           (if .followup != null then
              "- Follow-up Issue: \(.followup.title)" +
              (if .followup.issue_number != null then " ([#\(.followup.issue_number)](\(.followup.issue_url)))" else "" end) + "\n" +
              "- Recommended action: \(.followup.recommended_action)\n" +
              "- Acceptance criteria:\n" + (.followup.acceptance_criteria | map("  - \(.)\n") | join(""))
            else "" end)
         ) | join("\n")) end);
    "<!-- Generated from \($source). Do not edit; this file is never read by the scripts. -->\n\n" +
    "# Review Triage\n\n" +
    "Source review: `\(.source_review)`\n\n" +
    "Source feature Issue: #\(.issue)\n\n" +
    "Reviewer verdict: \(.review_verdict | gsub("_"; " "))\n\n" +
    "Triage agent: \(.triage.agent) (\(.triage.model))\n\n" +
    "Approved at: \(.approved_at)\n\n" +
    group("FIX_NOW"; "Fix now") + "\n" +
    group("DEFER"; "Deferred") + "\n" +
    group("ACCEPT"; "Accepted")
  ' "$1"
}
