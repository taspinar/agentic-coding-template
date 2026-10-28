#!/usr/bin/env bash

set -euo pipefail

# The completion gate of a feature: what counts as a valid completion record,
# what a handoff note lists as remaining work, and how the two decide.

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$source_root/tests/lib-fakes.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/completion-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "completion test failed: $*" >&2
  exit 1
}

source "$source_root/scripts/lib/completion.sh"

root="$tmp/project"
mkdir -p "$root/.agents/completion" "$root/.agents/handoffs" "$root/.agents/summaries"
record="$(completion_record "$root" 7)"
[[ "$record" == "$root/.agents/completion/7.json" ]] || fail "the record of an Issue is not where the contract says: $record"
note="$root/.agents/handoffs/7.md"

complete='{"schema": "completion/v1", "status": "complete", "criteria": [
  {"criterion": "Recipes can be searched", "status": "met", "evidence": "tests/test_search.py"},
  {"criterion": "Works offline", "status": "not_applicable", "evidence": "the Issue dropped it in a comment"}
], "remaining": []}'
partial='{"schema": "completion/v1", "status": "partial", "criteria": [
  {"criterion": "Recipes can be searched", "status": "met", "evidence": "tests/test_search.py"},
  {"criterion": "The page works without JavaScript", "status": "not_met", "evidence": "not started; plan step 4"}
], "remaining": ["Plan steps 4 to 6"]}'

# expect_errors <description> <record-json> <expected-error>...
expect_errors() {
  local description="$1"
  local errors

  printf '%s\n' "$2" >"$record"
  errors="$(completion_errors "$record")"
  shift 2
  if [[ $# -eq 0 ]]; then
    [[ -z "$errors" ]] || fail "$description: a valid record was refused: $errors"
    return 0
  fi
  for expected in "$@"; do
    grep -Fqx "$expected" <<<"$(printf '%s\n' "$errors")" || fail "$description: missing error '$expected' in: $errors"
  done
}

expect_errors "a complete record" "$complete"
expect_errors "a partial record" "$partial"
expect_errors "a blocked record" "$(printf '%s' "$partial" | sed 's/"partial"/"blocked"/')"
expect_errors "not JSON" "status: complete" "it is not valid JSON"
expect_errors "not an object" '["complete"]' "it is not a JSON object"
expect_errors "an empty object" '{}' 'schema must be "completion/v1"' "status must be complete, awaiting_evidence, partial, or blocked" \
  "criteria must list at least one acceptance criterion" "remaining must be a list of texts; an empty list when nothing remains"
expect_errors "an unknown status" "$(printf '%s' "$complete" | sed 's/"complete"/"done"/')" \
  "status must be complete, awaiting_evidence, partial, or blocked"
# A partial run of the checks is not a verification, so it is no evidence.
expect_errors "evidence that cites a partial run" "$(printf '%s' "$complete" | sed 's#tests/test_search.py#./scripts/verify.sh --only unit passed#')" \
  "criterion 1 cites a partial run of the checks (verify.sh --only) as evidence, which is not a verification"
expect_errors "evidence that cites the full run" "$(printf '%s' "$complete" | sed 's#tests/test_search.py#./scripts/verify.sh passed#')"
expect_errors "no criteria" '{"schema": "completion/v1", "status": "complete", "criteria": [], "remaining": []}' \
  "criteria must list at least one acceptance criterion"
expect_errors "a criterion without evidence" \
  '{"schema": "completion/v1", "status": "complete", "criteria": [{"criterion": "It works", "status": "met", "evidence": " "}], "remaining": []}' \
  "criterion 1 has no evidence"
expect_errors "a criterion without text or a known status" \
  '{"schema": "completion/v1", "status": "partial", "criteria": [{"criterion": "It works", "status": "met", "evidence": "a test"}, {"status": "yes", "evidence": "x"}], "remaining": ["more"]}' \
  "criterion 2 has no text" "criterion 2: status must be met, not_met, not_applicable, or pending"
# The status has to follow from the criteria and from what remains.
expect_errors "complete with a criterion that is not met" \
  '{"schema": "completion/v1", "status": "complete", "criteria": [{"criterion": "It works", "status": "not_met", "evidence": "not started"}], "remaining": []}' \
  "status is complete, but a criterion is not met"
expect_errors "complete with work that remains" \
  '{"schema": "completion/v1", "status": "complete", "criteria": [{"criterion": "It works", "status": "met", "evidence": "a test"}], "remaining": ["the documentation"]}' \
  "status is complete, but work remains"
expect_errors "partial without saying what is left" \
  '{"schema": "completion/v1", "status": "partial", "criteria": [{"criterion": "It works", "status": "met", "evidence": "a test"}], "remaining": []}' \
  "status is partial, but remaining does not say what is left"
expect_errors "remaining that is not a list of texts" \
  '{"schema": "completion/v1", "status": "partial", "criteria": [{"criterion": "It works", "status": "met", "evidence": "a test"}], "remaining": "steps 3 to 9"}' \
  "remaining must be a list of texts; an empty list when nothing remains"

# Evidence that appears at a later gate: pending is allowed there only, and
# the status is awaiting_evidence until it exists.
awaiting='{"schema": "completion/v1", "status": "awaiting_evidence", "criteria": [
  {"criterion": "Recipes can be searched", "status": "met", "evidence": "tests/test_search.py"},
  {"criterion": "CI passes on the pull request", "gate": "pr_ci", "status": "pending", "evidence": "after the pull request is published"},
  {"criterion": "main verifies after the merge", "gate": "post_merge", "status": "pending", "evidence": "the verify run on main"}
], "remaining": []}'
expect_errors "an awaiting_evidence record" "$awaiting"
expect_errors "a met criterion with an explicit gate" \
  '{"schema": "completion/v1", "status": "complete", "criteria": [{"criterion": "It works", "gate": "pr_ci", "status": "met", "evidence": "the CI run"}], "remaining": []}'
