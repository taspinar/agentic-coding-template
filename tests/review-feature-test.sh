#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/review-feature-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "review-feature test failed: $*" >&2
  exit 1
}

mkdir -p "$tmp/bin"

cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-} ${2:-}" == "auth status" ]]; then
  exit "${MOCK_GH_AUTH_EXIT:-0}"
fi
if [[ "${1:-} ${2:-}" == "issue view" ]]; then
  printf 'Title: Test feature\n\nThe marker file must exist.\n'
  exit 0
fi
echo "Unexpected gh invocation: $*" >&2
exit 1
GH

source "$source_root/tests/lib-fakes.sh"
make_fake_agents "$tmp/bin"
chmod +x "$tmp/bin/gh"

finding() {
  printf '{"severity": "%s", "title": "%s", "evidence": "marker.txt:1", "impact": "The marker is never read.", "recommendation": "Read the marker."}' "$1" "$2"
}
valid_result="{\"architecture_impact\": {\"level\": \"minor\", \"rationale\": \"Stays within the accepted architecture.\", \"checked_against\": []}, \"verdict\": \"CHANGES_REQUIRED\", \"limitations\": \"Tests were not run.\", \"findings\": [$(finding minor "Marker name is vague"), $(finding major "Marker content is unchecked")]}"
# A verdict that does not follow from the findings.
inconsistent_result="{\"architecture_impact\": {\"level\": \"minor\", \"rationale\": \"Stays within the accepted architecture.\", \"checked_against\": []}, \"verdict\": \"CHANGES_REQUIRED\", \"limitations\": \"\", \"findings\": [$(finding minor "Marker name is vague")]}"
export MOCK_OUTPUT="$valid_result"

# Creates a repository on feature/7-marker with one committed, one modified,
# and one untracked file relative to main.
setup_repo() {
  local repo="$tmp/$1"

  mkdir -p "$repo"
  copy_workflow "$repo"
  printf 'reviewer: claude model-r\n' >"$repo/.agents/agents.conf"
  printf 'base content\n' >"$repo/feature.txt"
  mkdir -p "$repo/docs"
  printf '*.log\n.agents/verification/\n' >"$repo/.gitignore"
  # Each verification run leaves one line in an ignored file.
  printf 'count: echo run >>verify-count.log\n' >"$repo/scripts/verify.conf"
  printf 'tracked although ignored\n' >"$repo/tracked.log"

  git -C "$repo" init -q -b main
  git -C "$repo" config user.name "Review Test"
  git -C "$repo" config user.email "review-test@example.com"
  git -C "$repo" add .
  git -C "$repo" add -f tracked.log
  git -C "$repo" commit -qm "Seed project"
  git -C "$repo" switch -q -c feature/7-marker
  printf 'committed change\n' >>"$repo/feature.txt"
  git -C "$repo" commit -qam "Committed feature work"
  printf 'uncommitted change\n' >>"$repo/feature.txt"
  printf 'untracked marker\n' >"$repo/marker.txt"

  printf '%s\n' "$repo"
}

run_review() {
  local repo="$1"
  shift

  (
    cd "$repo"
    PATH="$tmp/bin:/usr/bin:/bin" MOCK_AGENT_LOG="$repo.log" \
      ./scripts/review-feature.sh "$@"
  ) >"$repo.out" 2>&1
}

expect_no_review() {
  local repo="$1"
  local description="$2"
  shift 2

  if run_review "$repo" "$@"; then
    cat "$repo.out" >&2
    fail "expected failure: $description"
  fi
  if compgen -G "$repo/.agents/reviews/*" >/dev/null; then
    fail "a review was stored although: $description"
  fi
}

