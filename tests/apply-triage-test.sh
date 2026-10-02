#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/apply-triage-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "apply-triage test failed: $*" >&2
  exit 1
}

source "$source_root/tests/lib-fakes.sh"
make_fake_agents "$tmp/bin"

cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "auth status") exit 0 ;;
  "issue view") echo "13"; exit 0 ;;
esac
echo "Unexpected gh invocation: $*" >&2
exit 1
GH
chmod +x "$tmp/bin/gh"

review=".agents/reviews/feature-13-apply-test-review-01.json"
triage=".agents/triage/feature-13-apply-test-review-01-triage.json"

# Creates a repository on feature/13-apply-test with a stored review and its
# approved triage. Its verification passes unless a check is replaced.
setup_repo() {
  local repo="$tmp/$1"

  mkdir -p "$repo/.agents/reviews" "$repo/.agents/triage"
  copy_workflow "$repo"
  printf 'triage-implementer: codex model-i\n' >"$repo/.agents/agents.conf"
  printf 'marker: test -f AGENTS.md\n' >"$repo/scripts/verify.conf"
  printf '# Agents\n' >"$repo/AGENTS.md"

  jq -n '{
    schema: "review/v1", issue: 13, round: 1, branch: "feature/13-apply-test", base: "main",
    merge_base: "aaaa", head: "bbbb", reviewed_tree: "cccc",
    reviewer: {agent: "claude", model: "model-r"}, created_at: "2026-01-01T00:00:00Z",
    verdict: "CHANGES_REQUIRED", limitations: "",
    findings: [
      {id: "C1", severity: "critical", title: "Correctness regression", evidence: "src/a.sh:3", impact: "Wrong result.", recommendation: "Fix the branch."},
      {id: "MIN1", severity: "minor", title: "Deferred cleanup", evidence: "src/a.sh:9", impact: "Clutter.", recommendation: "Clean up."},
      {id: "S1", severity: "suggestion", title: "Accepted rename", evidence: "src/a.sh:8", impact: "Readability.", recommendation: "Rename."}
    ]
  }' >"$repo/$review"

  jq -n --arg review "$review" '{
    schema: "triage/v1", source_review: $review, issue: 13, reviewed_tree: "cccc",
    review_verdict: "CHANGES_REQUIRED", triage: {agent: "claude", model: "model-t"},
    approved_at: "2026-01-01T10:00:00Z",
    decisions: [
      {finding_id: "C1", severity: "critical", title: "Correctness regression", decision: "FIX_NOW", rationale: "Correctness blocks the feature.", followup: null},
      {finding_id: "MIN1", severity: "minor", title: "Deferred cleanup", decision: "DEFER", rationale: "Follow-up work.",
       followup: {title: "[#13][R01][MIN1] Deferred cleanup", recommended_action: "Handle separately.", acceptance_criteria: ["Done."], issue_number: 99, issue_url: "https://github.com/example/project/issues/99"}},
      {finding_id: "S1", severity: "suggestion", title: "Accepted rename", decision: "ACCEPT", rationale: "Adequate.", followup: null}
    ]
  }' >"$repo/$triage"

  git -C "$repo" init -q -b main
  git -C "$repo" config user.name "Apply Test"
  git -C "$repo" config user.email "apply-test@example.com"
  git -C "$repo" add .
  git -C "$repo" commit -qm "Seed project"
  git -C "$repo" switch -q -c feature/13-apply-test
  record_reviewed_tree "$repo" "$repo/$review" "$repo/$triage"

  printf '%s\n' "$repo"
}

edit_triage() {
  local repo="$1"
  local filter="$2"

  jq "$filter" "$repo/$triage" >"$repo/$triage.tmp"
  mv "$repo/$triage.tmp" "$repo/$triage"
}

run_apply() {
  local repo="$1"
  local answer="$2"
  shift 2

  (
    cd "$repo"
    printf '%s\n' "$answer" |
      PATH="$tmp/bin:/usr/bin:/bin" MOCK_AGENT_LOG="$repo.log" ./scripts/apply-triage.sh "$@"
  ) >"$repo.out" 2>&1
}

expect_rejected() {
  local repo="$1"
  local description="$2"
  shift 2

  if run_apply "$repo" y "$@"; then
    cat "$repo.out" >&2
    fail "expected failure: $description"
  fi
  [[ ! -e "$repo.log" ]] || fail "an implementation agent was started although: $description"
}

# After confirmation, a write-capable agent receives exactly the FIX_NOW
# findings, and the result is verified.
repo="$(setup_repo apply)"
run_apply "$repo" y "$triage" || {
  cat "$repo.out" >&2
  fail "applying an approved triage failed"
}
grep -Fq -- "--sandbox workspace-write --ask-for-approval never --model model-i" "$repo.log" ||
  fail "implementation agent was not started write-capable with the configured model"
grep -Fq "C1. Correctness regression" "$repo.log" || fail "the FIX_NOW finding was not passed to the agent"
if grep -Fq "Deferred cleanup" "$repo.log" || grep -Fq "Accepted rename" "$repo.log"; then
  fail "the implementation agent received a finding that is not FIX_NOW"
fi
grep -Fq "Verification passed." "$repo.out" || fail "the result was not verified"

# Declining, and a triage without FIX_NOW findings, start no agent.
repo="$(setup_repo decline)"
run_apply "$repo" n "$triage" || fail "declined apply returned an error"
[[ ! -e "$repo.log" ]] || fail "an agent was started after declining"

repo="$(setup_repo nothing-to-fix)"
jq '.verdict = "PASS_WITH_MINOR_FINDINGS" | del(.findings[0])' "$repo/$review" >"$repo/$review.tmp"
mv "$repo/$review.tmp" "$repo/$review"
edit_triage "$repo" '.review_verdict = "PASS_WITH_MINOR_FINDINGS" | del(.decisions[0])'
run_apply "$repo" y "$triage" || fail "a triage without FIX_NOW findings returned an error"
[[ ! -e "$repo.log" ]] || fail "an agent was started without FIX_NOW findings"