# The owner's approval is given on GitHub, never in a record that an agent
# writes: such a criterion can be pending (or not applicable), but not met.
expect_errors "owner_approval claimed as met" \
  '{"schema": "completion/v1", "status": "complete", "criteria": [{"criterion": "The owner approves", "gate": "owner_approval", "status": "met", "evidence": "the owner agreed in chat"}], "remaining": []}' \
  "criterion 1: owner_approval cannot be met in a record the implementer writes; it stays pending until the owner approves on GitHub"
expect_errors "owner_approval pending" \
  '{"schema": "completion/v1", "status": "awaiting_evidence", "criteria": [{"criterion": "The owner approves", "gate": "owner_approval", "status": "pending", "evidence": "approval of the final commit"}], "remaining": []}'
expect_errors "an unknown gate" \
  '{"schema": "completion/v1", "status": "partial", "criteria": [{"criterion": "It works", "gate": "later", "status": "met", "evidence": "x"}], "remaining": ["more"]}' \
  "criterion 1: gate must be implementation, pr_ci, owner_approval, or post_merge"
expect_errors "pending without a gate" \
  '{"schema": "completion/v1", "status": "partial", "criteria": [{"criterion": "It works", "status": "pending", "evidence": "x"}], "remaining": ["more"]}' \
  "criterion 1: pending is only for evidence of a later gate (pr_ci, owner_approval, or post_merge)"
expect_errors "pending at the implementation gate" \
  '{"schema": "completion/v1", "status": "awaiting_evidence", "criteria": [{"criterion": "It works", "gate": "implementation", "status": "pending", "evidence": "x"}], "remaining": []}' \
  "criterion 1: pending is only for evidence of a later gate (pr_ci, owner_approval, or post_merge)"
expect_errors "complete with pending evidence" \
  "$(printf '%s' "$awaiting" | sed 's/"awaiting_evidence"/"complete"/')" \
  "status is complete, but a criterion is pending; the status is awaiting_evidence until its evidence exists"
expect_errors "awaiting_evidence with nothing pending" \
  "$(printf '%s' "$complete" | sed 's/"complete"/"awaiting_evidence"/')" \
  "status is awaiting_evidence, but no criterion is pending"
expect_errors "awaiting_evidence with a criterion not met" \
  '{"schema": "completion/v1", "status": "awaiting_evidence", "criteria": [{"criterion": "It works", "status": "not_met", "evidence": "x"}, {"criterion": "CI", "gate": "pr_ci", "status": "pending", "evidence": "y"}], "remaining": []}' \
  "status is awaiting_evidence, but a criterion is not met"
expect_errors "awaiting_evidence with work that remains" \
  "$(printf '%s' "$awaiting" | sed 's/"remaining": \[\]/"remaining": ["the documentation"]/')" \
  "status is awaiting_evidence, but work remains"

# What a handoff note lists as remaining, in the shapes implementers write.
# expect_remaining <description> <note> <expected, lines joined by '|'>
expect_remaining() {
  local found

  printf '%b' "$2" >"$note"
  found="$(handoff_remaining "$note" | tr '\n' '|')"
  [[ "$found" == "$3" ]] || fail "$1: found '$found' instead of '$3'"
}