# The script stores the validated result as JSON with script-assigned finding
# identifiers and a generated report; the reviewer runs read-only and receives
# the Issue and the complete diff on standard input.
repo="$(setup_repo claude)"
run_review "$repo" 7 || {
  cat "$repo.out" >&2
  fail "review with the configured agent failed"
}
artifact="$repo/.agents/reviews/feature-7-marker-review-01"
[[ -f "$artifact.json" && -f "$artifact.md" ]] || fail "the script did not store the review and its report"
[[ "$(jq -c '[.issue, .round, .verdict, (.findings | map(.id))]' "$artifact.json")" == '[7,1,"CHANGES_REQUIRED",["MIN1","M1"]]' ]] ||
  fail "stored review lacks the Issue, round, verdict, or finding identifiers"
[[ "$(jq -r '.reviewed_tree | length' "$artifact.json")" -eq 40 ]] || fail "stored review lacks the reviewed tree"
grep -Fq "M1. Marker content is unchecked" "$artifact.md" || fail "generated report lacks a finding"
grep -Fq -- "--strict-mcp-config --permission-mode dontAsk --tools Read,Glob,Grep" "$repo.log" ||
  fail "Claude reviewer was not restricted to read tools"
grep -Fq -- "--json-schema" "$repo.log" || fail "Claude reviewer was not given the schema"
grep -Fq -- "--model model-r" "$repo.log" || fail "configured model was not passed to the reviewer"
grep -Fq "The marker file must exist." "$repo.log.stdin" || fail "Issue was not supplied to the reviewer"
for change in "+committed change" "+uncommitted change" "+untracked marker"; do
  grep -Fqx -- "$change" "$repo.log.stdin" || fail "diff supplied to the reviewer lacks: $change"
done

# A second round is numbered and points the reviewer at the previous review,
# which is not part of the reviewed diff.
run_review "$repo" 7 --agent codex --model model-c || {
  cat "$repo.out" >&2
  fail "re-review with an overridden agent failed"
}
[[ "$(jq '.round' "$repo/.agents/reviews/feature-7-marker-review-02.json")" -eq 2 ]] || fail "re-review was not numbered"
grep -Fq "feature-7-marker-review-01.json" "$repo.log" || fail "re-review did not reference the previous review"
grep -Fq -- "--sandbox read-only" "$repo.log" || fail "Codex reviewer was not sandboxed read-only"
grep -Fq -- "--output-schema" "$repo.log" || fail "Codex reviewer was not given the schema"
if grep -Fq "Marker content is unchecked" "$repo.log.stdin"; then
  fail "previous review artifact was included in the reviewed diff"
fi

# A review without findings is valid.
repo="$(setup_repo no-findings)"
MOCK_OUTPUT='{"architecture_impact": {"level": "minor", "rationale": "Stays within the accepted architecture.", "checked_against": []}, "verdict": "PASS", "limitations": "", "findings": []}' run_review "$repo" 7 || {
  cat "$repo.out" >&2
  fail "a review without findings was rejected"
}
[[ "$(jq -c '[.verdict, (.findings | length)]' "$repo/.agents/reviews/feature-7-marker-review-01.json")" == '["PASS",0]' ]] ||
  fail "a review without findings was not stored as PASS"

# A reviewer that changes or creates files is detected.
repo="$(setup_repo modify)"
MOCK_AGENT_ACTION="printf 'changed by the reviewer\n' >>'$repo/feature.txt'" \
  expect_no_review "$repo" "the reviewer modified a file" 7
grep -Fq "modified the working tree" "$repo.out" || fail "modification was not reported"

repo="$(setup_repo create)"
MOCK_AGENT_ACTION="printf 'created by the reviewer\n' >'$repo/reviewer-note.txt'" \
  expect_no_review "$repo" "the reviewer created a file" 7

# A reviewer that changes an earlier review artifact is detected, although
# artifacts are not part of the reviewed content.
repo="$(setup_repo modifies-artifact)"
run_review "$repo" 7 || {
  cat "$repo.out" >&2
  fail "the first review round failed"
}
earlier="$repo/.agents/reviews/feature-7-marker-review-01.json"
if MOCK_AGENT_ACTION="printf ' ' >>'$earlier'" run_review "$repo" 7; then
  fail "a reviewer that changed an earlier review artifact was accepted"
