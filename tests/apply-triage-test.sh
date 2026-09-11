#!/usr/bin/env bash

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
script="$root/scripts/apply-triage.sh"
review_dir="$root/.agents/reviews"
triage_dir="$root/.agents/triage"
test_stem="feature-13-apply-test-$$-$RANDOM"
review="$review_dir/${test_stem}-review-01.md"
triage="$triage_dir/${test_stem}-review-01-triage.md"
decline_triage="$triage_dir/${test_stem}-review-02-triage.md"
empty_triage="$triage_dir/${test_stem}-review-03-triage.md"
malformed_triage="$triage_dir/${test_stem}-review-04-triage.md"
unapproved_triage="$triage_dir/${test_stem}-review-05-triage.md"
stale_triage="$triage_dir/${test_stem}-review-06-triage.md"
ambiguous_triage="$triage_dir/${test_stem}-review-07-triage.md"
deleted_triage="$triage_dir/${test_stem}-review-08-triage.md"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/apply-triage-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
  rm -f "$review" "$triage" "$decline_triage" "$empty_triage" "$malformed_triage"
  rm -f "$unapproved_triage" "$stale_triage" "$ambiguous_triage"
  rm -f "$deleted_triage"
}
trap cleanup EXIT

mkdir -p "$review_dir" "$triage_dir" "$tmp/bin"
for test_path in "$review" "$triage" "$decline_triage" "$empty_triage" "$malformed_triage" "$unapproved_triage" "$stale_triage" "$ambiguous_triage" "$deleted_triage"; do
  if [[ -e "$test_path" ]]; then
    echo "Refusing to overwrite pre-existing test path: $test_path" >&2
    exit 1
  fi
done

cat >"$review" <<'REVIEW'
# Independent Review — feature/13-apply-test

Issue: #13

## Critical

### C1. Correctness regression

The incorrect branch must be fixed.
- S99. Evidence detail that is not a finding

## Minor

### Minor 1. Deferred cleanup

This work is outside the current scope.

## Suggestions

### Accepted rename

The existing name is acceptable.

## Verdict

CHANGES REQUIRED
REVIEW

write_triage() {
  local target="$1"
  local fix_decision="$2"
  local include_approval="$3"

  {
    echo "# Review Triage — $test_stem"
    echo
    echo "Source review: \`.agents/reviews/$(basename "$review")\`"
    echo
    echo "Source feature Issue: #13"
    echo
    echo "Reviewer verdict: CHANGES REQUIRED"
    echo
    echo "Triage agent: claude"
    if [[ "$include_approval" == "yes" ]]; then
      echo
      echo "Approved at: 2026-09-11T10:00:00Z"
    fi
    echo
    echo "## Fix now"
    echo
    echo "### C1. Correctness regression"
    echo
    echo "- Severity: Critical"
    echo "- Decision: $fix_decision"
    echo "- Source line: 7"
    echo "- Rationale: Correctness blocks the feature."
    echo
    echo "## Deferred"
    echo
    echo "### Minor 1. Deferred cleanup"
    echo
    echo "- Severity: Minor"
    echo "- Decision: DEFER"
    echo "- Source line: 15"
    echo "- Rationale: This belongs in follow-up work."
    echo "- Proposed Issue: [F03][R01][Minor-1] Deferred cleanup"
    echo "- Recommended action: Handle separately."
    echo "- Acceptance criteria: Cleanup is complete."
    echo "- Created Issue: see Traceability"
    echo
    echo "## Accepted"
    echo
    echo "### Suggestion-1. Accepted rename"
    echo
    echo "- Severity: Suggestions"
    echo "- Decision: ACCEPT"
    echo "- Source line: 23"
    echo "- Rationale: The existing name is adequate."
    echo
    echo "## Traceability"
    echo
    echo "- Minor 1 → [#99](https://github.com/example/project/issues/99)"
  } >"$target"
}

write_triage "$triage" "FIX_NOW" "yes"
cp "$triage" "$decline_triage"
write_triage "$malformed_triage" "DEFER" "yes"
write_triage "$unapproved_triage" "FIX_NOW" "no"
awk '{ gsub(/C1\. Correctness regression/, "S99. Evidence detail that is not a finding"); print }' "$triage" >"$stale_triage"
awk '
  { print }
  /^Source feature Issue: #13$/ {
    print "Source feature Issue: #99"
  }
