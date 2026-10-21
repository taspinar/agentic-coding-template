#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/triage-review-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "triage-review test failed: $*" >&2
  exit 1
}

source "$source_root/tests/lib-fakes.sh"
make_fake_agents "$tmp/bin"

# The fake GitHub CLI logs created Issues and finds them again by trace token.
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-} ${2:-}" in
  "auth status")
    exit 0
    ;;
  "api user")
    # A test can change files here, after the script took its copies.
    if [[ -n "${MOCK_GH_USER_ACTION:-}" ]]; then eval "$MOCK_GH_USER_ACTION"; fi
    if [[ -n "${MOCK_GH_USER_EXIT:-}" ]]; then exit "$MOCK_GH_USER_EXIT"; fi
    echo "${MOCK_GH_USER-owner-login}"
    exit 0
    ;;
  "issue view")
    printf '%s' "${MOCK_ISSUE_CONTEXT:-Title: F02 — Test feature

Test acceptance criteria.}"
    exit 0
    ;;
  "issue comment")
    if [[ -n "${MOCK_GH_COMMENT_EXIT:-}" ]]; then
      echo "simulated comment failure" >&2
      exit "$MOCK_GH_COMMENT_EXIT"
    fi
    shift 2
    issue="$1"
    shift
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "--body-file" ]]; then
        {
          echo "COMMENT ON #$issue"
          cat "$2"
          echo "END COMMENT"
        } >>"$MOCK_GH_LOG.comments"
      fi
      shift
    done
    exit 0
    ;;
  "issue list")
    if [[ -n "${MOCK_EXISTING_ISSUE:-}" ]]; then
      echo "$MOCK_EXISTING_ISSUE"
    fi
    exit 0
    ;;
  "issue create")
    if [[ -n "${MOCK_GH_CREATE_EXIT:-}" ]]; then
      echo "simulated Issue creation failure" >&2
      exit "$MOCK_GH_CREATE_EXIT"
    fi
    shift 2
    title=""
    body_file=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --title) title="$2"; shift 2 ;;
        --body-file) body_file="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    {
      echo "TITLE: $title"
      cat "$body_file"
    } >>"$MOCK_GH_LOG"
    echo "https://github.com/example/project/issues/123"
    exit 0
    ;;
esac
echo "Unexpected gh invocation: $*" >&2
exit 1
GH
chmod +x "$tmp/bin/gh"

# Creates a repository with a stored review of Issue #5 in the given round.
setup_repo() {
  local repo="$tmp/$1"
  local round="${2:-1}"
  local findings="${3:-default}"

  mkdir -p "$repo/.agents/reviews"
  copy_workflow "$repo"
  printf 'triage: claude model-t\n' >"$repo/.agents/agents.conf"

  if [[ "$findings" == "none" ]]; then
    findings='[]'
    verdict="PASS"
  else
    verdict="CHANGES_REQUIRED"
    findings='[
      {"id": "C1", "severity": "critical", "title": "Correctness regression", "evidence": "src/a.sh:3", "impact": "Wrong result.", "recommendation": "Fix the branch."},
      {"id": "MIN1", "severity": "minor", "title": "Missing edge-case coverage", "evidence": "tests/a.sh:9\nSecond line.", "impact": "A regression would go unnoticed.", "recommendation": "Add a test."},
      {"id": "S1", "severity": "suggestion", "title": "Rename local helper", "evidence": "src/a.sh:8", "impact": "Readability.", "recommendation": "Rename it."}
    ]'
  fi
  jq -n --argjson round "$round" --argjson findings "$findings" --arg verdict "$verdict" '{
    schema: "review/v1", issue: 5, round: $round, branch: "feature/5-test", base: "main",
    merge_base: "aaaa", head: "bbbb", reviewed_tree: "cccc",
    reviewer: {agent: "codex", model: "model-r"}, created_at: "2026-01-01T00:00:00Z",
    verdict: $verdict, limitations: "", findings: $findings
  }' >"$repo/.agents/reviews/feature-5-test-review-$(printf '%02d' "$round").json"

  git -C "$repo" init -q -b main
  git -C "$repo" config user.name "Triage Test"
  git -C "$repo" config user.email "triage-test@example.com"
  git -C "$repo" add .
  git -C "$repo" commit -qm "Seed project"
  record_reviewed_tree "$repo" "$repo/.agents/reviews/feature-5-test-review-$(printf '%02d' "$round").json"

  printf '%s\n' "$repo"
}

run_triage() {
  local repo="$1"
  local answer="$2"
  shift 2

  (
    cd "$repo"
    printf '%s\n' "$answer" |
      PATH="$tmp/bin:/usr/bin:/bin" MOCK_AGENT_LOG="$repo.log" MOCK_GH_LOG="$repo.gh" \
        ./scripts/triage-review.sh "$@"
  ) >"$repo.out" 2>&1
}