fi
[[ ! -e "$repo/.agents/reviews/feature-7-marker-review-02.json" ]] ||
  fail "a review was stored although the reviewer changed an earlier review artifact"

# A failed reviewer stores nothing.
repo="$(setup_repo agent-fails)"
MOCK_AGENT_EXIT=43 expect_no_review "$repo" "the reviewer failed" 7

# An invalid result is retried once: it is accepted when the retry is valid
# and rejected when it is not.
repo="$(setup_repo retry)"
MOCK_OUTPUT_FIRST="$inconsistent_result" run_review "$repo" 7 || {
  cat "$repo.out" >&2
  fail "a valid result after one invalid result was rejected"
}
[[ "$(grep -c '^AGENT=' "$repo.log")" -eq 2 ]] || fail "an invalid result was not retried exactly once"
[[ "$(grep -c 'previous result was rejected' "$repo.log")" -eq 1 ]] ||
  fail "the retry did not tell the reviewer why its result was rejected"
grep -Fq "requires a critical or major finding" "$repo.log" || fail "the retry prompt lacks the rejection reason"

# The reviewer may not supply script-owned fields or more than one result.
owned_fields_result="$(jq '. + {issue: 999} | .findings[0].id = "agent-id"' <<<"$valid_result")"
pass_result='{"architecture_impact": {"level": "minor", "rationale": "Stays within the accepted architecture.", "checked_against": []}, "verdict": "PASS", "limitations": "", "findings": []}'
minor_only_result="{\"architecture_impact\": {\"level\": \"minor\", \"rationale\": \"Stays within the accepted architecture.\", \"checked_against\": []}, \"verdict\": \"PASS_WITH_MINOR_FINDINGS\", \"limitations\": \"\", \"findings\": [$(finding minor "Marker name is vague")]}"

# One invalid result per rule, each derived from a valid result.
invalid_results=(
  "not json"
  "$pass_result $pass_result"
  '{"architecture_impact": {"level": "minor", "rationale": "Stays within the accepted architecture.", "checked_against": []}, "verdict": "PASS"}'
  "$owned_fields_result"
  "$inconsistent_result"
  "$(jq '.verdict = "APPROVED"' <<<"$valid_result")"
  "$(jq '.findings[0].severity = "blocker"' <<<"$valid_result")"
  "$(jq '.findings[1].evidence = " "' <<<"$valid_result")"
  "$(jq '.verdict = "PASS"' <<<"$minor_only_result")"
  "$(jq '.verdict = "PASS_WITH_MINOR_FINDINGS"' <<<"$valid_result")"
  "$(jq '.verdict = "PASS_WITH_MINOR_FINDINGS"' <<<"$pass_result")"
  # A feature review must classify the impact on the architecture, validly.
  "$(jq 'del(.architecture_impact)' <<<"$pass_result")"
  "$(jq '.architecture_impact.level = "small"' <<<"$pass_result")"
  "$(jq '.architecture_impact.rationale = " "' <<<"$pass_result")"
  "$(jq 'del(.architecture_impact.checked_against)' <<<"$pass_result")"
  "$(jq '.architecture_impact = "minor"' <<<"$pass_result")"
)
for index in "${!invalid_results[@]}"; do
  invalid_result="${invalid_results[$index]}"
  repo="$(setup_repo "invalid-$index")"
  MOCK_OUTPUT="$invalid_result" expect_no_review "$repo" "the result is invalid: $invalid_result" 7
  [[ "$(grep -c '^AGENT=' "$repo.log")" -eq 2 ]] || fail "an invalid result was not retried exactly once"
done

# From a subdirectory, the snapshot still contains tracked files that match an
# ignore rule, so they are not reviewed as deletions.
repo="$(setup_repo subdirectory)"
(
  cd "$repo/docs"
  PATH="$tmp/bin:/usr/bin:/bin" MOCK_AGENT_LOG="$repo.log" ../scripts/review-feature.sh 7
) >"$repo.out" 2>&1 || {
  cat "$repo.out" >&2
  fail "review from a subdirectory failed"
}
if grep -Fq "tracked.log" "$repo.log.stdin"; then
  fail "an unchanged tracked file matching an ignore rule appeared in the reviewed diff"