' "$triage" >"$ambiguous_triage"
cp "$triage" "$deleted_triage"

cat >"$empty_triage" <<EOF
# Review Triage — $test_stem

Source review: \`.agents/reviews/$(basename "$review")\`

Source feature Issue: #13

Reviewer verdict: PASS

Triage agent: claude

Approved at: 2026-09-11T10:00:00Z

## Fix now

None.

## Deferred

None.

## Accepted

None.

## Traceability

No follow-up Issues created.
EOF

cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-} ${2:-}" == "auth status" ]]; then
  exit 0
fi
if [[ "${1:-} ${2:-}" == "issue view" ]]; then
  echo "13"
  exit 0
fi
echo "Unexpected gh invocation: $*" >&2
exit 1
GH

cat >"$tmp/bin/codex" <<'CODEX'
#!/usr/bin/env bash
set -euo pipefail
printf 'codex %s\n' "$*" >>"$MOCK_AGENT_LOG"
if [[ -n "${MOCK_CHMOD_PATH:-}" ]]; then
  chmod 600 "$MOCK_CHMOD_PATH"
fi
if [[ -n "${MOCK_DELETE_PATH:-}" ]]; then
  rm -f "$MOCK_DELETE_PATH"
fi
exit "${MOCK_AGENT_EXIT:-0}"
CODEX

cat >"$tmp/bin/claude" <<'CLAUDE'
#!/usr/bin/env bash
set -euo pipefail
printf 'claude %s\n' "$*" >>"$MOCK_AGENT_LOG"
if [[ -n "${MOCK_CHMOD_PATH:-}" ]]; then
  chmod 600 "$MOCK_CHMOD_PATH"
fi
if [[ -n "${MOCK_DELETE_PATH:-}" ]]; then
  rm -f "$MOCK_DELETE_PATH"
fi
exit "${MOCK_AGENT_EXIT:-0}"
CLAUDE

chmod +x "$tmp/bin/gh" "$tmp/bin/codex" "$tmp/bin/claude"

review_hash_before="$(git hash-object "$review")"
triage_hash_before="$(git hash-object "$triage")"

output="$(
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$tmp/agent.log" \
    APPLY_TRIAGE_TEST_ACTIVE=1 \
    "$script" "$triage" codex test-model
)"

[[ "$output" == *"Approved FIX_NOW scope"* ]]
[[ "$output" == *"### C1. Correctness regression"* ]]
[[ "$output" == *"verification passed"* ]]
[[ "$(git hash-object "$review")" == "$review_hash_before" ]]
[[ "$(git hash-object "$triage")" == "$triage_hash_before" ]]
grep -Fq "codex --sandbox workspace-write --ask-for-approval never --model test-model" "$tmp/agent.log"
grep -Fq "### C1. Correctness regression" "$tmp/agent.log"
if grep -Fq "Deferred cleanup" "$tmp/agent.log" || grep -Fq "Accepted rename" "$tmp/agent.log"; then
  echo "Implementation agent received a non-FIX_NOW finding." >&2
  exit 1
fi

agent_calls_before="$(grep -c '^[a-z]' "$tmp/agent.log")"
decline_output="$(
  printf 'n\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$tmp/agent.log" \
    APPLY_TRIAGE_TEST_ACTIVE=1 \
    "$script" "$decline_triage" claude
)"
[[ "$decline_output" == *"Apply triage declined"* ]]
[[ "$(grep -c '^[a-z]' "$tmp/agent.log")" -eq "$agent_calls_before" ]]

empty_output="$(
  PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$tmp/agent.log" \
    APPLY_TRIAGE_TEST_ACTIVE=1 \
    "$script" "$empty_triage" claude
)"
[[ "$empty_output" == *"No FIX_NOW findings found"* ]]
[[ "$(grep -c '^[a-z]' "$tmp/agent.log")" -eq "$agent_calls_before" ]]

claude_output="$(
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$tmp/agent.log" \
    APPLY_TRIAGE_TEST_ACTIVE=1 \
    "$script" "$triage" claude opus
)"
[[ "$claude_output" == *"verification passed"* ]]
grep -Fq "claude --permission-mode acceptEdits --model opus" "$tmp/agent.log"

if PATH="$tmp/bin:/usr/bin:/bin" \
  MOCK_AGENT_LOG="$tmp/agent.log" \
  APPLY_TRIAGE_TEST_ACTIVE=1 \
  "$script" "$malformed_triage" claude </dev/null >"$tmp/malformed.out" 2>&1; then
  echo "Expected malformed triage validation to fail." >&2
  exit 1
fi
grep -Fq "wrong decision section" "$tmp/malformed.out"

if PATH="$tmp/bin:/usr/bin:/bin" \
  MOCK_AGENT_LOG="$tmp/agent.log" \
  APPLY_TRIAGE_TEST_ACTIVE=1 \
  "$script" "$unapproved_triage" claude >"$tmp/unapproved.out" 2>&1; then
  echo "Expected unapproved triage validation to fail." >&2
  exit 1
fi
grep -Fq "approval timestamp" "$tmp/unapproved.out"

if PATH="$tmp/bin:/usr/bin:/bin" \
  MOCK_AGENT_LOG="$tmp/agent.log" \
  APPLY_TRIAGE_TEST_ACTIVE=1 \
  "$script" "$stale_triage" claude >"$tmp/stale.out" 2>&1; then
  echo "Expected stale triage validation to fail." >&2
  exit 1
fi
if ! grep -Fq "does not map uniquely to the source review" "$tmp/stale.out"; then
  cat "$tmp/stale.out" >&2
  exit 1
fi

if PATH="$tmp/bin:/usr/bin:/bin" \
  MOCK_AGENT_LOG="$tmp/agent.log" \
  APPLY_TRIAGE_TEST_ACTIVE=1 \
  "$script" "$ambiguous_triage" claude >"$tmp/ambiguous.out" 2>&1; then
  echo "Expected ambiguous Issue metadata validation to fail." >&2
  exit 1
fi
grep -Fq "ambiguous source Issue metadata" "$tmp/ambiguous.out"

if printf 'y\n' | PATH="$tmp/bin:/usr/bin:/bin" \
  MOCK_AGENT_LOG="$tmp/agent.log" \
  MOCK_AGENT_EXIT=7 \
  APPLY_TRIAGE_TEST_ACTIVE=1 \
  "$script" "$triage" claude >"$tmp/failed-agent.out" 2>&1; then
  echo "Expected failed implementation agent to propagate failure." >&2
  exit 1
fi
grep -Fq "Running repository verification" "$tmp/failed-agent.out"
grep -Fq "implementation agent exited with status 7" "$tmp/failed-agent.out"

if [[ "$(uname -s)" == "Darwin" ]]; then
  original_mode="$(stat -f '%Lp' "$triage")"
else
  original_mode="$(stat -c '%a' "$triage")"
fi
if printf 'y\n' | PATH="$tmp/bin:/usr/bin:/bin" \
  MOCK_AGENT_LOG="$tmp/agent.log" \
  MOCK_CHMOD_PATH="$triage" \
  APPLY_TRIAGE_TEST_ACTIVE=1 \
  "$script" "$triage" claude >"$tmp/mode.out" 2>&1; then
  echo "Expected protected artifact mode change to fail." >&2
  exit 1
fi
chmod "$original_mode" "$triage"
grep -Fq "modified the approved triage artifact" "$tmp/mode.out"
grep -Fq "Running repository verification" "$tmp/mode.out"

if printf 'y\n' | PATH="$tmp/bin:/usr/bin:/bin" \
  MOCK_AGENT_LOG="$tmp/agent.log" \
  MOCK_DELETE_PATH="$deleted_triage" \
  APPLY_TRIAGE_TEST_ACTIVE=1 \
  "$script" "$deleted_triage" claude >"$tmp/deleted.out" 2>&1; then
  echo "Expected protected artifact deletion to fail." >&2
  exit 1
fi
grep -Fq "modified the approved triage artifact" "$tmp/deleted.out"
grep -Fq "Running repository verification" "$tmp/deleted.out"

if PATH="$tmp/bin:/usr/bin:/bin" "$script" "$triage_dir/missing.md" claude >"$tmp/missing.out" 2>&1; then
  echo "Expected missing triage validation to fail." >&2
  exit 1
fi
grep -Fq "triage artifact not found" "$tmp/missing.out"

rm "$tmp/bin/codex"
if PATH="$tmp/bin:/usr/bin:/bin" "$script" "$triage" codex >"$tmp/agent.out" 2>&1; then
  echo "Expected missing agent validation to fail." >&2
  exit 1
fi
grep -Fq "'codex' command not found" "$tmp/agent.out"

echo "apply-triage tests passed"