expect_no_triage() {
  local repo="$1"
  local description="$2"
  shift 2

  if run_triage "$repo" y "$@"; then
    cat "$repo.out" >&2
    fail "expected failure: $description"
  fi
  if compgen -G "$repo/.agents/triage/*" >/dev/null; then
    fail "a triage artifact was stored although: $description"
  fi
  [[ ! -e "$repo.gh" ]] || fail "a follow-up Issue was created although: $description"
}

review=".agents/reviews/feature-5-test-review-01.json"
valid_decisions='{"decisions": [
  {"finding_id": "C1", "decision": "FIX_NOW", "rationale": "Correctness blocks the feature.", "followup": null},
  {"finding_id": "MIN1", "decision": "DEFER", "rationale": "Valuable but not blocking.", "followup": {"title": "Add boundary-condition coverage", "recommended_action": "Add focused tests.", "acceptance_criteria": ["The boundary is covered by a test."]}},
  {"finding_id": "S1", "decision": "ACCEPT", "rationale": "The name is adequate.", "followup": null}
]}'
# A Critical finding may not be deferred.
downgraded_decisions="$(jq '.decisions[0] = {"finding_id": "C1", "decision": "DEFER", "rationale": "Later.", "followup": {"title": "Fix it later", "recommended_action": "Fix.", "acceptance_criteria": ["Fixed."]}}' <<<"$valid_decisions")"
# A finding of the review is missing.
incomplete_decisions="$(jq 'del(.decisions[2])' <<<"$valid_decisions")"
export MOCK_OUTPUT="$valid_decisions"

# Approval stores validated decisions and creates exactly the deferred
# follow-up Issue with a provenance-prefixed title.
repo="$(setup_repo approve)"
run_triage "$repo" y "$review" || {
  cat "$repo.out" >&2
  fail "approved triage failed"
}
artifact="$repo/.agents/triage/feature-5-test-review-01-triage"
[[ -f "$artifact.json" && -f "$artifact.md" ]] || fail "triage artifact and report were not stored"
[[ "$(jq -c '[.schema, .issue, .source_review, (.decisions | map(.decision))]' "$artifact.json")" == \
  "[\"triage/v1\",5,\"$review\",[\"FIX_NOW\",\"DEFER\",\"ACCEPT\"]]" ]] || fail "stored triage is incomplete"
[[ "$(jq -r '.decisions[1].followup | "\(.title) #\(.issue_number)"' "$artifact.json")" == \
  "[F02][R01][MIN1] Add boundary-condition coverage #123" ]] || fail "follow-up Issue was not recorded with its provenance"
[[ "$(grep -c '^TITLE:' "$repo.gh")" -eq 1 ]] || fail "exactly one follow-up Issue was expected"
grep -Fqx "TITLE: [F02][R01][MIN1] Add boundary-condition coverage" "$repo.gh" || fail "follow-up title lacks provenance"
grep -Fq "triage-source:$review#MIN1" "$repo.gh" || fail "follow-up Issue lacks its trace token"
grep -Fqx "Second line." "$repo.gh" || fail "follow-up Issue lacks the multi-line evidence"
grep -Fq -- "--strict-mcp-config --permission-mode dontAsk --tools Read,Glob,Grep" "$repo.log" || fail "triage agent was not read-only"
grep -Fq -- "--json-schema" "$repo.log" || fail "triage agent was not given the schema"
grep -Fq "Correctness regression" "$repo.log.stdin" || fail "findings were not supplied to the triage agent"

# One comment with both reports is published on the source Issue, and the
# publication is recorded in the triage.
grep -Eq '"published_at": "[0-9]{4}-' "$artifact.json" || fail "the publication was not recorded in the triage"
[[ "$(grep -c '^COMMENT ON #5$' "$repo.gh.comments")" -eq 1 ]] || fail "exactly one comment on Issue #5 was expected"
grep -Fq "C1. Correctness regression" "$repo.gh.comments" || fail "the comment lacks the review report"
grep -Fq "## Fix now" "$repo.gh.comments" || fail "the comment lacks the triage report"
grep -Fq "#123" "$repo.gh.comments" || fail "the comment lacks the follow-up Issue link"
if grep -Fq "Generated from" "$repo.gh.comments"; then
  fail "the comment contains the generated-file marker"
fi

# The complete follow-up proposal is shown before the approval question.
proposal="$(sed '/Proceed with this triage/,$d' "$repo.out")"
for shown in "Add focused tests." "The boundary is covered by a test."; do
  [[ "$proposal" == *"$shown"* ]] || fail "the proposal did not show before approval: $shown"
done

# A second approved round reuses the recorded Issue instead of creating one.
run_triage "$repo" y "$review" || {
  cat "$repo.out" >&2
  fail "repeated triage failed"
}
[[ "$(jq -r '.decisions[1].followup.issue_number' "$artifact-02.json")" == "123" ]] ||
  fail "repeated triage did not reuse the existing follow-up Issue"
[[ "$(grep -c '^TITLE:' "$repo.gh")" -eq 1 ]] || fail "repeated triage created a duplicate follow-up Issue"

