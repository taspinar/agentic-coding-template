#!/usr/bin/env bash

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
script="$root/scripts/triage-review.sh"
review_dir="$root/.agents/reviews"
triage_dir="$root/.agents/triage"
test_stem="feature-99999-triage-test-$$-$RANDOM"
review="$review_dir/${test_stem}-review-01.md"
decline_review="$review_dir/${test_stem}-review-02.md"
fallback_review="$review_dir/${test_stem}-review-07.md"
artifact="$triage_dir/${test_stem}-review-01-triage.md"
rerun_artifact="$triage_dir/${test_stem}-review-01-triage-02.md"
decline_artifact="$triage_dir/${test_stem}-review-02-triage.md"
fallback_artifact="$triage_dir/${test_stem}-review-07-triage.md"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/triage-review-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
  rm -f "$review" "$decline_review" "$fallback_review"
  rm -f "$artifact" "$rerun_artifact" "$decline_artifact" "$fallback_artifact"
}
trap cleanup EXIT

mkdir -p "$review_dir" "$triage_dir" "$tmp/bin"
for test_path in "$review" "$decline_review" "$fallback_review" "$artifact" "$rerun_artifact" "$decline_artifact" "$fallback_artifact"; do
  if [[ -e "$test_path" ]]; then
    echo "Refusing to overwrite pre-existing test path: $test_path" >&2
    exit 1
  fi
done

cat >"$review" <<'REVIEW'
# Independent Review — feature/5-test

Issue: #5

## Critical

### C1. Correctness regression

The primary path returns an incorrect result.

## Major

None.

## Minor

- Minor 1. Missing edge-case coverage
- Minor 2. Simplify fixture setup

## Suggestions

### S1. Rename local helper

The current name is less explicit.

## Verdict

CHANGES REQUIRED
REVIEW

cp "$review" "$decline_review"
cp "$review" "$fallback_review"

cat >"$tmp/bin/claude" <<'AGENT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$MOCK_AGENT_LOG"
printf '%s\n' "$MOCK_TRIAGE_OUTPUT"
AGENT

cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-} ${2:-}" == "auth status" ]]; then
  exit 0
fi

if [[ "${1:-} ${2:-}" == "issue view" ]]; then
  printf '%s' "${MOCK_ISSUE_CONTEXT:-Title: F02 — Test feature

Test acceptance criteria.}"
  exit 0
fi

if [[ "${1:-} ${2:-}" == "issue list" ]]; then
  exit 0
fi

if [[ "${1:-} ${2:-}" == "issue create" ]]; then
  shift 2
  title=""
  body_file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title)
        title="$2"
        shift 2
        ;;
      --body-file)
        body_file="$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done

  {
    echo "TITLE: $title"
    cat "$body_file"
  } >>"$MOCK_GH_LOG"
  echo "https://github.com/example/project/issues/123"
  exit 0
fi

echo "Unexpected gh invocation: $*" >&2
exit 1
GH

cat >"$tmp/bin/codex" <<'CODEX'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$MOCK_AGENT_LOG"

output_file=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--output-last-message" ]]; then
    output_file="$2"
    shift 2
  else
    shift
  fi
done

[[ -n "$output_file" ]]
printf '%s\n' "$MOCK_TRIAGE_OUTPUT" >"$output_file"
CODEX

chmod +x "$tmp/bin/claude" "$tmp/bin/codex" "$tmp/bin/gh"

review_hash_before="$(git hash-object "$review")"
decisions=$'F001\tFIX_NOW\tCorrectness blocks the feature.\t-\t-\t-\nF002\tDEFER\tCoverage is valuable but non-blocking.\tAdd boundary-condition coverage\tAdd focused tests for the uncovered boundary.\tBoundary behavior is covered by an automated test.\nF003\tACCEPT\tThe fixture setup is adequate for this scope.\t-\t-\t-\nF004\tACCEPT\tThe existing local name is adequate.\t-\t-\t-'

output="$(
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_TRIAGE_OUTPUT="$decisions" \
    MOCK_AGENT_LOG="$tmp/agent.log" \
    MOCK_GH_LOG="$tmp/gh.log" \
    "$script" "$review" claude
)"

[[ -f "$artifact" ]]
[[ "$(git hash-object "$review")" == "$review_hash_before" ]]
[[ "$output" == *"Proposed triage:"* ]]
[[ "$output" == *"C1 Correctness regression"* ]]
[[ "$output" == *"Minor 1 Missing edge-case coverage"* ]]
[[ "$output" == *"S1 Rename local helper"* ]]
[[ "$output" == *"Minor 1 → #123"* ]]
[[ "$output" == *"[F02][R01][Minor-1] Add boundary-condition coverage"* ]]

grep -Fq "Source review: \`.agents/reviews/$(basename "$review")\`" "$artifact"
grep -Fq "Source feature Issue: #5" "$artifact"
grep -Fq "Reviewer verdict: CHANGES REQUIRED" "$artifact"
grep -Fq "### C1. Correctness regression" "$artifact"
grep -Fq "### Minor 1. Missing edge-case coverage" "$artifact"
grep -Fq "### Minor 2. Simplify fixture setup" "$artifact"
grep -Fq "### S1. Rename local helper" "$artifact"
grep -Fq "Minor 1 → [#123]" "$artifact"