fi

# The review starts only on content that passes verification, and records
# that. A pass for the same content is not run a second time.
verification_runs() {
  grep -c . "$1/verify-count.log" 2>/dev/null || true
}

repo="$(setup_repo verified)"
run_review "$repo" 7 || {
  cat "$repo.out" >&2
  fail "a review of verified content failed"
}
[[ "$(verification_runs "$repo")" -eq 1 ]] || fail "verification did not run once before the review"
review="$repo/.agents/reviews/feature-7-marker-review-01.json"
[[ "$(jq -r '.verification.status' "$review")" == "passed" ]] || fail "the review does not record the passed verification"
grep -Fq "Verification: passed for the reviewed tree" "${review%.json}.md" ||
  fail "the report does not show the verification"
run_review "$repo" 7 || fail "a second review of the same content failed"
[[ "$(verification_runs "$repo")" -eq 1 ]] || fail "verification ran again for unchanged content"
printf 'another change\n' >>"$repo/feature.txt"
run_review "$repo" 7 || fail "a review of changed content failed"
[[ "$(verification_runs "$repo")" -eq 2 ]] || fail "verification did not run again for changed content"

repo="$(setup_repo verification-fails)"
printf 'broken: false\n' >"$repo/scripts/verify.conf"
expect_no_review "$repo" "verification fails" 7
[[ ! -e "$repo.log" ]] || fail "a reviewer started although verification failed"
grep -Fq "FAIL  broken" "$repo.out" || fail "the failing check was not named"
grep -Fq -- "--unverified" "$repo.out" || fail "the refusal did not name the override"

# A check that passes but changes a file verified other content than the
# review would cover, so no review starts.
repo="$(setup_repo check-changes-content)"
printf 'rewrite: echo changed >>feature.txt\n' >"$repo/scripts/verify.conf"
expect_no_review "$repo" "a check changed the content under review" 7
[[ ! -e "$repo.log" ]] || fail "a reviewer started although a check changed the content"
grep -Fq "the content changed while verification ran" "$repo.out" || fail "the changed content was not reported"

# --unverified reviews anyway and records the reason instead of a pass.
run_review "$repo" 7 --unverified "the build fails and the cause is unclear" || {
  cat "$repo.out" >&2
  fail "a review with --unverified failed"
}
review="$repo/.agents/reviews/feature-7-marker-review-01.json"
[[ "$(jq -r '.verification | "\(.status): \(.reason)"' "$review")" == "not-verified: the build fails and the cause is unclear" ]] ||
  fail "the review does not record why it was not verified"
grep -Fq "Verification: NOT verified (the build fails and the cause is unclear)" "${review%.json}.md" ||
  fail "the report does not show that the review was not verified"
if run_review "$repo" 7 --unverified " "; then fail "--unverified without a reason was accepted"; fi

# --changes reviews only what changed since the previous round. The reviewer
# gets that difference, not the complete feature, with the findings of the
# previous round and what was decided about them; the review records its
# scope.
repo="$(setup_repo changes-only)"
run_review "$repo" 7 || fail "the complete first round failed"
first="$repo/.agents/reviews/feature-7-marker-review-01.json"
[[ "$(jq -r '.scope.kind' "$first")" == "full" ]] || fail "a complete review does not record its scope"
# add_first_triage <repo>: an approved triage of round 1 that fixes the major
# finding and accepts the minor one.
add_first_triage() {
  mkdir -p "$1/.agents/triage"
  jq '{
    schema: "triage/v1", source_review: ".agents/reviews/feature-7-marker-review-01.json", issue,
    reviewed_tree, review_verdict: .verdict, triage: {agent: "codex", model: "model-t"},
    approved_at: "2026-01-02T00:00:00Z",
    decisions: [.findings[] | {finding_id: .id, severity, title,
      decision: (if .severity == "major" then "FIX_NOW" else "ACCEPT" end),
      rationale: (if .severity == "major" then "The content must be checked." else "The name is fine." end),
      followup: null}]
  }' "$1/.agents/reviews/feature-7-marker-review-01.json" >"$1/.agents/triage/feature-7-marker-review-01-triage.json"
}
add_first_triage "$repo"
printf 'the fix\n' >>"$repo/feature.txt"
rm -f "$repo.log" "$repo.log.stdin"
run_review "$repo" 7 --changes || {
  cat "$repo.out" >&2
  fail "a review of changes only failed"
}
second="$repo/.agents/reviews/feature-7-marker-review-02.json"
[[ "$(jq -c '[.round, .scope.kind, .scope.since_round]' "$second")" == '[2,"changes",1]' ]] ||
  fail "the review of changes does not record its scope"