# Without a local record, an Issue found by its trace token is reused.
repo="$(setup_repo found-remotely)"
MOCK_EXISTING_ISSUE="https://github.com/example/project/issues/77" run_triage "$repo" y "$review" || {
  cat "$repo.out" >&2
  fail "triage with an existing remote Issue failed"
}
[[ "$(jq -r '.decisions[1].followup.issue_number' "$repo/.agents/triage/feature-5-test-review-01-triage.json")" == "77" ]] ||
  fail "an existing remote follow-up Issue was not reused"
[[ ! -e "$repo.gh" ]] || fail "a duplicate of an existing remote follow-up Issue was created"

# The published review is rendered from the JSON, not from an edited report,
# and a record too long for one comment is split rather than shortened.
repo="$(setup_repo long-report)"
printf 'Edited report that must not be published.\n' >"$repo/.agents/reviews/feature-5-test-review-01.md"
long_evidence="$(printf 'evidence line %s\\n' $(seq 1 4000))"
jq --arg evidence "$long_evidence" '.findings[1].evidence = $evidence' \
  "$repo/$review" >"$repo/$review.tmp"
mv "$repo/$review.tmp" "$repo/$review"
run_triage "$repo" y "$review" || {
  cat "$repo.out" >&2
  fail "triage with a long review failed"
}
if grep -Fq "Edited report that must not be published." "$repo.gh.comments"; then
  fail "an edited Markdown report was published instead of the JSON"
fi
parts="$(grep -c '^COMMENT ON #5$' "$repo.gh.comments")"
[[ "$parts" -ge 2 ]] || fail "a record too long for one comment was not split"
grep -Fq "evidence line 4000" "$repo.gh.comments" || fail "the long review was shortened"
grep -Fq "## Fix now" "$repo.gh.comments" || fail "the split record lacks the triage report"

# A failed publication keeps the stored triage and tells how to retry.
repo="$(setup_repo comment-fails)"
if MOCK_GH_COMMENT_EXIT=1 run_triage "$repo" y "$review"; then
  fail "a failed publication returned success"
fi
[[ -f "$repo/.agents/triage/feature-5-test-review-01-triage.json" ]] ||
  fail "a failed publication discarded the stored triage"
triage_file="$repo/.agents/triage/feature-5-test-review-01-triage.json"
[[ "$(jq -r '.published_at // "none"' "$triage_file")" == "none" ]] || fail "a failed publication was recorded as published"
grep -Fq "./scripts/triage-review.sh --publish .agents/triage/feature-5-test-review-01-triage.json" "$repo.out" ||
  fail "a failed publication did not print the retry command"
(
  cd "$repo"
  PATH="$tmp/bin:/usr/bin:/bin" MOCK_GH_LOG="$repo.gh" ./scripts/triage-review.sh --publish .agents/triage/feature-5-test-review-01-triage.json
) >"$repo.retry.out" 2>&1 || {
  cat "$repo.retry.out" >&2
  fail "retrying the publication failed"
}
[[ "$(grep -c '^COMMENT ON #5$' "$repo.gh.comments")" -eq 1 ]] || fail "the retry did not publish the reports"
grep -Eq '"published_at": "[0-9]{4}-' "$triage_file" || fail "the retried publication was not recorded"

# When Issue creation fails, no triage artifact is stored.
repo="$(setup_repo create-fails)"
if MOCK_GH_CREATE_EXIT=1 run_triage "$repo" y "$review"; then
  fail "a failed follow-up Issue creation returned success"
fi
if compgen -G "$repo/.agents/triage/*" >/dev/null; then
  fail "a triage artifact was stored although a follow-up Issue could not be created"
fi

# Without a feature ID in the Issue title, the Issue number is the provenance.
repo="$(setup_repo fallback 7)"
MOCK_ISSUE_CONTEXT=$'Title: Test feature without roadmap ID\n\nBody.' \
  run_triage "$repo" y ".agents/reviews/feature-5-test-review-07.json" || {
  cat "$repo.out" >&2
  fail "triage without a feature ID failed"
}
grep -Fqx "TITLE: [#5][R07][MIN1] Add boundary-condition coverage" "$repo.gh" || fail "fallback provenance is wrong"

# Declining has no side effects.
repo="$(setup_repo decline)"
run_triage "$repo" n "$review" --agent codex --model model-c || fail "declined triage returned an error"
if compgen -G "$repo/.agents/triage/*" >/dev/null || [[ -e "$repo.gh" || -e "$repo.gh.comments" ]]; then
  fail "declined triage had side effects"
fi
grep -Fq -- "--sandbox read-only" "$repo.log" || fail "Codex triage agent was not sandboxed read-only"
grep -Fq -- "--output-schema" "$repo.log" || fail "Codex triage agent was not given the schema"