expect_remaining "bold labels on one line each" \
  '**Done:** steps 1 and 2.\n**Remaining:** steps 3 to 9.\n**Open questions:** none\n' "steps 3 to 9.|"
expect_remaining "headings with a list" \
  '## Done\nsteps 1 and 2\n\n## Remaining\n- step 3\n- step 4\n\n## Open questions\nnone\n' "step 3|step 4|"
expect_remaining "a list of labels" \
  '- **Done:** a\n- **In progress:** b\n- **Remaining:** the documentation\n- **Tried and rejected:** c\n' "the documentation|"
expect_remaining "plain labels" 'Done: all\nRemaining work:\n  - docs\nIn progress: none\n' "docs|"
expect_remaining "text on the lines after the label" '**Remaining:**\nstep 3\nstep 4\n' "step 3|step 4|"
for nothing in 'Remaining: none.' '**Remaining:** nothing' '- **Remaining:** n/a' '## Remaining\n\nNone\n' \
  '**Remaining:** -' 'Remaining: nothing remains.'; do
  expect_remaining "nothing remains: $nothing" "$nothing\n" ""
done
# A labelled line that says a category has nothing left is not work (#218);
# a label followed by anything else still is.
for nothing in 'FIX_NOW findings: none.' 'Open findings: nothing' '- Manual steps: n/a' \
  '- **FIX_NOW findings:** none' 'Follow-ups: no.' 'Deferred: -'; do
  expect_remaining "a labelled none line: $nothing" "**Remaining:**\n$nothing\n" ""
done
expect_remaining "a labelled none line after the label" '**Remaining:** FIX_NOW findings: none.\n' ""
expect_remaining "labelled work" \
  'Remaining: Plan steps 3 to 9\n' "Plan steps 3 to 9|"
expect_remaining "labelled work in a list" \
  '## Remaining\n- Tests: the integration test\n- Plan steps: 3 to 9\n- the documentation\n- Findings: none of them fixed yet\n- Docs: no section yet\n' \
  "Tests: the integration test|Plan steps: 3 to 9|the documentation|Findings: none of them fixed yet|Docs: no section yet|"
expect_remaining "labelled none lines beside work" \
  '**Remaining:**\n- FIX_NOW findings: none.\n- step 3\n' "step 3|"
# The clarification line of the implementer is a part of its own, not work
# that remains.
expect_remaining "the clarification line after the list" \
  '**Remaining:** none\n\n**Clarification:** clear, the Issue settles every decision.\n' ""
expect_remaining "the clarification line ends the list" \
  '## Remaining\n- step 3\n- **Clarification:** clear\n' "step 3|"
expect_remaining "a note reduced to one line" 'Issue 7 is complete.\n' ""
expect_remaining "the word in a sentence" 'The remaining tests pass, and remaining: is not a label here.\n' ""
expect_remaining "an empty note" '' ""
rm "$note"
[[ -z "$(handoff_remaining "$note")" ]] || fail "a missing note lists remaining work"

# The gate: the outcome on the first line, the reasons after it.
# expect_gate <description> <outcome> [reason-fragment...]
expect_gate() {
  local description="$1"
  local expected="$2"
  local gate

  gate="$(completion_gate "$root" 7)"
  [[ "$(printf '%s\n' "$gate" | sed -n 1p)" == "$expected" ]] ||
    fail "$description: the gate says '$(printf '%s\n' "$gate" | sed -n 1p)' instead of '$expected'"
  shift 2
  for fragment in "$@"; do
    grep -Fq "$fragment" <<<"$(printf '%s\n' "$gate" | sed 1d)" || fail "$description: the reasons lack '$fragment': $gate"
  done
}

rm -f "$record"
expect_gate "no record" missing "the implementer wrote no completion record (.agents/completion/7.json)"
printf 'broken\n' >"$record"
expect_gate "a record that cannot be read" invalid "it is not valid JSON"
printf '%s\n' "$partial" >"$record"
expect_gate "a partial record" partial "not met: The page works without JavaScript" "remaining: Plan steps 4 to 6"
printf '%s\n' "$partial" | sed 's/"partial"/"blocked"/' >"$record"
expect_gate "a blocked record" blocked "remaining: Plan steps 4 to 6"
printf '%s\n' "$complete" >"$record"
expect_gate "a complete record" complete
[[ "$(completion_gate "$root" 7)" == "complete" ]] || fail "a passed gate gives reasons"
# The record of another Issue says nothing about this one.
expect_gate "the record of another Issue" complete
[[ "$(completion_gate "$root" 8 | sed -n 1p)" == "missing" ]] || fail "the record of Issue 7 was used for Issue 8"