[[ "$(jq -r '.scope.base_tree' "$second")" == "$(jq -r '.reviewed_tree' "$first")" ]] ||
  fail "the review of changes does not build on the content of the previous round"
grep -Fq "Scope: ONLY the changes since round 1" "${second%.json}.md" || fail "the report does not show the limited scope"
grep -Fqx "+the fix" "$repo.log.stdin" || fail "the change since the previous round was not supplied"
if grep -Fq "untracked marker" "$repo.log.stdin"; then
  fail "content that did not change since the previous round was supplied"
fi
if grep -Fq "diff --git a/marker.txt" "$repo.log.stdin"; then fail "an unchanged file was supplied as changed"; fi
grep -Fq "### M1 [major] Marker content is unchecked" "$repo.log.stdin" || fail "the previous findings were not supplied"
grep -Fq "Decision: FIX_NOW (The content must be checked.)" "$repo.log.stdin" || fail "the decision to fix was not supplied"
grep -Fq "Decision: ACCEPT (The name is fine.)" "$repo.log.stdin" || fail "the accepted finding was not supplied with its decision"
grep -Fq "This is a review of changes only" "$repo.log" || fail "the reviewer was not told that it reviews changes only"

# Without the option a later round reviews the complete feature again.
printf 'more\n' >>"$repo/feature.txt"
rm -f "$repo.log" "$repo.log.stdin"
run_review "$repo" 7 || fail "a complete third round failed"
third="$repo/.agents/reviews/feature-7-marker-review-03.json"
[[ "$(jq -r '.scope.kind' "$third")" == "full" ]] || fail "a round without --changes is not a complete review"
grep -Fq "untracked marker" "$repo.log.stdin" || fail "a complete later round was not given the complete diff"

# Findings that were never triaged are supplied as to be fixed.
repo="$(setup_repo changes-untriaged)"
run_review "$repo" 7 || fail "the complete first round failed"
printf 'the fix\n' >>"$repo/feature.txt"
rm -f "$repo.log.stdin"
run_review "$repo" 7 --changes || fail "a review of changes without a triage failed"
grep -Fq "The findings were not triaged; treat each one as to be fixed." "$repo.log.stdin" ||
  fail "untriaged findings were not supplied as to be fixed"

# A triage that is not approved, or that belongs to other content, does not
# get to say that a finding was accepted: every finding counts as to be fixed.
for defect in 'del(.approved_at)' '.reviewed_tree = "0123456789012345678901234567890123456789"' '(.decisions[] | select(.severity == "major") | .decision) = "ACCEPT"'; do
  repo="$(setup_repo "changes-bad-triage-$(printf '%s' "$defect" | cksum | cut -d' ' -f1)")"
  run_review "$repo" 7 || fail "the complete first round failed"
  add_first_triage "$repo"
  triage_file="$repo/.agents/triage/feature-7-marker-review-01-triage.json"
  jq "$defect" "$triage_file" >"$triage_file.tmp" && mv "$triage_file.tmp" "$triage_file"
  printf 'the fix\n' >>"$repo/feature.txt"
  rm -f "$repo.log.stdin"
  run_review "$repo" 7 --changes || fail "a review of changes with an invalid triage failed"
  grep -Fq "treat each one as to be fixed" "$repo.log.stdin" || fail "an invalid triage was not ignored: $defect"
  if grep -Fq "Decision: ACCEPT" "$repo.log.stdin"; then fail "an invalid triage told the reviewer to skip a finding: $defect"; fi
  grep -Fq "its decisions are not used" "$repo.out" || fail "the ignored triage was not reported: $defect"