# Invalid decisions are retried once and then rejected before any side effect.
# The triage agent may not supply script-owned fields or more than one result.
owned_fields_decisions="$(jq '.decisions[0].severity = "minor"' <<<"$valid_decisions")"
# A required field is absent rather than null.
missing_field_decisions="$(jq 'del(.decisions[2].followup)' <<<"$valid_decisions")"

# One invalid result per rule, each derived from the valid decisions.
invalid_decisions=(
  "not json"
  "$valid_decisions $valid_decisions"
  "$downgraded_decisions"
  "$incomplete_decisions"
  "$owned_fields_decisions"
  "$missing_field_decisions"
  "$(jq '.decisions += [.decisions[2]]' <<<"$valid_decisions")"
  "$(jq '.decisions[2].finding_id = "S9"' <<<"$valid_decisions")"
  "$(jq '.decisions[2].decision = "LATER"' <<<"$valid_decisions")"
  "$(jq '.decisions[2].rationale = ""' <<<"$valid_decisions")"
  "$(jq '.decisions[1].followup = null' <<<"$valid_decisions")"
  "$(jq '.decisions[1].followup.title = ""' <<<"$valid_decisions")"
  "$(jq '.decisions[1].followup.recommended_action = ""' <<<"$valid_decisions")"
  "$(jq '.decisions[1].followup.acceptance_criteria = []' <<<"$valid_decisions")"
  "$(jq '.decisions[2].followup = .decisions[1].followup' <<<"$valid_decisions")"
)
for index in "${!invalid_decisions[@]}"; do
  invalid="${invalid_decisions[$index]}"
  repo="$(setup_repo "invalid-$index")"
  MOCK_OUTPUT="$invalid" expect_no_triage "$repo" "the decisions are invalid" "$review"
  [[ "$(grep -c '^AGENT=' "$repo.log")" -eq 2 ]] || fail "invalid decisions were not retried exactly once"
done

repo="$(setup_repo retry)"
MOCK_OUTPUT_FIRST="$incomplete_decisions" run_triage "$repo" y "$review" || {
  cat "$repo.out" >&2
  fail "valid decisions after one invalid result were rejected"
}
grep -Fq "finding S1 was not classified" "$repo.log" || fail "the retry prompt lacks the rejection reason"

# A triage agent that fails or changes the working tree is rejected.
repo="$(setup_repo agent-fails)"
MOCK_AGENT_EXIT=9 expect_no_triage "$repo" "the triage agent failed" "$review"

repo="$(setup_repo modifies)"
MOCK_AGENT_ACTION="printf 'x\n' >'$repo/note.txt'" expect_no_triage "$repo" "the triage agent changed the working tree" "$review"

# A review of content that changed since is stale and is not triaged.
repo="$(setup_repo stale)"
printf 'changed after the review\n' >>"$repo/AGENTS.md"
expect_no_triage "$repo" "the review is stale" "$review"
grep -Fq "stale" "$repo.out" || fail "a stale review was not reported as stale"
[[ ! -e "$repo.log" ]] || fail "a triage agent was started for a stale review"

# A review without findings needs no agent and still records an approved triage.
repo="$(setup_repo none 1 none)"
run_triage "$repo" y "$review" || {
  cat "$repo.out" >&2
  fail "triage of a review without findings failed"
}
[[ "$(jq '.decisions | length' "$repo/.agents/triage/feature-5-test-review-01-triage.json")" -eq 0 ]] ||
  fail "triage of a review without findings is not empty"
[[ ! -e "$repo.log" ]] || fail "a triage agent was started for a review without findings"

# Invalid inputs fail before an agent starts.
repo="$(setup_repo preconditions)"
printf '# report\n' >"$repo/.agents/reviews/feature-5-test-review-01.md"
expect_no_triage "$repo" "the input is the generated report" ".agents/reviews/feature-5-test-review-01.md"
expect_no_triage "$repo" "the review does not exist" ".agents/reviews/missing.json"
printf '{"schema": "other"}\n' >"$repo/.agents/reviews/other.json"
expect_no_triage "$repo" "the file is not a review artifact" ".agents/reviews/other.json"
expect_no_triage "$repo" "the agent is unsupported" "$review" --agent copilot --model model-x
[[ ! -e "$repo.log" ]] || fail "a triage agent was started despite failed preconditions"

# --unattended approves the proposal without a question, and both the
# artifact and the published record say that no human approved it.
repo="$(setup_repo unattended)"
run_triage "$repo" "" "$review" --unattended || {
  cat "$repo.out" >&2
  fail "an unattended triage failed"
}
artifact="$repo/.agents/triage/feature-5-test-review-01-triage"
if grep -Fq "Proceed with this triage?" "$repo.out"; then fail "an unattended triage asked for approval"; fi
[[ "$(jq -r '.unattended' "$artifact.json")" == "true" ]] || fail "the artifact does not record the unattended approval"
[[ "$(jq -r '.decisions[0].decision' "$artifact.json")" == "FIX_NOW" ]] || fail "the unattended triage lost its decisions"
grep -Fq "by an unattended run; no human approved these decisions" "$artifact.md" ||
  fail "the report does not say that no human approved the triage"
