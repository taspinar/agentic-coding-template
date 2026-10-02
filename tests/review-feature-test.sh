#!/usr/bin/env bash

set -euo pipefail

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
valid_result="{\"verdict\": \"CHANGES_REQUIRED\", \"limitations\": \"Tests were not run.\", \"findings\": [$(finding minor "Marker name is vague"), $(finding major "Marker content is unchecked")]}"
# A verdict that does not follow from the findings.
inconsistent_result="{\"verdict\": \"CHANGES_REQUIRED\", \"limitations\": \"\", \"findings\": [$(finding minor "Marker name is vague")]}"
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
  printf '*.log\n' >"$repo/.gitignore"
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
MOCK_OUTPUT='{"verdict": "PASS", "limitations": "", "findings": []}' run_review "$repo" 7 || {
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
pass_result='{"verdict": "PASS", "limitations": "", "findings": []}'
minor_only_result="{\"verdict\": \"PASS_WITH_MINOR_FINDINGS\", \"limitations\": \"\", \"findings\": [$(finding minor "Marker name is vague")]}"

# One invalid result per rule, each derived from a valid result.
invalid_results=(
  "not json"
  "$pass_result $pass_result"
  '{"verdict": "PASS"}'
  "$owned_fields_result"
  "$inconsistent_result"
  "$(jq '.verdict = "APPROVED"' <<<"$valid_result")"
  "$(jq '.findings[0].severity = "blocker"' <<<"$valid_result")"
  "$(jq '.findings[1].evidence = " "' <<<"$valid_result")"
  "$(jq '.verdict = "PASS"' <<<"$minor_only_result")"
  "$(jq '.verdict = "PASS_WITH_MINOR_FINDINGS"' <<<"$valid_result")"
  "$(jq '.verdict = "PASS_WITH_MINOR_FINDINGS"' <<<"$pass_result")"
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

# Invalid invocations fail before a reviewer starts.
repo="$(setup_repo preconditions)"
expect_no_review "$repo" "the branch belongs to another Issue" 8
expect_no_review "$repo" "the agent is unsupported" 7 --agent copilot --model model-x
MOCK_GH_AUTH_EXIT=1 expect_no_review "$repo" "the GitHub CLI is not authenticated" 7
expect_no_review "$repo" "the base branch does not exist" 7 missing-base
[[ ! -e "$repo.log" ]] || fail "a reviewer was started despite failed preconditions"

echo "review-feature tests passed"