done

# --changes needs a previous round with the same base whose content is still
# known, and a change since then. Otherwise no review starts.
expect_no_changes_review() {
  local repo="$1"
  local description="$2"
  local message="$3"

  rm -f "$repo.log"
  if run_review "$repo" 7 --changes; then
    cat "$repo.out" >&2
    fail "a review of changes started although: $description"
  fi
  grep -Fq "$message" "$repo.out" || {
    cat "$repo.out" >&2
    fail "the refusal did not say: $message"
  }
  [[ ! -e "$repo.log" ]] || fail "a reviewer started although: $description"
  [[ ! -e "$repo/.agents/reviews/feature-7-marker-review-02.json" ]] || fail "a review was stored although: $description"
}

repo="$(setup_repo changes-first-round)"
expect_no_changes_review "$repo" "there is no previous round" "this is round 1"
[[ "$(verification_runs "$repo")" -eq 0 ]] || fail "verification ran before --changes was refused in round 1"

repo="$(setup_repo changes-nothing)"
run_review "$repo" 7 || fail "the complete first round failed"
expect_no_changes_review "$repo" "nothing changed" "nothing changed since round 1"

printf 'the fix\n' >>"$repo/feature.txt"
first="$repo/.agents/reviews/feature-7-marker-review-01.json"
cp "$first" "$tmp/first.json"
jq '.merge_base = "0000000000000000000000000000000000000000"' "$tmp/first.json" >"$first"
expect_no_changes_review "$repo" "the base of the branch changed" "the base of the branch changed since round 1"
jq '.reviewed_tree = "0123456789012345678901234567890123456789"' "$tmp/first.json" >"$first"
expect_no_changes_review "$repo" "the earlier content is unknown" "is no longer available"
# A scope that is not an object is rejected as an invalid review, not with a
# raw tool error.
jq '.scope = "changes"' "$tmp/first.json" >"$first"
expect_no_changes_review "$repo" "the previous review has a malformed scope" "scope must be full"

# Invalid invocations fail before a reviewer starts.
repo="$(setup_repo preconditions)"
expect_no_review "$repo" "the branch belongs to another Issue" 8
expect_no_review "$repo" "the agent is unsupported" 7 --agent copilot --model model-x
MOCK_GH_AUTH_EXIT=1 expect_no_review "$repo" "the GitHub CLI is not authenticated" 7
expect_no_review "$repo" "the base branch does not exist" 7 missing-base
[[ ! -e "$repo.log" ]] || fail "a reviewer was started despite failed preconditions"

# A feature is created from origin/<base>. When the local base branch is
# behind it, the review still covers only what the feature changed, not what
# was merged into the base before the feature started.
repo="$(setup_repo stale-local-base)"
git -C "$repo" stash -q --include-untracked
git -C "$repo" switch -q -c merged-work main
printf 'work of another feature\n' >"$repo/other.txt"
git -C "$repo" add other.txt
git -C "$repo" commit -qm "Another feature, merged on the remote"
git -C "$repo" update-ref refs/remotes/origin/main merged-work
git -C "$repo" switch -q feature/7-marker
git -C "$repo" rebase -q merged-work
git -C "$repo" branch -q -D merged-work
git -C "$repo" stash pop -q >/dev/null
run_review "$repo" 7 || {
  cat "$repo.out" >&2
  fail "a review with a stale local base branch failed"
}
artifact="$repo/.agents/reviews/feature-7-marker-review-01.json"
[[ "$(jq -r '.base' "$artifact")" == "origin/main" ]] || fail "the review did not record the base it used"
[[ "$(jq -r '.merge_base' "$artifact")" == "$(git -C "$repo" rev-parse origin/main)" ]] ||
  fail "the review did not start from the point where the feature left its base"