grep -Fq "no human approved these decisions" "$repo.gh.comments" ||
  fail "the published triage does not say that no human approved it"
[[ "$(grep -c '^TITLE:' "$repo.gh")" -eq 1 ]] || fail "the unattended triage did not create the follow-up Issue"

# The proposal must still be valid: nothing is approved otherwise.
repo="$(setup_repo unattended-invalid)"
if MOCK_OUTPUT="$downgraded_decisions" run_triage "$repo" "" "$review" --unattended; then
  fail "an unattended triage approved invalid decisions"
fi
if compgen -G "$repo/.agents/triage/*.json" >/dev/null; then fail "invalid decisions were stored unattended"; fi

# An approval that you gave says nothing about an unattended run, and the
# field has no other value than true.
repo="$(setup_repo attended)"
run_triage "$repo" y "$review" || fail "an attended triage failed"
artifact="$repo/.agents/triage/feature-5-test-review-01-triage"
[[ "$(jq 'has("unattended")' "$artifact.json")" == "false" ]] || fail "an attended triage was recorded as unattended"
if grep -Fq "unattended" "$artifact.md"; then fail "the report of an attended triage mentions an unattended run"; fi
jq '.unattended = false' "$artifact.json" >"$tmp/not-unattended.json"
(
  source "$source_root/scripts/lib/review-data.sh"
  grep -Fq "unattended must be true or absent" <<<"$(triage_artifact_errors "$tmp/not-unattended.json" "$repo/$review")"
) || fail "a triage with 'unattended: false' was accepted"

# A review whose findings were fixed before the triage is stale. With a later
# round and its reviewed tree available it is triaged as a historical review,
# and the agent reads the reviewed content, not the live worktree.
add_later_round() {
  local repo="$1"

  jq '.round = 2 | .verdict = "PASS" | .findings = []' "$repo/$review" >"$repo/.agents/reviews/feature-5-test-review-02.json"
  record_reviewed_tree "$repo" "$repo/.agents/reviews/feature-5-test-review-02.json"
}
repo="$(setup_repo historical)"
printf 'reviewed content\n' >"$repo/note.txt"
printf 'packaging only\n' >"$repo/packaging.txt"
printf 'packaging.txt export-ignore\n' >"$repo/.gitattributes"
record_reviewed_tree "$repo" "$repo/$review"
printf 'changed after the review\n' >"$repo/note.txt"
printf 'live change\n' >"$repo/live-change.txt"
add_later_round "$repo"
MOCK_AGENT_ACTION="pwd -P >\"$repo.agent-dir\"; ls -A . >\"$repo.agent-files\"; cp note.txt \"$repo.agent-note\"; git rev-parse --is-inside-work-tree >\"$repo.agent-git\"" \
  run_triage "$repo" y "$review" || {
  cat "$repo.out" >&2
  fail "a historical triage failed"
}
artifact="$repo/.agents/triage/feature-5-test-review-01-triage"
[[ "$(jq -r '.historical' "$artifact.json")" == "true" ]] || fail "the triage does not record that it is historical"
[[ "$(<"$repo.agent-dir")" != "$(cd "$repo" && pwd -P)" ]] || fail "the historical triage agent ran in the live worktree"
if grep -Fq "live-change.txt" "$repo.agent-files"; then fail "the agent saw the live change"; fi
grep -Fq ".agents" "$repo.agent-files" || fail "the agent did not see the reviewed content"
[[ "$(<"$repo.agent-note")" == "reviewed content" ]] || fail "the agent did not read the reviewed version of a changed file"
grep -Fq "packaging.txt" "$repo.agent-files" || fail "the extract lacks an export-ignore path of the reviewed content"
[[ "$(<"$repo.agent-git")" == "true" ]] || fail "the extract is not a Git work tree, which Codex needs"
grep -Fq "Historical triage" "$artifact.md" || fail "the report does not say that the triage is historical"
grep -Fq "Historical triage" "$repo.gh.comments" || fail "the published triage does not say that it is historical"
grep -Fq "as they were when the review was made" "$repo.log.stdin" || fail "the agent was not told that the files are the reviewed ones"
(
  source "$source_root/scripts/lib/review-data.sh"
  [[ -z "$(triage_artifact_errors "$artifact.json" "$repo/$review")" ]] || exit 1
  jq 'del(.historical)' "$artifact.json" >"$tmp/no-historical.json"
  [[ -z "$(triage_artifact_errors "$tmp/no-historical.json" "$repo/$review")" ]] || exit 2
  jq '.historical = false' "$artifact.json" >"$tmp/bad-historical.json"
  grep -Fq "historical must be true or absent" <<<"$(triage_artifact_errors "$tmp/bad-historical.json" "$repo/$review")" || exit 3
) || fail "the validation of the historical field is wrong (status $?)"