[[ "$(grep -c '^TITLE:' "$tmp/gh.log")" -eq 1 ]]
grep -Fq "TITLE: [F02][R01][Minor-1] Add boundary-condition coverage" "$tmp/gh.log"
grep -Fq "Original finding: Minor 1" "$tmp/gh.log"
grep -Fq "Issue #5" "$tmp/gh.log"
grep -Fq ".agents/reviews/$(basename "$review")" "$tmp/gh.log"
grep -Fq -- "- Minor 1. Missing edge-case coverage" "$tmp/gh.log"
if grep -Fq -- "- Minor 2. Simplify fixture setup" "$tmp/gh.log"; then
  echo "Deferred bullet excerpt included the next finding." >&2
  exit 1
fi
grep -Fq "triage-source:.agents/reviews/$(basename "$review")#F002" "$tmp/gh.log"
grep -Fq -- "--print --permission-mode plan --tools Read,Glob,Grep --no-session-persistence" "$tmp/agent.log"

fallback_output="$(
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_ISSUE_CONTEXT=$'Title: Test feature without roadmap ID\n\nTest acceptance criteria.' \
    MOCK_TRIAGE_OUTPUT="$decisions" \
    MOCK_AGENT_LOG="$tmp/agent.log" \
    MOCK_GH_LOG="$tmp/fallback-gh.log" \
    "$script" "$fallback_review" claude
)"
[[ "$fallback_output" == *"[#5][R07][Minor-1] Add boundary-condition coverage"* ]]
grep -Fq "TITLE: [#5][R07][Minor-1] Add boundary-condition coverage" "$tmp/fallback-gh.log"
grep -Fq "Minor 1 → [#123]" "$fallback_artifact"

decline_output="$(
  printf 'n\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_TRIAGE_OUTPUT="$decisions" \
    MOCK_AGENT_LOG="$tmp/agent.log" \
    MOCK_GH_LOG="$tmp/gh.log" \
    "$script" "$decline_review" claude
)"
[[ "$decline_output" == *"Triage declined"* ]]
[[ ! -e "$decline_artifact" ]]
[[ "$(grep -c '^TITLE:' "$tmp/gh.log")" -eq 1 ]]

codex_output="$(
  printf 'n\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_TRIAGE_OUTPUT="$decisions" \
    MOCK_AGENT_LOG="$tmp/agent.log" \
    MOCK_GH_LOG="$tmp/gh.log" \
    "$script" "$decline_review" codex test-model
)"
[[ "$codex_output" == *"Triage declined"* ]]
grep -Fq -- "exec --sandbox read-only --ephemeral --color never" "$tmp/agent.log"
grep -Fq -- "--model test-model" "$tmp/agent.log"

rerun_output="$(
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_TRIAGE_OUTPUT="$decisions" \
    MOCK_AGENT_LOG="$tmp/agent.log" \
    MOCK_GH_LOG="$tmp/gh.log" \
    "$script" "$review" claude
)"
[[ "$rerun_output" == *"Reusing existing follow-up Issue #123"* ]]
[[ "$(grep -c '^TITLE:' "$tmp/gh.log")" -eq 1 ]]
grep -Fq "Minor 1 → [#123]" "$rerun_artifact"

invalid_decisions=$'F001\tDEFER\tShould not downgrade.\tBad follow-up\tDo something.\tSomething changes.\nF002\tDEFER\tCoverage is useful.\tAdd coverage\tAdd tests.\tTests pass.\nF003\tACCEPT\tKeep fixture.\t-\t-\t-\nF004\tACCEPT\tSkip rename.\t-\t-\t-'
if PATH="$tmp/bin:/usr/bin:/bin" \
  MOCK_TRIAGE_OUTPUT="$invalid_decisions" \
  MOCK_AGENT_LOG="$tmp/agent.log" \
  MOCK_GH_LOG="$tmp/gh.log" \
  "$script" "$review" claude </dev/null >"$tmp/invalid.out" 2>&1; then
  echo "Expected Critical downgrade validation to fail." >&2
  exit 1
fi
grep -Fq "Critical finding F001 must be FIX_NOW" "$tmp/invalid.out"
[[ "$(grep -c '^TITLE:' "$tmp/gh.log")" -eq 1 ]]

if PATH="$tmp/bin:/usr/bin:/bin" "$script" "$review_dir/missing.md" claude >"$tmp/missing.out" 2>&1; then
  echo "Expected missing review validation to fail." >&2
  exit 1
fi
grep -Fq "review artifact not found" "$tmp/missing.out"

rm "$tmp/bin/codex"
if PATH="$tmp/bin:/usr/bin:/bin" "$script" "$review" codex >"$tmp/agent.out" 2>&1; then
  echo "Expected missing agent validation to fail." >&2
  exit 1
fi
grep -Fq "'codex' command not found" "$tmp/agent.out"

echo "triage-review tests passed"