# Pending evidence of a later gate passes the gate as awaiting_evidence and
# names what is pending; a hidden implementation criterion cannot be pending.
printf '%s\n' "$awaiting" >"$record"
expect_gate "an awaiting_evidence record" awaiting_evidence \
  "pending at pr_ci: CI passes on the pull request" "pending at post_merge: main verifies after the merge"
[[ "$(completion_pending_gates "$root" 7 | tr '\n' ' ')" == "post_merge pr_ci " ]] ||
  fail "the pending gates are '$(completion_pending_gates "$root" 7 | tr '\n' ' ')'"
completion_ready awaiting_evidence || fail "awaiting_evidence does not let the work go on"
completion_ready complete || fail "complete does not let the work go on"
if completion_ready partial; then fail "partial lets the work go on"; fi
printf '%s\n' "$awaiting" | sed 's/"gate": "pr_ci", //' >"$record"
expect_gate "pending without a gate" invalid "criterion 2: pending is only for evidence of a later gate"
printf '%s\n' "$awaiting" >"$record"
printf '**Remaining:** step 3.\n' >"$note"
expect_gate "pending evidence and remaining work in the handoff note" partial "remaining: step 3."
rm "$note"

# A budget check of the verification configuration ('<name> [<group>]
# budget: <command>', scripts/verify.sh) is a measurement that never fails
# the verification, so it cannot be the evidence of a met criterion. The
# check is named as a whole word; a word that merely contains the name is not
# the check. Without a root, completion_errors cannot know the budgets.
mkdir -p "$root/scripts"
printf 'lint: true\nperf [code] budget: ./bench.sh\n' >"$root/scripts/verify.conf"
printf 'paths: scripts\nbundle-size budget: du -s dist\nselftest: ./tests/x.sh\n' >"$root/scripts/verify-workflow.conf"
[[ "$(completion_budget_checks "$root" | paste -sd, -)" == "bundle-size,perf" ]] ||
  fail "the budget checks of both files were not found: $(completion_budget_checks "$root" | paste -sd, -)"
cites_budget='{"schema": "completion/v1", "status": "complete", "criteria": [
  {"criterion": "The page is fast", "status": "met", "evidence": "the perf check of verify.sh passes"},
  {"criterion": "The bundle is small", "status": "met", "evidence": "verify.sh: bundle-size is within its target"}
], "remaining": []}'
printf '%s\n' "$cites_budget" >"$record"
expect_gate "evidence that cites a budget check" invalid \
  "criterion 1 cites the budget check 'perf' as evidence of a met criterion" \
  "criterion 2 cites the budget check 'bundle-size' as evidence of a met criterion"
[[ -z "$(completion_errors "$record")" ]] || fail "completion_errors without a root knew the budget checks"
names_but_not_the_check='{"schema": "completion/v1", "status": "complete", "criteria": [
  {"criterion": "The page is fast", "status": "met", "evidence": "tests/test_performance.py::test_perf_page passes; perf-tests/ cover it"},
  {"criterion": "The bundle is small", "status": "met", "evidence": "the size of dist/ is asserted by tests/test_bundle.py"}
], "remaining": []}'
printf '%s\n' "$names_but_not_the_check" >"$record"
expect_gate "evidence that only contains the name of a budget check in a word" complete
budget_for_not_met='{"schema": "completion/v1", "status": "partial", "criteria": [
  {"criterion": "The page is fast", "status": "not_met", "evidence": "the perf budget is exceeded; the optimization is not done"}
], "remaining": ["The optimization"]}'
printf '%s\n' "$budget_for_not_met" >"$record"
expect_gate "a budget named in the evidence of a criterion that is not met" partial
rm "$root/scripts/verify.conf" "$root/scripts/verify-workflow.conf"
printf '%s\n' "$cites_budget" >"$record"
expect_gate "the same record in a project without budget checks" complete
printf '%s\n' "$awaiting" >"$record"
completion_commit_lines "$root" 7 | grep -Fqx -- "- pending at post_merge: main verifies after the merge (the verify run on main)" ||
  fail "the commit lines do not name the gate of pending evidence"