# Declining a historical triage has no side effects either.
repo="$(setup_repo historical-declined)"
printf 'changed after the review\n' >>"$repo/AGENTS.md"
add_later_round "$repo"
run_triage "$repo" n "$review" || fail "a declined historical triage returned an error"
if compgen -G "$repo/.agents/triage/*" >/dev/null || [[ -e "$repo.gh.comments" ]]; then fail "a declined historical triage had side effects"; fi

# The latest stale round is refused, with the next step named.
repo="$(setup_repo latest-stale)"
printf 'changed after the review\n' >>"$repo/AGENTS.md"
expect_no_triage "$repo" "the stale review is the latest round" "$review"
grep -Fq "Run a new review first" "$repo.out" || fail "the refusal does not say to review again first"
[[ ! -e "$repo.log" ]] || fail "a triage agent was started for a stale latest review"

# A reviewed tree that is gone fails closed.
repo="$(setup_repo tree-missing)"
printf 'changed after the review\n' >>"$repo/AGENTS.md"
add_later_round "$repo"
jq '.reviewed_tree = "0123456789abcdef0123456789abcdef01234567"' "$repo/$review" >"$repo/$review.tmp"
mv "$repo/$review.tmp" "$repo/$review"
expect_no_triage "$repo" "the reviewed tree is missing" "$review"
grep -Fq "not a tree in the Git object database" "$repo.out" || fail "a missing tree was not named"
[[ ! -e "$repo.log" ]] || fail "a triage agent was started without the reviewed tree"

# A reviewed_tree that is a revision, not an object hash, is not extracted.
repo="$(setup_repo tree-is-ref)"
printf 'changed after the review\n' >>"$repo/AGENTS.md"
add_later_round "$repo"
jq '.reviewed_tree = "HEAD"' "$repo/$review" >"$repo/$review.tmp"
mv "$repo/$review.tmp" "$repo/$review"
expect_no_triage "$repo" "the reviewed tree is a revision, not a hash" "$review"
[[ ! -e "$repo.log" ]] || fail "a triage agent was started for a reviewed_tree that is a revision"

# A commit hash as reviewed_tree is not a tree and is not extracted.
repo="$(setup_repo tree-is-commit)"
printf 'changed after the review\n' >>"$repo/AGENTS.md"
add_later_round "$repo"
jq --arg c "$(git -C "$repo" rev-parse HEAD)" '.reviewed_tree = $c' "$repo/$review" >"$repo/$review.tmp"
mv "$repo/$review.tmp" "$repo/$review"
expect_no_triage "$repo" "the reviewed tree is a commit" "$review"
[[ ! -e "$repo.log" ]] || fail "a triage agent was started for a reviewed_tree that is a commit"

# A later round of another Issue, or an invalid one, does not make it historical.
repo="$(setup_repo other-issue)"
printf 'changed after the review\n' >>"$repo/AGENTS.md"
add_later_round "$repo"
jq '.issue = 6' "$repo/.agents/reviews/feature-5-test-review-02.json" >"$tmp/r2.json"
mv "$tmp/r2.json" "$repo/.agents/reviews/feature-5-test-review-02.json"
expect_no_triage "$repo" "the later round belongs to another Issue" "$review"

# Owner-directed triage: the agent proposes FIX_NOW for the suggestion, the
# owner decides ACCEPT, and exactly the owner's decision is stored and published.
agent_proposal="$(jq '.decisions[2] = {"finding_id": "S1", "decision": "FIX_NOW", "rationale": "Rename it now.", "followup": null}' <<<"$valid_decisions")"
owner_decisions="$valid_decisions"
reason="The rename is not worth another review cycle."

# An override asks twice: for the decisions, and for the complete artifact.
run_owner() {
  local repo="$1"
  local answer="$2"
  shift 2
  [[ "$answer" != y ]] || answer=$'y\ny'
  run_triage "$repo" "$answer" "$review" "$@"
}

repo="$(setup_repo owner)"
printf '%s\n' "$owner_decisions" >"$repo.decisions.json"
printf '%s\n' "$agent_proposal" >"$repo.proposal.json"
run_owner "$repo" y --decisions "$repo.decisions.json" --reason "$reason" --proposal "$repo.proposal.json" || {
  cat "$repo.out" >&2
  fail "owner-directed triage failed"
}
artifact="$repo/.agents/triage/feature-5-test-review-01-triage"
[[ ! -e "$repo.log" ]] || fail "an agent was started for an owner-directed triage"
[[ "$(jq -r '.decisions[2].decision' "$artifact.json")" == "ACCEPT" ]] || fail "the owner's ACCEPT was not stored"
[[ "$(jq -r '.decisions[2].rationale' "$artifact.json")" == "The name is adequate." ]] || fail "the owner's rationale was changed"
[[ "$(jq -c '[.decisions[] | {finding_id, decision, rationale}]' "$artifact.json")" == \
  "$(jq -c '[.decisions[] | {finding_id, decision, rationale}]' <<<"$owner_decisions")" ]] || fail "the stored decisions differ from the owner's"