# Unapproved, mismatching, or misplaced triage artifacts are rejected.
repo="$(setup_repo unapproved)"
edit_triage "$repo" 'del(.approved_at)'
expect_rejected "$repo" "the triage is not approved" "$triage"

# An edited artifact cannot weaken a decision: the stored triage is checked
# with the same rules as the triage agent's output.
repo="$(setup_repo critical-accepted)"
edit_triage "$repo" '.decisions[0].decision = "ACCEPT"'
expect_rejected "$repo" "a Critical finding is not FIX_NOW" "$triage"

repo="$(setup_repo no-followup-issue)"
edit_triage "$repo" '.decisions[1].followup.issue_number = null | .decisions[1].followup.issue_url = null'
expect_rejected "$repo" "a deferred finding has no follow-up Issue" "$triage"

repo="$(setup_repo no-rationale)"
edit_triage "$repo" '.decisions[0].rationale = ""'
expect_rejected "$repo" "a decision has no rationale" "$triage"

repo="$(setup_repo invalid-review)"
jq '.findings[0].evidence = ""' "$repo/$review" >"$repo/$review.tmp"
mv "$repo/$review.tmp" "$repo/$review"
expect_rejected "$repo" "the source review is invalid" "$triage"

# Script-owned fields of stored artifacts are constrained, so they cannot be
# used as paths or contradict the review.
repo="$(setup_repo unsafe-id)"
jq '.findings[2].id = "../S1"' "$repo/$review" >"$repo/$review.tmp"
mv "$repo/$review.tmp" "$repo/$review"
expect_rejected "$repo" "a finding id is not a script-assigned identifier" "$triage"

repo="$(setup_repo bad-round)"
jq '.round = 1.5' "$repo/$review" >"$repo/$review.tmp"
mv "$repo/$review.tmp" "$repo/$review"
expect_rejected "$repo" "the review round is not a positive integer" "$triage"

repo="$(setup_repo bad-issue-reference)"
edit_triage "$repo" '.decisions[1].followup.issue_number = -0.5 | .decisions[1].followup.issue_url = "not an issue"'
expect_rejected "$repo" "a follow-up Issue reference is invalid" "$triage"

repo="$(setup_repo missing-metadata)"
edit_triage "$repo" 'del(.triage) | del(.decisions[2].followup)'
expect_rejected "$repo" "triage metadata and a required field are missing" "$triage"

repo="$(setup_repo copied-title)"
edit_triage "$repo" '.decisions[0].title = "Something else"'
expect_rejected "$repo" "the triage misstates a finding of the review" "$triage"

repo="$(setup_repo unknown-finding)"
edit_triage "$repo" '.decisions[0].finding_id = "C9"'
expect_rejected "$repo" "a decision does not map to the review" "$triage"

repo="$(setup_repo undecided-finding)"
edit_triage "$repo" 'del(.decisions[2])'
expect_rejected "$repo" "a finding of the review has no decision" "$triage"

repo="$(setup_repo other-issue)"
edit_triage "$repo" '.issue = 99'
expect_rejected "$repo" "triage and review reference different Issues" "$triage"

repo="$(setup_repo missing-review)"
rm "$repo/$review"
expect_rejected "$repo" "the source review is missing" "$triage"

repo="$(setup_repo wrong-branch)"
git -C "$repo" switch -q -c feature/14-other
expect_rejected "$repo" "the branch belongs to another Issue" "$triage"

repo="$(setup_repo preconditions)"
printf '# report\n' >"$repo/.agents/triage/report.md"
expect_rejected "$repo" "the input is the generated report" ".agents/triage/report.md"
expect_rejected "$repo" "the triage does not exist" ".agents/triage/missing.json"
expect_rejected "$repo" "the agent is unsupported" "$triage" --agent copilot --model model-x

# Fixes apply only to the reviewed content; a stale review is refused.
repo="$(setup_repo stale)"
printf 'changed after the review\n' >>"$repo/AGENTS.md"
expect_rejected "$repo" "the review is stale" "$triage"
grep -Fq "stale" "$repo.out" || fail "a stale review was not reported as stale"

# A failing agent is reported after verification still ran.
repo="$(setup_repo agent-fails)"
if MOCK_AGENT_EXIT=7 run_apply "$repo" y "$triage"; then
  fail "a failed implementation agent returned success"
fi
grep -Fq "== Verification summary ==" "$repo.out" || fail "verification did not run after a failed agent"

# An agent that changes or removes the protected artifacts is rejected.
repo="$(setup_repo edits-triage)"
if MOCK_AGENT_ACTION="chmod 600 '$repo/$triage'" run_apply "$repo" y "$triage" --agent claude --model model-c; then
  fail "a changed triage artifact returned success"
fi
grep -Fq -- "--permission-mode acceptEdits --model model-c" "$repo.log" ||
  fail "overridden Claude agent was not started write-capable with its model"

repo="$(setup_repo deletes-review)"
if MOCK_AGENT_ACTION="rm '$repo/$review'" run_apply "$repo" y "$triage"; then
  fail "a deleted review artifact returned success"
fi

# A failing verification fails the run.
repo="$(setup_repo verification-fails)"
printf 'broken: false\n' >"$repo/scripts/verify.conf"
git -C "$repo" commit -qam "Break verification"
record_reviewed_tree "$repo" "$repo/$review" "$repo/$triage"
if run_apply "$repo" y "$triage"; then
  fail "a failed verification returned success"
fi

echo "apply-triage tests passed"