completion_commit_lines "$root" 7 | grep -Fqx "Completion: awaiting_evidence" || fail "the commit lines do not state awaiting_evidence"
# A pending post_merge criterion also gets an exact line, a JSON string, so
# that record-post-merge.sh matches it whatever it or its evidence contains;
# other gates and other statuses get none.
[[ "$(completion_commit_lines "$root" 7 | grep -c '^Post-merge criterion: ')" -eq 1 ]] || fail "the commit lines do not hold exactly one post-merge criterion line"
completion_commit_lines "$root" 7 | grep -Fqx 'Post-merge criterion: "main verifies after the merge"' || fail "the post-merge criterion line is not the criterion as a JSON string"
printf '%s\n' '{"schema": "completion/v1", "status": "awaiting_evidence", "criteria": [{"criterion": "main verifies \"fast\" (production)", "gate": "post_merge", "status": "pending", "evidence": "the run (verify.sh)"}], "remaining": []}' >"$record"
completion_commit_lines "$root" 7 | grep -Fqx 'Post-merge criterion: "main verifies \"fast\" (production)"' || fail "quotes and parentheses of a criterion are not kept exactly in its JSON string"
printf '%s\n' "$awaiting" >"$record"
printf '%s\n' "$complete" >"$record"

# The handoff note outweighs a record that says complete.
printf '**Remaining:** steps 3 to 9.\n' >"$note"
expect_gate "a complete record against a note with remaining work" partial \
  "the completion record says complete, but the handoff note (.agents/handoffs/7.md) lists remaining work" \
  "remaining: steps 3 to 9."
printf 'Issue 7 is complete.\n' >"$note"
expect_gate "a complete record with a note that agrees" complete
# A labelled none line under Remaining says that a category has nothing left,
# so the gate agrees with the record (#218).
printf '**Remaining:**\nFIX_NOW findings: none.\n' >"$note"
expect_gate "a complete record with a labelled none line under Remaining" complete
printf 'Issue 7 is complete.\n' >"$note"

# The statement that finish-feature.sh puts in the commit message.
[[ "$(completion_commit_lines "$root" 7)" == "Completion: complete
- met: Recipes can be searched (tests/test_search.py)
- not applicable: Works offline (the Issue dropped it in a comment)" ]] || fail "the completion statement of a complete record is wrong"
printf '%s\n' "$partial" >"$record"
[[ "$(completion_commit_lines "$root" 7)" == "Completion: partial
- met: Recipes can be searched (tests/test_search.py)
- not met: The page works without JavaScript (not started; plan step 4)
- remaining: Plan steps 4 to 6" ]] || fail "the completion statement of a partial record is wrong"

# Closing keywords. GitHub closes an Issue on one of them next to its number,
# so text taken over into a pull request that may not close the Issue is
# rewritten, and a commit that carries one is found.
closes() {
  grep -Eiq "$(completion_closing_pattern 12)" <<<"$(printf '%s\n' "$1")"
}
for closing in "Closes #12" "closes #12." "CLOSED #12" "Fix #12" "fixes: #12" "This fixed #12, see below" \
  "resolve #12" "Resolves owner/repo#12" "resolved https://github.com/owner/repo/issues/12" "(closes #12)"; do
  closes "$closing" || fail "a closing keyword was not recognised: $closing"
done
for harmless in "Refs #12" "Closes #123" "Closes #1" "This encloses #12" "prefixes #12" "See #12" "closes the gap in #12" \
  "Closes owner/repo#120"; do
  if closes "$harmless"; then fail "text without a closing keyword for Issue 12 was taken for one: $harmless"; fi
done
[[ "$(printf '%s\n' "Closes #12" "closes: #12." "This fixes #12 and Fixes #123, resolved owner/repo#12; see #12" \
  "Fixed https://github.com/o/r/issues/12" "Refs #12" "This encloses #12" | completion_neutralize_closing 12)" == "Refs #12
Refs #12.
This Refs #12 and Fixes #123, Refs owner/repo#12; see #12
Refs https://github.com/o/r/issues/12
Refs #12
This encloses #12" ]] || fail "closing keywords were not turned into references as expected"
if printf '%s\n' "Closes #12" "Fixes #12 and resolves #12" | completion_neutralize_closing 12 |
  grep -Eiq "$(completion_closing_pattern 12)"; then
  fail "a closing keyword survived the rewriting"
fi

# The summary of the changes, which an unattended commit needs.
if completion_summary_present "$root" 7; then fail "a missing summary counts as present"; fi
printf 'Some text without a list.\n' >"$root/.agents/summaries/7.md"
if completion_summary_present "$root" 7; then fail "a summary without a list line counts as present"; fi
printf -- '- Adds the search.\n' >"$root/.agents/summaries/7.md"
completion_summary_present "$root" 7 || fail "a summary with a list line does not count"

echo "completion tests passed"