[[ "$(jq -r '.owner_directed.reason' "$artifact.json")" == "$reason" ]] || fail "the reason was not recorded"
[[ "$(jq -r '.owner_directed.account' "$artifact.json")" == "owner-login" ]] || fail "the account was not recorded"
jq -e '.owner_directed.directed_at | test("^[0-9]{4}-")' "$artifact.json" >/dev/null || fail "the time was not recorded"
[[ "$(jq -r '.owner_directed.original_proposal.decisions[2].decision' "$artifact.json")" == "FIX_NOW" ]] ||
  fail "the original proposal was not recorded"
jq -e '.published_at' "$artifact.json" >/dev/null || fail "the owner-directed triage was not published"
grep -Fq "Owner-directed triage" "$repo.gh.comments" || fail "the comment does not show the override"
grep -Fq "$reason" "$repo.gh.comments" || fail "the comment lacks the reason"
grep -Fq "S1: FIX_NOW — Rename it now." "$repo.gh.comments" || fail "the comment lacks the original proposal"
shown="$(sed '/Proceed with this triage/,$d' "$repo.out")"
[[ "$shown" == *"OWNER-DIRECTED TRIAGE"* && "$shown" == *"The name is adequate."* ]] || fail "the owner's decisions were not shown before the question"
(
  source "$source_root/scripts/lib/review-data.sh"
  [[ -z "$(triage_artifact_errors "$artifact.json" "$repo/$review")" ]]
) || fail "the owner-directed artifact is not valid"
# apply-triage.sh and finish-feature.sh read the stored decisions as they are:
# the artifact is covered by the artifact fingerprint.
(
  source "$source_root/scripts/lib/fingerprint.sh"
  before="$(fingerprint_artifacts "$repo")"
  jq '.decisions[2].decision = "FIX_NOW"' "$artifact.json" >"$tmp/changed.json"
  cp "$tmp/changed.json" "$artifact.json"
  [[ "$(fingerprint_artifacts "$repo")" != "$before" ]]
) || fail "a change to the stored triage was not detected"

# Exactly what was shown is stored: the inputs are copied before they are shown,
# so changing the files while the question is open changes nothing.
repo="$(setup_repo owner-exact)"
printf '%s\n' "$owner_decisions" >"$repo.decisions.json"
printf '%s\n' "$agent_proposal" >"$repo.proposal.json"
MOCK_GH_USER_ACTION="jq '.decisions[2].decision = \"FIX_NOW\"' '$repo.decisions.json' >'$repo.d.tmp' && mv '$repo.d.tmp' '$repo.decisions.json'; printf '{\"decisions\": []}' >'$repo.proposal.json'" \
  run_owner "$repo" y --decisions "$repo.decisions.json" --reason "$reason" --proposal "$repo.proposal.json" || {
  cat "$repo.out" >&2
  fail "owner-directed triage with changing inputs failed"
}
artifact="$repo/.agents/triage/feature-5-test-review-01-triage.json"
[[ "$(jq -r '.decisions[2].decision' "$artifact")" == "ACCEPT" ]] || fail "a changed decisions file changed the stored decision"
[[ "$(jq -r '.owner_directed.original_proposal.decisions[2].decision' "$artifact")" == "FIX_NOW" ]] ||
  fail "a changed proposal file changed the stored original proposal"
# The complete artifact that was shown for the final confirmation is the
# artifact that is stored, byte for byte, apart from published_at.
shown_artifact="$(sed -n '/^The complete triage artifact, as it will be stored:/,/^Store and publish exactly/p' "$repo.out" | sed '1d;$d')"
[[ "$shown_artifact" == "$(jq 'del(.published_at)' "$artifact")" ]] || fail "the stored artifact differs from the artifact that was shown"
[[ "$(jq -r '.decisions[1].followup.issue_number' <<<"$shown_artifact")" == "123" ]] || fail "the shown artifact lacks the follow-up reference"

# Declining the complete artifact stores and publishes nothing.
repo="$(setup_repo owner-final-declined)"
printf '%s\n' "$owner_decisions" >"$repo.decisions.json"
(
  cd "$repo"
  printf 'y\nn\n' | PATH="$tmp/bin:/usr/bin:/bin" MOCK_GH_LOG="$repo.gh" \
    ./scripts/triage-review.sh "$review" --decisions "$repo.decisions.json" --reason "$reason"
) >"$repo.out" 2>&1 || fail "declining the final confirmation returned an error"
if compgen -G "$repo/.agents/triage/*" >/dev/null || [[ -e "$repo.gh.comments" ]]; then
  fail "a declined final confirmation stored or published something"
fi

