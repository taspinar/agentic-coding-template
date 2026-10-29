#!/usr/bin/env bash

set -euo pipefail

# The relation of a finding to the findings of earlier rounds (previous), as
# scripts/lib/review-data.sh checks it in the reviewer's result and in a
# stored review artifact against the earlier rounds and their triages.

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/review-data-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "review-data test failed: $*" >&2
  exit 1
}

source "$source_root/tests/lib-fakes.sh"
source "$source_root/scripts/lib/review-data.sh"

reviews="$tmp/.agents/reviews"
mkdir -p "$reviews" "$tmp/.agents/triage"

# finding <severity> <title> [<previous-json>]
finding() {
  jq -n --arg severity "$1" --arg title "$2" --argjson previous "${3:-null}" '
    {severity: $severity, title: $title, evidence: "marker.txt:1", impact: "It matters.",
     recommendation: "Fix it."} + (if $previous == null then {} else {previous: $previous} end)'
}

# write_review <round> <findings-json-array>: a stored review of round <round>
# of Issue 7, with the identifiers the script assigns.
write_review() {
  local file
  file="$reviews/feature-7-marker-review-$(printf '%02d' "$1").json"
  jq -n --argjson round "$1" --argjson findings "$2" '
    def prefix: {"critical": "C", "major": "M", "minor": "MIN", "suggestion": "S"}[.];
    {schema: "review/v1", kind: "feature", issue: 7, round: $round, branch: "feature/7-marker",
     base: "main", merge_base: "abc", head: "def", reviewed_tree: "tree-\($round)",
     created_at: "2026-01-01T00:00:00Z", reviewer: {agent: "codex", model: "model-r"},
     scope: {kind: "full"}, limitations: "",
     verdict: (if any($findings[]; .severity == "critical" or .severity == "major") then "CHANGES_REQUIRED"
               elif ($findings | length) > 0 then "PASS_WITH_MINOR_FINDINGS" else "PASS" end),
     findings: (reduce $findings[] as $f ({count: {}, out: []};
       .count[$f.severity] = ((.count[$f.severity] // 0) + 1)
       | .out += [{id: (($f.severity | prefix) + (.count[$f.severity] | tostring))} + $f]) | .out)}' >"$file"
  printf '%s\n' "$file"
}

# write_triage <review-json> <decision-per-id-json>: an approved triage of the
# review; a deferred finding has its follow-up Issue.
write_triage() {
  jq --argjson decided "$2" '{
    schema: "triage/v1", source_review: ".agents/reviews/\(input_filename | split("/") | last)", issue,
    reviewed_tree, review_verdict: .verdict, triage: {agent: "claude", model: "model-t"},
    approved_at: "2026-01-02T00:00:00Z",
    decisions: [.findings[] | {finding_id: .id, severity, title, decision: $decided[.id],
      rationale: "Decided \($decided[.id]).",
      followup: (if $decided[.id] == "DEFER" then
        {title: "Later", recommended_action: "Do it later.", acceptance_criteria: ["Done"],
         issue_number: 99, issue_url: "https://github.com/o/r/issues/99"} else null end)}]
  }' "$1" >"$tmp/.agents/triage/$(basename "$1" .json)-triage.json"
}

# Round 1: a major finding to fix, a minor one accepted, a suggestion deferred.
round1="$(write_review 1 "[$(finding major "Content unchecked"), $(finding minor "Vague name"), $(finding suggestion "Later idea")]")"
write_triage "$round1" '{"M1": "FIX_NOW", "MIN1": "ACCEPT", "S1": "DEFER"}'
[[ -z "$(review_artifact_errors "$round1")" ]] || fail "the fixture of round 1 is invalid: $(review_artifact_errors "$round1")"
# Round 2: never triaged.
round2="$(write_review 2 "[$(finding minor "Another detail")]")"

# expect_valid <what> <round> <findings>, expect_invalid <what> <round> <findings> <message>
expect_valid() {
  local review errors
  review="$(write_review "$2" "$3")"
  errors="$(review_artifact_errors "$review")"
  rm -f "$review"
  [[ -z "$errors" ]] || fail "$1 was refused: $errors"
}
expect_invalid() {
  local review errors
  review="$(write_review "$2" "$3")"
  errors="$(review_artifact_errors "$review")"
  rm -f "$review"
  [[ -n "$errors" ]] || fail "$1 was accepted"
  grep -Fq -- "$4" <<<"$errors" || fail "$1 was refused for another reason: $errors"
}

# Artifacts without previous validate as before.
expect_valid "a later round without previous" 3 "[$(finding major "Content unchecked")]"

# unresolved may point to a finding to fix, or to one that was never triaged.
expect_valid "an unresolved FIX_NOW finding" 3 \
  "[$(finding major "Content still unchecked" '{"round": 1, "id": "M1", "relation": "unresolved", "reason": ""}')]"
expect_valid "an unresolved finding of an untriaged round" 3 \
  "[$(finding minor "Detail still open" '{"round": 2, "id": "MIN1", "relation": "unresolved", "reason": ""}')]"

# unresolved must not point to an accepted or deferred finding.
expect_invalid "an unresolved ACCEPT finding" 3 \
  "[$(finding minor "Name still vague" '{"round": 1, "id": "MIN1", "relation": "unresolved", "reason": ""}')]" \
  "which the approved triage decided ACCEPT"
expect_invalid "an unresolved DEFER finding" 3 \
  "[$(finding suggestion "Idea still open" '{"round": 1, "id": "S1", "relation": "unresolved", "reason": ""}')]" \
  "which the approved triage decided DEFER"

# worsened is a legitimate re-raise with a reason, and invalid without one.
expect_valid "a worsened ACCEPT finding with a reason" 3 \
  "[$(finding major "Name now misleading" '{"round": 1, "id": "MIN1", "relation": "worsened", "reason": "The rename made it misleading."}')]"
expect_invalid "a worsened finding without a reason" 3 \
  "[$(finding minor "Name worse" '{"round": 1, "id": "MIN1", "relation": "worsened", "reason": " "}')]" \
  "a worsened finding needs a reason"
expect_valid "a worsened DEFER finding with a reason" 3 \
  "[$(finding minor "Idea now blocks" '{"round": 1, "id": "S1", "relation": "worsened", "reason": "The change made it block."}')]"

# The earlier decision stands: an unresolved finding keeps the severity of
# its predecessor, and a finding to fix (FIX_NOW or untriaged) cannot come
# back as worsened, which would let a lower severity weaken the gate.
expect_invalid "an unresolved FIX_NOW finding with a lower severity" 3 \
  "[$(finding minor "Content still unchecked" '{"round": 1, "id": "M1", "relation": "unresolved", "reason": ""}')]" \
  "finding MIN1 is unresolved M1 of round 1, which was major, but is minor; an unresolved finding keeps the severity of its predecessor"
expect_invalid "an unresolved untriaged finding with another severity" 3 \
  "[$(finding major "Detail still open" '{"round": 2, "id": "MIN1", "relation": "unresolved", "reason": ""}')]" \
  "an unresolved finding keeps the severity of its predecessor"
expect_invalid "a worsened FIX_NOW finding" 3 \
  "[$(finding minor "Content unchecked, now worse" '{"round": 1, "id": "M1", "relation": "worsened", "reason": "The fix removed the check."}')]" \
  "finding MIN1 is worsened M1 of round 1, which was to be fixed (FIX_NOW); only an accepted or deferred finding comes back as worsened"
expect_invalid "a worsened finding of an untriaged round" 3 \
  "[$(finding suggestion "Detail now worse" '{"round": 2, "id": "MIN1", "relation": "worsened", "reason": "The fix made it worse."}')]" \
  "which was to be fixed (not triaged)"

# An unknown round or id, or a round that is not earlier, is invalid.
expect_invalid "an unknown id" 3 \
  "[$(finding major "Gone" '{"round": 1, "id": "M7", "relation": "unresolved", "reason": ""}')]" \
  "that round has no such finding"
expect_invalid "an unknown round" 5 \
  "[$(finding major "Gone" '{"round": 4, "id": "M1", "relation": "unresolved", "reason": ""}')]" \
  "the feature has no review of that round"
expect_invalid "the same round" 3 \
  "[$(finding major "Self" '{"round": 3, "id": "M1", "relation": "unresolved", "reason": ""}')]" \
  "which is not an earlier round"
expect_invalid "an invalid relation" 3 \
  "[$(finding major "Odd" '{"round": 1, "id": "M1", "relation": "same", "reason": ""}')]" \
  "previous.relation must be unresolved or worsened"

# A triage that is not valid for its review does not count: the finding is
# to be fixed, so unresolved is valid.
triage="$tmp/.agents/triage/feature-7-marker-review-01-triage.json"
cp "$triage" "$tmp/triage.saved"
jq 'del(.approved_at)' "$tmp/triage.saved" >"$triage"
expect_valid "an unresolved finding whose triage is not approved" 3 \
  "[$(finding minor "Name still vague" '{"round": 1, "id": "MIN1", "relation": "unresolved", "reason": ""}')]"
cp "$tmp/triage.saved" "$triage"

# The latest triage of a round decides.
jq '.decisions |= map(if .finding_id == "MIN1" then .decision = "FIX_NOW" else . end)' "$tmp/triage.saved" \
  >"$tmp/.agents/triage/feature-7-marker-review-01-triage-02.json"
expect_valid "an unresolved finding that a later triage decided to fix" 3 \
  "[$(finding minor "Name still vague" '{"round": 1, "id": "MIN1", "relation": "unresolved", "reason": ""}')]"
rm -f "$tmp/.agents/triage/feature-7-marker-review-01-triage-02.json"

# A newer triage artifact that is invalid does not hide the approved one: its
# decisions stay in force, so an unresolved ACCEPT finding is still refused.
jq '.decisions |= map(if .finding_id == "MIN1" then .decision = "FIX_NOW" else . end) | del(.approved_at)' \
  "$tmp/triage.saved" >"$tmp/.agents/triage/feature-7-marker-review-01-triage-02.json"
[[ "$(review_approved_triage "$tmp" "$round1")" == "$triage" ]] ||
  fail "the approved triage was not chosen over a newer invalid one"
expect_invalid "an unresolved ACCEPT finding whose round has a newer invalid triage" 3 \
  "[$(finding minor "Name still vague" '{"round": 1, "id": "MIN1", "relation": "unresolved", "reason": ""}')]" \
  "which the approved triage decided ACCEPT"
[[ "$(jq -r '.findings[] | select(.round == 1 and .id == "MIN1") | .decision' \
     <<<"$(review_earlier_decisions "$reviews/feature-7-marker-review-03.json" 7 3)")" == "ACCEPT" ]] ||
  fail "the earlier decisions lost the approved ACCEPT behind a newer invalid triage"
rm -f "$tmp/.agents/triage/feature-7-marker-review-01-triage-02.json"
[[ -z "$(review_approved_triage "$tmp" "$round2")" ]] || fail "an untriaged round has an approved triage"

# The earlier decisions as review-feature.sh gives them to the reviewer.
earlier="$(review_earlier_decisions "$reviews/feature-7-marker-review-03.json" 7 3)"
[[ "$(jq -c '.rounds' <<<"$earlier")" == "[1,2]" ]] || fail "the earlier rounds are wrong: $earlier"
[[ "$(jq -c '[.findings[] | [.round, .id, .decision]]' <<<"$earlier")" == '[[1,"M1","FIX_NOW"],[1,"MIN1","ACCEPT"],[1,"S1","DEFER"],[2,"MIN1",null]]' ]] ||
  fail "the earlier decisions are wrong: $earlier"
[[ "$(jq -c '.rounds' <<<"$(review_earlier_decisions "$reviews/feature-7-marker-review-02.json" 7 2)")" == "[1]" ]] ||
  fail "a later round counted as earlier"
[[ "$(jq -c '.rounds' <<<"$(review_earlier_decisions "$reviews/feature-7-marker-review-03.json" 8 3)")" == "[]" ]] ||
  fail "a round of another Issue counted as earlier"

# The reviewer's result: previous may be null or absent, and is kept in the
# stored findings only when it names a finding.
result="$tmp/result.json"
jq -n --argjson a "$(finding major "New")" --argjson b "$(finding minor "Old" '{"round": 1, "id": "M1", "relation": "unresolved", "reason": ""}')" '
  {verdict: "CHANGES_REQUIRED", limitations: "", findings: [$a + {previous: null}, $b]}' >"$result"
[[ -z "$(review_result_errors "$result")" ]] || fail "a valid result was refused: $(review_result_errors "$result")"
[[ "$(review_result_with_ids "$result" | jq -c '[.findings[] | .previous]')" == '[null,{"round":1,"id":"M1","relation":"unresolved","reason":""}]' ]] ||
  fail "the stored findings do not keep previous as named"
[[ "$(review_result_with_ids "$result" | jq '.findings[0] | has("previous")')" == "false" ]] ||
  fail "a new finding was stored with previous"
jq '.findings[1].previous.extra = 1' "$result" >"$result.tmp"
grep -Fq "previous has unexpected fields: extra" <<<"$(review_result_errors "$result.tmp")" ||
  fail "an unexpected field of previous was accepted"

# The generated report names the predecessor.
review="$(write_review 3 "[$(finding major "Name now misleading" '{"round": 1, "id": "MIN1", "relation": "worsened", "reason": "The rename made it misleading."}')]")"
review_render_markdown "$review" review.json | grep -Fq "**Continues:** MIN1 of round 1, worsened: The rename made it misleading." ||
  fail "the report does not name the predecessor"

echo "review-data tests passed"