grep -Fqx "+committed change" "$repo.log.stdin" || fail "the feature's own change was not supplied"
if grep -Fq "work of another feature" "$repo.log.stdin"; then
  fail "work that was merged before the feature started was supplied as its change"
fi

# The other way around, a local base branch that is ahead of origin is used.
repo="$(setup_repo stale-remote-base)"
git -C "$repo" update-ref refs/remotes/origin/main "$(git -C "$repo" rev-parse main)"
git -C "$repo" stash -q --include-untracked
git -C "$repo" switch -q main
printf 'local work\n' >"$repo/local.txt"
git -C "$repo" add local.txt
git -C "$repo" commit -qm "Local work on the base"
git -C "$repo" switch -q feature/7-marker
git -C "$repo" rebase -q main
git -C "$repo" stash pop -q >/dev/null
run_review "$repo" 7 || fail "a review with a local base ahead of origin failed"
[[ "$(jq -r '.base' "$repo/.agents/reviews/feature-7-marker-review-01.json")" == "main" ]] ||
  fail "the local base branch was not used although it is the more recent"
if grep -Fq "local work" "$repo.log.stdin"; then fail "work on the base was supplied as the feature's change"; fi

# The review records the reviewer's classification of the impact on the
# architecture and what the gate found in the diff, and the reviewer is told
# which paths are protected or sensitive.
repo="$(setup_repo gate)"
git -C "$repo" stash -q --include-untracked
git -C "$repo" switch -q main
mkdir -p "$repo/.agents/policies"
printf 'sensitive: feature.txt\n' >"$repo/.agents/policies/guardrails.conf"
git -C "$repo" add -A
git -C "$repo" commit -qm "Add the gate configuration"
git -C "$repo" switch -q feature/7-marker
git -C "$repo" rebase -q main
git -C "$repo" stash pop -q >/dev/null
mkdir -p "$repo/docs/decisions"
printf '# ADR 009: Another storage\n\nStatus: Proposed\n' >"$repo/docs/decisions/009-storage.md"
MOCK_OUTPUT="$(jq '.architecture_impact = {level: "major", rationale: "Adds a storage.", checked_against: ["ADR 001"]}' <<<"$pass_result")" \
  run_review "$repo" 7 || {
  cat "$repo.out" >&2
  fail "a review with a classified impact failed"
}
artifact="$repo/.agents/reviews/feature-7-marker-review-01.json"
[[ "$(jq -r '.architecture_impact.level' "$artifact")" == "major" ]] || fail "the classification of the reviewer was not stored"
[[ "$(jq -r '.guardrails.level' "$artifact")" == "protected" ]] || fail "the level of the gate was not stored"
[[ "$(jq -r '[.guardrails.findings[] | "\(.kind) \(.path)"] | sort | join(", ")' "$artifact")" == \
  "protected docs/decisions/009-storage.md, sensitive feature.txt" ]] || fail "the findings of the gate were not stored"
[[ "$(jq -r '.merge_approval.required' "$artifact")" == "true" ]] || fail "the decision of the gate was not stored"
[[ "$(jq -r '.merge_approval.reasons | length' "$artifact")" -eq 2 ]] ||
  fail "the stored decision lacks the reasons: the added ADR and the classification"
grep -Fq "Merge approval: required from the owner" "$repo.out" || fail "the needed approval was not shown after the review"
grep -Fq "## Merge approval gate" "$repo.log.stdin" || fail "the reviewer was not told about the gate"
grep -Fq -- "- protected: docs/decisions/009-storage.md" "$repo.log.stdin" || fail "the reviewer was not told about the added ADR"
grep -Fq -- "- sensitive: feature.txt" "$repo.log.stdin" || fail "the reviewer was not told about the sensitive path"

echo "review-feature tests passed"