# Without a proposal, the artifact has none.
repo="$(setup_repo owner-no-proposal)"
printf '%s\n' "$owner_decisions" >"$repo.decisions.json"
run_owner "$repo" y --decisions "$repo.decisions.json" --reason "$reason" || fail "owner-directed triage without a proposal failed"
jq -e '.owner_directed | has("original_proposal") | not' "$repo/.agents/triage/feature-5-test-review-01-triage.json" >/dev/null ||
  fail "an original proposal was recorded although none was given"

# Without a determined GitHub account the override fails closed: no artifact,
# no Issue, no comment, and no fallback to the local user name.
for account_failure in "MOCK_GH_USER_EXIT=1" "MOCK_GH_USER="; do
  repo="$(setup_repo "owner-no-account-${account_failure%%=*}-${account_failure#*=}")"
  printf '%s\n' "$owner_decisions" >"$repo.decisions.json"
  export "$account_failure"
  expect_no_triage "$repo" "the GitHub account cannot be determined ($account_failure)" "$review" --decisions "$repo.decisions.json" --reason "$reason"
  unset "${account_failure%%=*}"
  grep -Fq "authenticated GitHub account" "$repo.out" || fail "the missing account was not reported"
  [[ ! -e "$repo.gh.comments" ]] || fail "something was published without an account"
done

# Declining stores and publishes nothing; --unattended does not apply.
repo="$(setup_repo owner-declined)"
printf '%s\n' "$owner_decisions" >"$repo.decisions.json"
run_owner "$repo" n --decisions "$repo.decisions.json" --reason "$reason" || fail "declined override returned an error"
if compgen -G "$repo/.agents/triage/*" >/dev/null || [[ -e "$repo.gh" || -e "$repo.gh.comments" ]]; then
  fail "a declined override had side effects"
fi
repo="$(setup_repo owner-unattended)"
printf '%s\n' "$owner_decisions" >"$repo.decisions.json"
expect_no_triage "$repo" "an override cannot be unattended" "$review" --decisions "$repo.decisions.json" --reason "$reason" --unattended
[[ ! -e "$repo.log" ]] || fail "an agent was started for an unattended override"

# A missing reason, and invalid decisions, are refused before any side effect.
repo="$(setup_repo owner-invalid)"
printf '%s\n' "$owner_decisions" >"$repo.decisions.json"
expect_no_triage "$repo" "the reason is missing" "$review" --decisions "$repo.decisions.json"
expect_no_triage "$repo" "the reason is blank" "$review" --decisions "$repo.decisions.json" --reason "  "
expect_no_triage "$repo" "the decisions file is missing" "$review" --decisions "$repo.nothing.json" --reason "$reason"
owner_invalid=(
  "$incomplete_decisions"
  "$(jq '.decisions += [.decisions[2]]' <<<"$valid_decisions")"
  "$(jq '.decisions[2].finding_id = "S9"' <<<"$valid_decisions")"
  "$(jq '.decisions[1].followup = null' <<<"$valid_decisions")"
  "$(jq '.decisions[2].rationale = ""' <<<"$valid_decisions")"
  "$downgraded_decisions"
  "$(jq '.decisions[0].decision = "ACCEPT"' <<<"$valid_decisions")"
)
for index in "${!owner_invalid[@]}"; do
  printf '%s\n' "${owner_invalid[$index]}" >"$repo.decisions.json"
  expect_no_triage "$repo" "the owner's decisions are invalid ($index)" "$review" --decisions "$repo.decisions.json" --reason "$reason"
done
printf '%s\n' "$owner_decisions" >"$repo.decisions.json"
printf '{"decisions": []}\n' >"$repo.proposal.json"
expect_no_triage "$repo" "the original proposal is invalid" "$review" --decisions "$repo.decisions.json" --reason "$reason" --proposal "$repo.proposal.json"
[[ ! -e "$repo.log" ]] || fail "an agent was started for an override"

# The audit fields are validated, and an artifact without them stays valid.
repo="$(setup_repo owner-audit)"
printf '%s\n' "$owner_decisions" >"$repo.decisions.json"
run_owner "$repo" y --decisions "$repo.decisions.json" --reason "$reason" || fail "owner-directed triage failed"
artifact="$repo/.agents/triage/feature-5-test-review-01-triage.json"
for edit in '.owner_directed.reason = ""' 'del(.owner_directed.account)' '.owner_directed.directed_at = "now"' \
  '.owner_directed.extra = 1' '.owner_directed = "x"' '.unattended = true'; do
  jq "$edit" "$artifact" >"$tmp/audit.json"
  [[ -n "$(source "$source_root/scripts/lib/review-data.sh"; triage_artifact_errors "$tmp/audit.json" "$repo/$review")" ]] ||
    fail "an invalid owner_directed was accepted: $edit"
done
jq 'del(.owner_directed) | .triage = {agent: "claude", model: "model-t"}' "$artifact" >"$tmp/old.json"
[[ -z "$(source "$source_root/scripts/lib/review-data.sh"; triage_artifact_errors "$tmp/old.json" "$repo/$review")" ]] ||
  fail "an artifact without the new fields is no longer valid"

echo "triage-review tests passed"
