#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/finish-feature-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "finish-feature test failed: $*" >&2
  exit 1
}

source "$source_root/tests/lib-fakes.sh"
make_fake_agents "$tmp/bin"

review=".agents/reviews/feature-12-marker-review-01.json"
triage=".agents/triage/feature-12-marker-review-01-triage.json"

# set_completion <repo> <status>
# Writes the implementer's completion record of the Issue with that status.
set_completion() {
  local remaining='[]'
  local met="met"

  if [[ "$2" != "complete" ]]; then
    remaining='["Plan steps 3 to 9"]'
    met="not_met"
  fi
  mkdir -p "$1/.agents/completion"
  jq -n --arg status "$2" --arg met "$met" --argjson remaining "$remaining" '{
    schema: "completion/v1", status: $status,
    criteria: [
      {criterion: "The marker exists", status: "met", evidence: "feature.txt"},
      {criterion: "The marker is documented", status: $met, evidence: "docs/marker.md"}
    ],
    remaining: $remaining
  }' >"$1/.agents/completion/12.json"
}

# Creates a feature repository with an uncommitted change, a completion record
# that says complete, and a current review.
# setup_repo <label> <verdict> <findings-json>
setup_repo() {
  local repo="$tmp/$1"

  mkdir -p "$repo/.agents/reviews" "$repo/.agents/triage"
  copy_workflow "$repo"
  cp "$source_root/.gitignore" "$repo/.gitignore"
  printf 'marker: test -f AGENTS.md\n' >"$repo/scripts/verify.conf"
  printf '# Agents\n' >"$repo/AGENTS.md"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.name "Finish Test"
  git -C "$repo" config user.email "finish-test@example.com"
  git -C "$repo" add .
  git -C "$repo" commit -qm "Seed"
  git -C "$repo" switch -q -c feature/12-marker
  printf 'feature work\n' >"$repo/feature.txt"
  set_completion "$repo" complete

  # The review names the base it compared the feature with: the merge base
  # the feature has, which finish-feature.sh checks.
  jq -n --arg verdict "$2" --argjson findings "$3" --arg merge_base "$(git -C "$repo" rev-parse main)" '{
    schema: "review/v1", kind: "feature", issue: 12, round: 1,
    branch: "feature/12-marker", base: "main", merge_base: $merge_base, head: "bbbb",
    reviewed_tree: "", reviewed_paths: null,
    reviewer: {agent: "claude", model: "model-r"}, created_at: "2026-01-01T00:00:00Z",
    verdict: $verdict, limitations: "", findings: $findings
  }' >"$repo/$review"
  record_reviewed_tree "$repo" "$repo/$review"

  printf '%s\n' "$repo"
}

# add_triage <repo> <decision> [published]
add_triage() {
  local repo="$1"

  jq --arg decision "$2" --arg published "${3:-yes}" '{
    schema: "triage/v1", source_review: ".agents/reviews/feature-12-marker-review-01.json", issue,
    reviewed_tree, review_verdict: .verdict, triage: {agent: "codex", model: "model-t"},
    approved_at: "2026-01-02T00:00:00Z",
    decisions: [.findings[] | {finding_id: .id, severity, title, decision: $decision, rationale: "Considered.",
      followup: (if $decision == "DEFER" then {title: "[#12][R01][\(.id)] Later", recommended_action: "Later.",
        acceptance_criteria: ["Done."], issue_number: 99, issue_url: "https://github.com/example/project/issues/99"} else null end)}]
  } + (if $published == "yes" then {published_at: "2026-01-02T00:01:00Z"} else {} end)' "$repo/$review" >"$repo/$triage"
}

# claims_changed <repo>
# The completion record and the handoff note are part of what a review of
# the feature covers: a change to either after the review makes it stale.
# A case that changes them after the fixture review, and expects the review
# to count, records the review as made on the changed claims.
claims_changed() {
  local extra=""

  [[ ! -f "$1/$triage" ]] || extra="$1/$triage"
  record_reviewed_tree "$1" "$1/$review" $extra
}

minor='[{"id": "MIN1", "severity": "minor", "title": "Vague name", "evidence": "feature.txt:1", "impact": "Readability.", "recommendation": "Rename."}]'
major='[{"id": "M1", "severity": "major", "title": "Wrong result", "evidence": "feature.txt:1", "impact": "Bug.", "recommendation": "Fix."}]'

run_finish() {
  local repo="$1"
  shift

  (
    cd "$repo"
    PATH="$tmp/bin:/usr/bin:/bin" GIT_EDITOR="${EDITOR_COMMAND:-true}" ./scripts/finish-feature.sh "$@"
  ) >"$repo.out" 2>&1
}

expect_no_commit() {
  local repo="$1"
  local description="$2"
  shift 2

  if run_finish "$repo" "$@"; then
    cat "$repo.out" >&2
    fail "expected refusal: $description"
  fi
  [[ "$(git -C "$repo" rev-list --count HEAD)" -eq 1 ]] || fail "a commit was created although: $description"
}

message() {
  git -C "$1" log -1 --format=%B
}

# A feature with a passed, current review is committed with a structured
# message; review and triage files are not committed.
repo="$(setup_repo pass PASS "[]")"
run_finish "$repo" 12 "Add the marker" || {
  cat "$repo.out" >&2
  fail "finishing a reviewed feature failed"
}
[[ "$(git -C "$repo" rev-list --count HEAD)" -eq 2 ]] || fail "no commit was created"
for line in "Add the marker" "Issue: #12" "Review: round 1, PASS, by claude (model-r)" "Refs #12"; do
  grep -Fqx "$line" <<<"$(message "$repo")" || fail "the commit message lacks: $line"
done
grep -Fqx "feature.txt" <<<"$(git -C "$repo" show --name-only --format= HEAD)" || fail "the feature change was not committed"
if grep -Fq ".agents/reviews/" <<<"$(git -C "$repo" show --name-only --format= HEAD)"; then
  fail "a review file was committed"
fi
grep -Fq "./scripts/publish-feature.sh 12" "$repo.out" || fail "the next steps do not name publish-feature.sh"
grep -Fqx -- "- none" <<<"$(message "$repo" | grep -A1 -Fx "Manual steps:")" ||
  fail "a feature without manual steps does not say so in the commit message"

# Manual steps recorded by the implementer are shown before the commit and
# recorded in the message. The file is a working file: it is not committed and
# writing it after the review does not make the review stale.
repo="$(setup_repo manual PASS "[]")"
mkdir -p "$repo/.agents/manual-steps"
printf -- '- Enable GitHub Pages under Settings, Pages.\n\n- Add the secret API_KEY.\n' >"$repo/.agents/manual-steps/12.md"
printf -- '- A step of another Issue.\n' >"$repo/.agents/manual-steps/99.md"
run_finish "$repo" 12 "Add the marker" || {
  cat "$repo.out" >&2
  fail "finishing a feature with manual steps failed"
}
grep -Fq "This feature needs these manual steps from you:" "$repo.out" || fail "the manual steps were not shown"
[[ "$(message "$repo" | sed -n '/^Manual steps:$/,/^$/p')" == "Manual steps:
- Enable GitHub Pages under Settings, Pages.
- Add the secret API_KEY." ]] || fail "the commit message does not list exactly the manual steps of the Issue"
if grep -Fq "manual-steps" <<<"$(git -C "$repo" show --name-only --format= HEAD)"; then
  fail "the manual steps file was committed"
fi

# A pass that was recorded for exactly this content is not run again; any
# change to the content is verified again before the commit.
count_runs() {
  grep -c . "$1/verify-count.log" 2>/dev/null || true
}

repo="$(setup_repo reuse PASS "[]")"
printf 'count: echo run >>verify-count.log\n' >"$repo/scripts/verify.conf"
record_reviewed_tree "$repo" "$repo/$review"
(cd "$repo" && PATH="$tmp/bin:/usr/bin:/bin" ./scripts/verify.sh >/dev/null) || fail "the first verification failed"
[[ "$(count_runs "$repo")" -eq 1 ]] || fail "the first verification did not run"
run_finish "$repo" 12 "Add the marker" || {
  cat "$repo.out" >&2
  fail "finishing verified content failed"
}
[[ "$(count_runs "$repo")" -eq 1 ]] || fail "verification ran again for unchanged content"
[[ "$(git -C "$repo" rev-list --count HEAD)" -eq 2 ]] || fail "no commit was created after a reused verification"

repo="$(setup_repo reverify PASS "[]")"
printf 'count: echo run >>verify-count.log\n' >"$repo/scripts/verify.conf"
(cd "$repo" && PATH="$tmp/bin:/usr/bin:/bin" ./scripts/verify.sh >/dev/null) || fail "the first verification failed"
printf 'more feature work\n' >>"$repo/feature.txt"
record_reviewed_tree "$repo" "$repo/$review"
run_finish "$repo" 12 "Add the marker" || fail "finishing changed content failed"
[[ "$(count_runs "$repo")" -eq 2 ]] || fail "changed content was committed without a new verification"

# A feature is committed on a review of the complete feature. A latest round
# that reviewed only the changes since an earlier one confirms fixes; it does
# not establish that the Issue is done, so it is refused.
# add_changes_review <repo>: makes round 2 a passed review of the changes
# since round 1, after a further change, and prints its path.
add_changes_review() {
  local repo="$1"
  local second="$repo/.agents/reviews/feature-12-marker-review-02.json"

  jq '.round = 2 | .verdict = "PASS" | .findings = []
      | .scope = {kind: "changes", since_round: 1, base_tree: .reviewed_tree}' "$repo/$review" >"$second"
  printf 'the fix\n' >>"$repo/feature.txt"
  record_reviewed_tree "$repo" "$second"
  printf '%s\n' "$second"
}

repo="$(setup_repo changes-latest PASS "[]")"
second="$(add_changes_review "$repo")"
expect_no_commit "$repo" "the latest review covers only changes" 12 "Add the marker"
grep -Fq "covers only the changes since round 1" "$repo.out" || fail "the review of changes only was not given as the reason"
grep -Fq "./scripts/review-feature.sh 12 (without --changes)" "$repo.out" ||
  fail "the review of the complete feature was not asked for"
# A third round that reviews the complete feature again is accepted.
jq '.round = 3 | del(.scope)' "$second" >"$repo/.agents/reviews/feature-12-marker-review-03.json"
run_finish "$repo" 12 "Add the marker" || {
  cat "$repo.out" >&2
  fail "finishing on a review of the complete feature after a review of changes failed"
}
grep -Fqx "Review: round 3, PASS, by claude (model-r)" <<<"$(message "$repo")" ||
  fail "the commit message does not name the review of the complete feature"

# A latest round made on a partial check (verification.status: partial) is
# an intermediate round too, also when it reviewed the complete feature
# after a further change; a later round on the full verification is
# accepted. The hand-run path after an interrupted run of a high-risk
# feature ends here.
# add_partial_review <repo>: makes round 2 a passed review of the complete
# feature on a partial check, after a further change, and prints its path.
add_partial_review() {
  local repo="$1"
  local second="$repo/.agents/reviews/feature-12-marker-review-02.json"

  jq '.round = 2 | .verdict = "PASS" | .findings = []
      | .verification = {status: "partial", groups: ["fast"], verified_at: "2026-01-01T00:00:00Z"}' "$repo/$review" >"$second"
  printf 'the fix\n' >>"$repo/feature.txt"
  record_reviewed_tree "$repo" "$second"
  printf '%s\n' "$second"
}

repo="$(setup_repo partial-latest PASS "[]")"
second="$(add_partial_review "$repo")"
expect_no_commit "$repo" "the latest review was made on a partial check" 12 "Add the marker"
grep -Fq "partially checked content" "$repo.out" || fail "the partial check was not given as the reason"
jq '.round = 3 | del(.verification)' "$second" >"$repo/.agents/reviews/feature-12-marker-review-03.json"
run_finish "$repo" 12 "Add the marker" || {
  cat "$repo.out" >&2
  fail "finishing on a review on the full verification after a review on a partial check failed"
}
grep -Fqx "Review: round 3, PASS, by claude (model-r)" <<<"$(message "$repo")" ||
  fail "the commit message does not name the review on the full verification"

# Minor findings that were triaged without FIX_NOW and published are fine.
repo="$(setup_repo minor PASS_WITH_MINOR_FINDINGS "$minor")"
add_triage "$repo" DEFER
run_finish "$repo" 12 "Add the marker" || {
  cat "$repo.out" >&2
  fail "finishing with published, deferred minor findings failed"
}
grep -Fq "triage published on #12" <<<"$(message "$repo")" || fail "the commit message does not mention the published triage"

# A round triaged by the owner's override, with the original proposal of the
# agent recorded, is accepted like any other published triage.
repo="$(setup_repo owner-directed PASS_WITH_MINOR_FINDINGS "$minor")"
add_triage "$repo" ACCEPT
jq '.triage = {agent: "owner", model: "owner-directed"}
    | .owner_directed = {account: "owner-login", directed_at: "2026-01-02T00:00:00Z",
        reason: "Not worth another cycle.",
        original_proposal: {decisions: [{finding_id: "MIN1", decision: "FIX_NOW", rationale: "Rename.", followup: null}]}}' \
  "$repo/$triage" >"$tmp/owner.tmp"
mv "$tmp/owner.tmp" "$repo/$triage"
run_finish "$repo" 12 "Add the marker" || {
  cat "$repo.out" >&2
  fail "finishing with an owner-directed triage failed"
}
grep -Fq "triage published on #12" <<<"$(message "$repo")" || fail "the commit message does not mention the owner-directed triage"
# An unpublished owner-directed triage is still refused.
repo="$(setup_repo owner-directed-unpublished PASS_WITH_MINOR_FINDINGS "$minor")"
add_triage "$repo" ACCEPT no
jq '.owner_directed = {account: "owner-login", directed_at: "2026-01-02T00:00:00Z", reason: "r"}' "$repo/$triage" >"$tmp/owner.tmp"
mv "$tmp/owner.tmp" "$repo/$triage"
expect_no_commit "$repo" "the owner-directed triage was not published" 12 "Add the marker"

# add_second_round <repo>: a passed, current review round 2.
add_second_round() {
  jq '.round = 2 | .verdict = "PASS" | .findings = []' "$1/$review" >"$1/.agents/reviews/feature-12-marker-review-02.json"
  record_reviewed_tree "$1" "$1/.agents/reviews/feature-12-marker-review-02.json"
}

# A newer, passed round confirms the FIX_NOW fixes of an earlier round, but
# does not excuse an earlier round that was never triaged or published.
repo="$(setup_repo fixed-in-round-2 CHANGES_REQUIRED "$major")"
add_triage "$repo" FIX_NOW
printf 'fixed\n' >>"$repo/feature.txt"
add_second_round "$repo"
run_finish "$repo" 12 "Add the marker" || {
  cat "$repo.out" >&2
  fail "a passed second round after applied fixes was refused"
}
grep -Fq "Review: round 2, PASS" <<<"$(message "$repo")" || fail "the commit message does not name the final round"

repo="$(setup_repo untriaged-round-1 PASS_WITH_MINOR_FINDINGS "$minor")"
add_second_round "$repo"
expect_no_commit "$repo" "round 1 was never triaged" 12 "Add the marker"

repo="$(setup_repo unpublished-round-1 PASS_WITH_MINOR_FINDINGS "$minor")"
add_triage "$repo" ACCEPT no
add_second_round "$repo"
expect_no_commit "$repo" "the triage of round 1 was never published" 12 "Add the marker"

# The newest triage of a round counts, by number: -triage-02 after -triage.
repo="$(setup_repo newest-triage PASS_WITH_MINOR_FINDINGS "$minor")"
add_triage "$repo" ACCEPT
cp "$repo/$triage" "${repo}/.agents/triage/feature-12-marker-review-01-triage-02.json"
jq 'del(.published_at)' "${repo}/.agents/triage/feature-12-marker-review-01-triage-02.json" >"$tmp/triage.tmp"
mv "$tmp/triage.tmp" "${repo}/.agents/triage/feature-12-marker-review-01-triage-02.json"
expect_no_commit "$repo" "the newest triage was not published" 12 "Add the marker"

# A low-risk change may be finished without a review; the reason is recorded.
repo="$(setup_repo no-review PASS "[]")"
rm "$repo/$review"
run_finish "$repo" 12 "Fix a typo" --no-review "documentation typo" || {
  cat "$repo.out" >&2
  fail "finishing without a review failed"
}
grep -Fqx "Review: no independent review (low risk: documentation typo)" <<<"$(message "$repo")" ||
  fail "the commit message does not record the missing review"

# The list of changes comes from the implementer's summary: its list items,
# and nothing else. The file is a working file and is not committed.
changes_of() {
  message "$1" | sed -n '/^Changes:$/,/^$/p'
}

repo="$(setup_repo summary PASS "[]")"
mkdir -p "$repo/.agents/summaries"
printf 'Summary of the feature:\n\n- Adds the marker file.\n  - Explains why it matters.\n-not an item\n- \n' \
  >"$repo/.agents/summaries/12.md"
printf -- '- A change of another Issue.\n' >"$repo/.agents/summaries/99.md"
run_finish "$repo" 12 "Add the marker" || {
  cat "$repo.out" >&2
  fail "finishing a feature with a summary failed"
}
[[ "$(changes_of "$repo")" == "Changes:
- Adds the marker file.
- Explains why it matters." ]] || fail "the commit message does not list exactly the summarized changes"
if grep -Fq "summaries" <<<"$(git -C "$repo" show --name-only --format= HEAD)"; then
  fail "the summary file was committed"
fi

# Without a summary you fill in the list yourself, in the editor.
repo="$(setup_repo no-summary PASS "[]")"
run_finish "$repo" 12 "Add the marker" || fail "finishing a feature without a summary failed"
[[ "$(changes_of "$repo")" == "Changes:
- TODO: summarize the main changes" ]] || fail "the list of changes to fill in is missing"

# --unattended commits without an editor. Nobody edits that message, so it
# refuses when the implementer left no summary of the changes.
repo="$(setup_repo unattended-no-summary PASS "[]")"
EDITOR_COMMAND=false expect_no_commit "$repo" "an unattended commit has no summary of the changes" 12 "Add the marker" --unattended
grep -Fq "the implementer supplied no summary of the changes" "$repo.out" || fail "the missing summary was not given as the reason"
grep -Fq "./scripts/start-feature.sh 12 --resume" "$repo.out" || fail "resuming the implementer was not offered for the missing summary"

repo="$(setup_repo unattended PASS "[]")"
mkdir -p "$repo/.agents/summaries"
printf -- '- Adds the marker.\n' >"$repo/.agents/summaries/12.md"
EDITOR_COMMAND=false run_finish "$repo" 12 "Add the marker" --unattended || {
  cat "$repo.out" >&2
  fail "finishing unattended failed"
}
[[ "$(git -C "$repo" rev-list --count HEAD)" -eq 2 ]] || fail "finishing unattended created no commit"
[[ "$(changes_of "$repo")" == "Changes:
- Adds the marker." ]] || fail "an unattended commit does not carry the implementer's summary"
grep -Fqx "Review: round 1, PASS, by claude (model-r)" <<<"$(message "$repo")" || fail "the unattended commit lacks its review"

# The completion gate. A feature is committed as done only on a completion
# record of the implementer that says complete; the commit message carries
# the statement with the evidence per criterion.
repo="$(setup_repo completion-complete PASS "[]")"
run_finish "$repo" 12 "Add the marker" || fail "finishing a complete feature failed"
[[ "$(message "$repo" | sed -n '/^Completion: /,/^$/p')" == "Completion: complete
- met: The marker exists (feature.txt)
- met: The marker is documented (docs/marker.md)" ]] || fail "the commit message does not carry the completion statement"
if grep -Fq "completion" <<<"$(git -C "$repo" show --name-only --format= HEAD)"; then
  fail "the completion record was committed"
fi

repo="$(setup_repo completion-missing PASS "[]")"
rm "$repo/.agents/completion/12.json"
expect_no_commit "$repo" "the implementer wrote no completion record" 12 "Add the marker"
grep -Fq "the implementer wrote no completion record (.agents/completion/12.json)" "$repo.out" ||
  fail "the missing completion record was not given as the reason"
grep -Fq "./scripts/start-feature.sh 12 --resume" "$repo.out" || fail "resuming was not offered for the missing record"
# Your own choice does not replace the record either: --partial needs one.
expect_no_commit "$repo" "no completion record, with --partial" 12 "Add the marker" --partial

repo="$(setup_repo completion-partial PASS "[]")"
set_completion "$repo" partial
expect_no_commit "$repo" "the completion record says partial" 12 "Add the marker"
grep -Fq "the feature is not complete (partial)" "$repo.out" || fail "the partial record was not given as the reason"
grep -Fq "remaining: Plan steps 3 to 9" "$repo.out" || fail "the remaining work was not shown"
grep -Fq "not met: The marker is documented" "$repo.out" || fail "the criterion that is not met was not shown"
expect_no_commit "$repo" "the completion record says partial, unattended" 12 "Add the marker" --unattended

repo="$(setup_repo completion-blocked PASS "[]")"
set_completion "$repo" blocked
expect_no_commit "$repo" "the completion record says blocked" 12 "Add the marker"

# A record that says complete is not believed against the handoff note.
repo="$(setup_repo completion-contradicted PASS "[]")"
mkdir -p "$repo/.agents/handoffs"
printf '**Done:** steps 1 and 2.\n**Remaining:** steps 3 to 9.\n**Open questions:** none\n' >"$repo/.agents/handoffs/12.md"
expect_no_commit "$repo" "the handoff note lists remaining work" 12 "Add the marker"
grep -Fq "the handoff note (.agents/handoffs/12.md) lists remaining work" "$repo.out" ||
  fail "the handoff note was not given as the reason"
grep -Fq "remaining: steps 3 to 9." "$repo.out" || fail "the remaining work of the handoff note was not shown"
printf 'Issue 12 is complete.\n' >"$repo/.agents/handoffs/12.md"
expect_no_commit "$repo" "the handoff note changed after the review" 12 "Add the marker"
grep -Fq "is stale" "$repo.out" || fail "a handoff note changed after the review did not make it stale"
claims_changed "$repo"
run_finish "$repo" 12 "Add the marker" || fail "a handoff note without remaining work stopped the commit"

invalid_count=0
for broken in 'not json' '{"schema": "completion/v1", "status": "complete", "criteria": [], "remaining": []}' \
  '{"schema": "completion/v1", "status": "done", "criteria": [{"criterion": "a", "status": "met", "evidence": "b"}], "remaining": []}' \
  '{"schema": "completion/v1", "status": "complete", "criteria": [{"criterion": "a", "status": "not_met", "evidence": "b"}], "remaining": []}' \
  '{"schema": "completion/v1", "status": "complete", "criteria": [{"criterion": "a", "status": "met", "evidence": ""}], "remaining": []}' \
  '{"schema": "completion/v1", "status": "complete", "criteria": [{"criterion": "a", "status": "met", "evidence": "b"}], "remaining": ["more"]}' \
  '{"schema": "completion/v1", "status": "partial", "criteria": [{"criterion": "a", "status": "met", "evidence": "b"}], "remaining": []}'; do
  invalid_count=$((invalid_count + 1))
  repo="$(setup_repo "completion-invalid-$invalid_count" PASS "[]")"
  printf '%s\n' "$broken" >"$repo/.agents/completion/12.json"
  expect_no_commit "$repo" "an invalid completion record: $broken" 12 "Add the marker"
  grep -Fq "the completion record cannot be used" "$repo.out" || fail "an invalid record was not refused as invalid: $broken"
  expect_no_commit "$repo" "an invalid completion record with --partial: $broken" 12 "Add the marker" --partial
done

# --partial is your explicit choice to commit work that is not complete. The
# commit says so, with what remains.
repo="$(setup_repo completion-partial-chosen PASS "[]")"
set_completion "$repo" partial
claims_changed "$repo"
run_finish "$repo" 12 "Add the first part of the marker" --partial || {
  cat "$repo.out" >&2
  fail "committing partial work with --partial failed"
}
[[ "$(message "$repo" | sed -n '/^Completion: /,/^$/p')" == "Completion: partial
- met: The marker exists (feature.txt)
- not met: The marker is documented (docs/marker.md)
- remaining: Plan steps 3 to 9" ]] || fail "the commit message of partial work does not say what remains"
grep -Fq "does not close Issue #12" "$repo.out" || fail "the draft pull request was not announced for partial work"

# --partial takes what the record says into the commit, so a record that says
# complete, contradicted by the handoff note, is not committed as partial: it
# would be recorded as complete, without what remains.
repo="$(setup_repo completion-partial-contradicted PASS "[]")"
mkdir -p "$repo/.agents/handoffs"
printf '**Remaining:** steps 3 to 9.\n' >"$repo/.agents/handoffs/12.md"
expect_no_commit "$repo" "--partial with a record that says complete against the handoff note" 12 "Add the marker" --partial
grep -Fq "the completion record says complete, so the work cannot be committed as partial" "$repo.out" ||
  fail "the contradicted record was not given as the reason with --partial"
grep -Fq "remaining: steps 3 to 9." "$repo.out" || fail "what the handoff note lists was not shown with --partial"
# With the record corrected, the same work is committed as partial.
set_completion "$repo" partial
claims_changed "$repo"
run_finish "$repo" 12 "Add the first part of the marker" --partial || fail "partial work with a corrected record was refused"
grep -Fqx "Completion: partial" <<<"$(message "$repo")" || fail "the corrected record was not committed as partial"
if grep -Fqx "Completion: complete" <<<"$(message "$repo")"; then fail "work with remaining steps was committed as complete"; fi

# Evidence of a later gate does not hold back the commit: the feature is
# committed as awaiting_evidence, without --partial and without --no-review.
repo="$(setup_repo completion-awaiting PASS "[]")"
jq '.status = "awaiting_evidence"
  | .criteria[1] = {criterion: "CI passes on the pull request", gate: "pr_ci", status: "pending", evidence: "after publication"}
  | .criteria += [{criterion: "main verifies", gate: "post_merge", status: "pending", evidence: "the run on main"}]' \
  "$repo/.agents/completion/12.json" >"$repo/completion.tmp"
mv "$repo/completion.tmp" "$repo/.agents/completion/12.json"
claims_changed "$repo"
run_finish "$repo" 12 "Add the marker" || {
  cat "$repo.out" >&2
  fail "a feature that awaits later evidence was refused"
}
grep -Fqx "Completion: awaiting_evidence" <<<"$(message "$repo")" || fail "the commit does not say awaiting_evidence"
grep -Fqx -- "- pending at post_merge: main verifies (the run on main)" <<<"$(message "$repo")" ||
  fail "the pending post_merge evidence is not in the commit message"
grep -Fqx 'Post-merge criterion: "main verifies"' <<<"$(message "$repo")" ||
  fail "the exact post-merge criterion line is not in the commit message"
if grep -Fqx "Completion: complete" <<<"$(message "$repo")"; then fail "a feature with pending evidence was committed as complete"; fi
grep -Fq "evidence of a later gate is pending (post_merge, pr_ci)" "$repo.out" || fail "the pending gates were not named"

# The owner's approval is not something a completion record can hold. A
# record that claims it as met is invalid, and a record that leaves it pending
# does not change whether the merge needs the owner: the gate decides from
# the diff and the review.
repo="$(setup_repo completion-owner-met PASS "[]")"
jq '.criteria[1] = {criterion: "The owner approves", gate: "owner_approval", status: "met", evidence: "the owner agreed in chat"}' \
  "$repo/.agents/completion/12.json" >"$repo/completion.tmp"
mv "$repo/completion.tmp" "$repo/.agents/completion/12.json"
expect_no_commit "$repo" "owner_approval claimed as met" 12 "Add the marker"
grep -Fq "owner_approval cannot be met in a record the implementer writes" "$repo.out" || fail "the claimed approval was not given as the reason"

repo="$(setup_repo completion-owner-pending PASS "[]")"
jq '.status = "awaiting_evidence" | .criteria[1] = {criterion: "The owner approves", gate: "owner_approval", status: "pending", evidence: "approval of the final commit"}' \
  "$repo/.agents/completion/12.json" >"$repo/completion.tmp"
mv "$repo/completion.tmp" "$repo/.agents/completion/12.json"
jq '.architecture_impact = {level: "major", rationale: "Because of the marker.", checked_against: ["ADR 001"]}' \
  "$repo/$review" >"$repo/$review.tmp" && mv "$repo/$review.tmp" "$repo/$review"
claims_changed "$repo"
run_finish "$repo" 12 "Add the marker" || { cat "$repo.out" >&2; fail "a feature that awaits the owner's approval was refused"; }
grep -Fqx -- "- required from the project owner, for exactly this commit" <<<"$(message "$repo" | sed -n '/^Merge approval:$/,/^$/p')" ||
  fail "a record that leaves owner_approval pending changed whether the merge needs the owner"
grep -Fq "no script or agent may merge it" "$repo.out" || fail "the needed approval was not announced for a feature that awaits it"
grep -Fqx -- "- pending at owner_approval: The owner approves (approval of the final commit)" <<<"$(message "$repo")" ||
  fail "the pending approval is not shown as pending in the commit"
if grep -Fq -- "- met: The owner approves" <<<"$(message "$repo")"; then fail "the commit states the owner's approval as met"; fi

# --partial takes the commit statement from the record, so a record that
# awaits evidence, contradicted by the handoff note, is not committed as
# partial either: it would carry no remaining work.
repo="$(setup_repo completion-awaiting-contradicted PASS "[]")"
jq '.status = "awaiting_evidence" | .criteria[1] = {criterion: "CI", gate: "pr_ci", status: "pending", evidence: "later"}' \
  "$repo/.agents/completion/12.json" >"$repo/completion.tmp"
mv "$repo/completion.tmp" "$repo/.agents/completion/12.json"
mkdir -p "$repo/.agents/handoffs"
printf '**Remaining:** steps 3 to 9.\n' >"$repo/.agents/handoffs/12.md"
expect_no_commit "$repo" "--partial with an awaiting_evidence record against the handoff note" 12 "Add the marker" --partial
grep -Fq "the completion record says awaiting_evidence, so the work cannot be committed as partial" "$repo.out" ||
  fail "the contradicted awaiting record was not given as the reason with --partial"
grep -Fq "remaining: steps 3 to 9." "$repo.out" || fail "what the handoff note lists was not shown for the awaiting record"
set_completion "$repo" partial
claims_changed "$repo"
run_finish "$repo" 12 "Add the first part of the marker" --partial || fail "partial work with a corrected record was refused"
grep -Fqx "Completion: partial" <<<"$(message "$repo")" || fail "the corrected record was not committed as partial"

# The end of the finish names the script that closes an Issue which awaits
# post_merge evidence; for other pending evidence it says nothing of it.
repo="$(setup_repo completion-awaiting-hint PASS "[]")"
jq '.status = "awaiting_evidence" | .criteria[1] = {criterion: "main verifies", gate: "post_merge", status: "pending", evidence: "the run on main"}' \
  "$repo/.agents/completion/12.json" >"$repo/completion.tmp"
mv "$repo/completion.tmp" "$repo/.agents/completion/12.json"
claims_changed "$repo"
run_finish "$repo" 12 "Add the marker" || fail "finishing a feature that awaits post_merge evidence failed"
grep -Fq "./scripts/record-post-merge.sh 12" "$repo.out" || fail "the end of the finish does not name record-post-merge.sh"
repo="$(setup_repo completion-awaiting-no-hint PASS "[]")"
jq '.status = "awaiting_evidence" | .criteria[1] = {criterion: "CI", gate: "pr_ci", status: "pending", evidence: "later"}' \
  "$repo/.agents/completion/12.json" >"$repo/completion.tmp"
mv "$repo/completion.tmp" "$repo/.agents/completion/12.json"
claims_changed "$repo"
run_finish "$repo" 12 "Add the marker" || fail "finishing a feature that awaits pr_ci evidence failed"
if grep -Fq "record-post-merge.sh" "$repo.out"; then fail "the end of the finish names record-post-merge.sh without post_merge evidence"; fi

# Pending evidence does not hide an implementation criterion that is not met,
# and --partial is for work that is incomplete, not for work that awaits.
repo="$(setup_repo completion-awaiting-hidden PASS "[]")"
jq '.status = "awaiting_evidence"
  | .criteria[1] = {criterion: "The marker is documented", status: "not_met", evidence: "docs/marker.md"}
  | .criteria += [{criterion: "main verifies", gate: "post_merge", status: "pending", evidence: "the run on main"}]' \
  "$repo/.agents/completion/12.json" >"$repo/completion.tmp"
mv "$repo/completion.tmp" "$repo/.agents/completion/12.json"
expect_no_commit "$repo" "an awaiting_evidence record with a criterion that is not met" 12 "Add the marker"
grep -Fq "status is awaiting_evidence, but a criterion is not met" "$repo.out" || fail "the hidden unmet criterion was not given as the reason"
repo="$(setup_repo completion-awaiting-partial PASS "[]")"
jq '.status = "awaiting_evidence" | .criteria[1] = {criterion: "CI", gate: "pr_ci", status: "pending", evidence: "later"}' \
  "$repo/.agents/completion/12.json" >"$repo/completion.tmp"
mv "$repo/completion.tmp" "$repo/.agents/completion/12.json"
expect_no_commit "$repo" "--partial for a feature that awaits evidence" 12 "Add the marker" --partial
grep -Fq "the feature is awaiting_evidence" "$repo.out" || fail "--partial for an awaiting feature was not explained"

repo="$(setup_repo completion-partial-refused PASS "[]")"
expect_no_commit "$repo" "--partial for a complete feature" 12 "Add the marker" --partial
grep -Fq "the feature is complete" "$repo.out" || fail "--partial for a complete feature was not explained"

repo="$(setup_repo completion-not-ignored PASS "[]")"
grep -v '^\.agents/completion/$' "$repo/.gitignore" >"$tmp/gitignore" && cp "$tmp/gitignore" "$repo/.gitignore"
record_reviewed_tree "$repo" "$repo/$review"
if run_finish "$repo" 12 "Add the marker"; then fail "a completion record that is not ignored was accepted"; fi
grep -Fq ".agents/completion/" "$repo.out" || fail "the missing ignore rule for the completion record was not named"

# The option may stand anywhere, and the checks before the commit still apply.
repo="$(setup_repo unattended-no-review PASS "[]")"
rm "$repo/$review"
mkdir -p "$repo/.agents/summaries"
printf -- '- Fixes a typo.\n' >"$repo/.agents/summaries/12.md"
EDITOR_COMMAND=false run_finish "$repo" --unattended 12 "Fix a typo" --no-review "documentation typo" ||
  fail "finishing unattended without a review failed"
[[ "$(changes_of "$repo")" == "Changes:
- Fixes a typo." ]] || fail "the unattended commit does not list the summarized changes"

# A summary that Git does not ignore would be committed with the feature.
repo="$(setup_repo summary-not-ignored PASS "[]")"
grep -v '^\.agents/summaries/$' "$repo/.gitignore" >"$tmp/gitignore" && cp "$tmp/gitignore" "$repo/.gitignore"
mkdir -p "$repo/.agents/summaries"
printf -- '- Adds the marker.\n' >"$repo/.agents/summaries/12.md"
record_reviewed_tree "$repo" "$repo/$review"
if run_finish "$repo" 12 "Add the marker"; then fail "a summary that is not ignored was accepted"; fi
grep -Fq ".agents/summaries/" "$repo.out" || fail "the missing ignore rule for the summary was not named"

repo="$(setup_repo unattended-major CHANGES_REQUIRED "$major")"
expect_no_commit "$repo" "the review has a major finding, unattended" 12 "Add the marker" --unattended

# With an editor, a failing editor creates no commit.
repo="$(setup_repo editor-fails PASS "[]")"
EDITOR_COMMAND=false expect_no_commit "$repo" "the editor failed" 12 "Add the marker"

# In a project with an approved planning, a feature may update the
# architecture and the ADRs, but not the roadmap or the requirements.
setup_planned() {
  local repo

  repo="$(setup_repo "$1" PASS "[]")"
  git -C "$repo" stash -q --include-untracked
  git -C "$repo" switch -q main
  mkdir -p "$repo/docs/decisions"
  printf '# Roadmap\n' >"$repo/docs/roadmap.md"
  printf '# Requirements\n' >"$repo/docs/PROJECT_REQUIREMENTS.md"
  printf '# Architecture\n' >"$repo/docs/architecture.md"
  printf '# Planning Approval\n\nStatus: Approved\n' >"$repo/docs/PLANNING_APPROVAL.md"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "Approved planning"
  git -C "$repo" switch -q feature/12-marker
  git -C "$repo" rebase -q main
  git -C "$repo" stash pop -q >/dev/null
  # The feature left its base elsewhere now; the review compared it there.
  jq --arg merge_base "$(git -C "$repo" rev-parse main)" '.merge_base = $merge_base' "$repo/$review" >"$repo/$review.tmp" &&
    mv "$repo/$review.tmp" "$repo/$review"
  printf '%s\n' "$repo"
}

repo="$(setup_planned architecture-update)"
printf '\nThe marker is a file.\n' >>"$repo/docs/architecture.md"
printf '# ADR 001: Marker\n' >"$repo/docs/decisions/001-marker.md"
record_reviewed_tree "$repo" "$repo/$review"
run_finish "$repo" 12 "Add the marker" || {
  cat "$repo.out" >&2
  fail "a feature that updates the architecture and an ADR was refused"
}
[[ "$(git -C "$repo" rev-list --count main..HEAD)" -eq 1 ]] || fail "the feature with an architecture update was not committed"

for document in docs/roadmap.md docs/PROJECT_REQUIREMENTS.md docs/changes/later.md; do
  repo="$(setup_planned "changes-$(basename "$document" .md)")"
  mkdir -p "$repo/docs/changes"
  printf '\nChanged by a feature.\n' >>"$repo/$document"
  record_reviewed_tree "$repo" "$repo/$review"
  if run_finish "$repo" 12 "Add the marker"; then fail "a feature that changes $document was committed"; fi
  [[ "$(git -C "$repo" rev-list --count main..HEAD)" -eq 0 ]] || fail "a commit was created although the feature changes $document"
  grep -Fq "$document" "$repo.out" || fail "the changed planning document was not named: $document"
  grep -Fq "start-planning.sh <name> --change <file>" "$repo.out" || fail "the change cycle was not named"
done

# The guard cannot be passed by removing or changing the approval itself.
repo="$(setup_planned removes-approval)"
git -C "$repo" rm -q docs/PLANNING_APPROVAL.md
printf '\nChanged by a feature.\n' >>"$repo/docs/roadmap.md"
record_reviewed_tree "$repo" "$repo/$review"
if run_finish "$repo" 12 "Add the marker"; then fail "a feature that removes the approval and changes the roadmap was committed"; fi
grep -Fq "docs/PLANNING_APPROVAL.md" "$repo.out" || fail "the removed approval was not named"
grep -Fq "docs/roadmap.md" "$repo.out" || fail "the changed roadmap was not named after the approval was removed"

repo="$(setup_planned edits-approval)"
printf '\nA note by a feature.\n' >>"$repo/docs/PLANNING_APPROVAL.md"
record_reviewed_tree "$repo" "$repo/$review"
if run_finish "$repo" 12 "Add the marker"; then fail "a feature that edits the approval was committed"; fi

# Without a base to compare with, a planned project is not committed blind.
repo="$(setup_planned no-base)"
git -C "$repo" branch -q -m main trunk
if run_finish "$repo" 12 "Add the marker"; then fail "a feature without a known base was committed in a planned project"; fi
grep -Fq "could not determine the base" "$repo.out" || fail "the unknown base was not reported"

# The merge approval gate. The commit message says whether the owner must
# approve the merge, and why: the heaviest of the rules checked on the diff
# and the reviewer's classification decides.
approval_of() {
  message "$1" | sed -n '/^Merge approval:$/,/^$/p'
}

set_impact() {
  jq --arg level "$2" '.architecture_impact = {level: $level, rationale: "Because of the marker.", checked_against: ["ADR 001"]}' \
    "$1/$review" >"$1/$review.tmp" && mv "$1/$review.tmp" "$1/$review"
}

repo="$(setup_repo gate-minor PASS "[]")"
set_impact "$repo" minor
run_finish "$repo" 12 "Add the marker" || fail "finishing a feature with a minor impact failed"
grep -Fqx -- "- not required" <<<"$(approval_of "$repo")" || fail "a minor impact without a protected path needed approval"
grep -Fqx -- "- decided for the reviewed content $(jq -r '.reviewed_tree' "$repo/$review")" <<<"$(approval_of "$repo")" ||
  fail "the decision does not name the reviewed content it was made for"

for level in major breaking; do
  repo="$(setup_repo "gate-$level" PASS "[]")"
  set_impact "$repo" "$level"
  run_finish "$repo" 12 "Add the marker" || fail "finishing a feature with a $level impact failed"
  grep -Fqx -- "- required from the project owner, for exactly this commit" <<<"$(approval_of "$repo")" ||
    fail "a $level impact did not need the owner's approval"
  grep -Fq "classified the impact on the architecture as $level: Because of the marker." <<<"$(approval_of "$repo")" ||
    fail "the reason of the reviewer was not recorded for a $level impact"
  grep -Fq "no script or agent may merge it" "$repo.out" || fail "the needed approval was not announced"
done

# The rules on the diff outweigh a reviewer who calls the change minor.
repo="$(setup_repo gate-adr PASS "[]")"
set_impact "$repo" minor
mkdir -p "$repo/docs/decisions"
printf '# ADR 002: Another marker\n\nStatus: Proposed\n' >"$repo/docs/decisions/002-marker.md"
record_reviewed_tree "$repo" "$repo/$review"
run_finish "$repo" 12 "Add the marker" || fail "finishing a feature with a new ADR failed"
grep -Fqx -- "- required from the project owner, for exactly this commit" <<<"$(approval_of "$repo")" ||
  fail "a new ADR did not need the owner's approval although the reviewer said minor"
grep -Fq "docs/decisions/002-marker.md: an ADR is added, changed, or removed" <<<"$(approval_of "$repo")" ||
  fail "the added ADR was not given as the reason"

# No classification gives no permission: a review without one, an invalid
# one, and a feature without a review.
repo="$(setup_repo gate-unclassified PASS "[]")"
run_finish "$repo" 12 "Add the marker" || fail "finishing a feature with an unclassified review failed"
grep -Fq "no valid classification of the impact" <<<"$(approval_of "$repo")" || fail "a review without a classification gave permission"

repo="$(setup_repo gate-invalid PASS "[]")"
jq '.architecture_impact = {level: "harmless"}' "$repo/$review" >"$repo/$review.tmp" && mv "$repo/$review.tmp" "$repo/$review"
if run_finish "$repo" 12 "Add the marker"; then
  grep -Fq "no valid classification of the impact" <<<"$(approval_of "$repo")" || fail "an invalid classification gave permission"
fi

repo="$(setup_repo gate-no-review PASS "[]")"
rm "$repo/$review"
run_finish "$repo" 12 "Fix a typo" --no-review "documentation typo" || fail "finishing without a review failed"
grep -Fqx -- "- required from the project owner, for exactly this commit" <<<"$(approval_of "$repo")" ||
  fail "a feature without a review did not need the owner's approval"

# The risk level. Computed from the diff by the rules of the base and
# recorded in the commit message with its reasons; the implementer's record
# can raise it, never lower it, and the reviewer's classification raises it.
risk_of() {
  message "$1" | sed -n '/^Risk: /,/^$/p'
}

set_risk_claim() {
  jq --arg risk "$2" '.risk = $risk' "$1/.agents/completion/12.json" >"$1/.agents/completion/12.json.tmp" &&
    mv "$1/.agents/completion/12.json.tmp" "$1/.agents/completion/12.json"
}

repo="$(setup_repo risk-default PASS "[]")"
set_impact "$repo" minor
run_finish "$repo" 12 "Add the marker" || fail "finishing a feature of today's shape failed"
grep -Fqx "Risk: medium" <<<"$(risk_of "$repo")" || fail "a feature without a project policy is not recorded as medium"
grep -Fq -- "- feature.txt: " <<<"$(risk_of "$repo")" || fail "the reason for the level was not recorded"

repo="$(setup_repo risk-lowered PASS "[]")"
set_impact "$repo" minor
set_risk_claim "$repo" low
expect_no_commit "$repo" "the completion record claims a lower level than computed" 12 "Add the marker"
grep -Fq "claims risk: low, but the feature is medium" "$repo.out" || fail "the refused claim was not explained with the computed level"
grep -Fq -- "- feature.txt: " "$repo.out" || fail "the refusal does not give the reasons for the computed level"

repo="$(setup_repo risk-raised PASS "[]")"
set_impact "$repo" minor
set_risk_claim "$repo" high
claims_changed "$repo"
run_finish "$repo" 12 "Add the marker" || fail "finishing a feature whose record raises the level failed"
grep -Fqx "Risk: high" <<<"$(risk_of "$repo")" || fail "the record did not raise the level"
grep -Fq "recorded risk: high in the completion record" <<<"$(risk_of "$repo")" || fail "the raised level does not name the record as the reason"

repo="$(setup_repo risk-review PASS "[]")"
set_impact "$repo" major
run_finish "$repo" 12 "Add the marker" || fail "finishing a feature with a major impact failed"
grep -Fqx "Risk: high" <<<"$(risk_of "$repo")" || fail "a major impact did not raise the level to high"
grep -Fq "classified the impact on the architecture as major" <<<"$(risk_of "$repo")" || fail "the review is not named as the reason for high"

# A high-risk path stays high whatever the record claims.
repo="$(setup_repo risk-protected PASS "[]")"
set_impact "$repo" minor
set_risk_claim "$repo" low
printf '\n# changed\n' >>"$repo/scripts/publish-feature.sh"
record_reviewed_tree "$repo" "$repo/$review"
expect_no_commit "$repo" "the record claims low for a change to a file of the gate" 12 "Add the marker"
grep -Fq "but the feature is high" "$repo.out" || fail "the computed level high was not reported"

# A feature that was already in progress when the level came into the
# workflow is not refused: its completion record has no 'risk', as no record
# written before had one, so there is no claim to refuse; the level is
# derived and recorded all the same.
repo="$(setup_repo risk-earlier-record PASS "[]")"
set_impact "$repo" minor
jq 'del(.risk)' "$repo/.agents/completion/12.json" >"$repo/.agents/completion/12.json.tmp" &&
  mv "$repo/.agents/completion/12.json.tmp" "$repo/.agents/completion/12.json"
printf '\n# changed\n' >>"$repo/scripts/publish-feature.sh"
record_reviewed_tree "$repo" "$repo/$review"
run_finish "$repo" 12 "Add the marker" || {
  cat "$repo.out" >&2
  fail "a high-risk feature whose record predates the risk level was refused"
}
grep -Fqx "Risk: high" <<<"$(risk_of "$repo")" || fail "the level of a feature with an earlier record was not derived and recorded"
grep -Fq -- "- scripts/publish-feature.sh: " <<<"$(risk_of "$repo")" || fail "the reason for the derived level was not recorded"

# A review made on a partial check (review-feature.sh --checks) is an
# intermediate round: a feature is committed on a review of content that
# passed the full verification, whatever the risk policy allows for the
# intermediate rounds.
repo="$(setup_repo partial-check PASS "[]")"
set_impact "$repo" minor
jq '.verification = {status: "partial", groups: ["fast"], verified_at: "2026-01-01T00:00:00Z"}' "$repo/$review" >"$repo/$review.tmp" &&
  mv "$repo/$review.tmp" "$repo/$review"
expect_no_commit "$repo" "the latest review was made on a partial check" 12 "Add the marker"
grep -Fq "was made on partially checked content: only the groups fast" "$repo.out" || fail "the partial check was not given as the reason"
grep -Fq "without --checks" "$repo.out" || fail "the refusal does not say how to review again"

# The review compared the feature against its base: one whose merge base is
# not the one the feature has now judged another diff.
repo="$(setup_repo other-base PASS "[]")"
set_impact "$repo" minor
jq '.merge_base = "0123456789012345678901234567890123456789"' "$repo/$review" >"$repo/$review.tmp" &&
  mv "$repo/$review.tmp" "$repo/$review"
expect_no_commit "$repo" "the review names another merge base" 12 "Add the marker"
grep -Fq "the base of the branch changed since the review" "$repo.out" || fail "the other merge base was not given as the reason"

# Without a review, a feature is committed only when it is low risk and the
# risk policy of the base says 'low: review: none'; the commit says so, and
# the merge needs the owner, as for any feature without a classification of
# the impact. 'review: none' is refused for medium and high.
# policy_on_base <repo> <policy>: the risk policy, committed on main.
policy_on_base() {
  mkdir -p "$1/.agents/policies"
  git -C "$1" switch -q main
  printf '%s\n' "$2" >"$1/.agents/policies/risk.conf"
  git -C "$1" add .agents/policies/risk.conf
  git -C "$1" commit -qm "The risk policy"
  git -C "$1" switch -q feature/12-marker
  git -C "$1" rebase -q main
}
# without_review <repo>: the fixture review is removed.
without_review() {
  rm -f "${1:?}/${review:?}"
}
# expect_no_feature_commit <repo> <description> <argument...>: as
# expect_no_commit, for a feature whose base got a commit of its own.
expect_no_feature_commit() {
  local repo="$1"
  local description="$2"
  shift 2

  if run_finish "$repo" "$@"; then
    cat "$repo.out" >&2
    fail "expected refusal: $description"
  fi
  [[ "$(git -C "$repo" rev-list --count main..HEAD)" -eq 0 ]] || fail "a commit was created although: $description"
}
repo="$(setup_repo low-unreviewed PASS "[]")"
without_review "$repo"
policy_on_base "$repo" "$(printf 'default: medium\nlow: feature.txt\nlow: review: none')"
run_finish "$repo" 12 "Add the marker" || {
  cat "$repo.out" >&2
  fail "a low-risk feature was refused without a review although the policy says 'low: review: none'"
}
grep -Fqx "Review: not reviewed: Low risk by project policy (.agents/policies/risk.conf of the base: low: review: none)" <<<"$(message "$repo")" ||
  fail "the commit does not say that the feature was not reviewed by project policy"
grep -Fqx "Risk: low" <<<"$(risk_of "$repo")" || fail "the commit does not record the low level"
grep -Fqx -- "- required from the project owner, for exactly this commit" <<<"$(approval_of "$repo")" ||
  fail "an unreviewed low-risk feature did not need the owner's approval"
grep -Fq "no valid classification of the impact" <<<"$(approval_of "$repo")" || fail "the missing classification is not the reason for the approval"
# The same feature with a review is committed on the review, as before.
repo="$(setup_repo low-reviewed PASS "[]")"
set_impact "$repo" minor
policy_on_base "$repo" "$(printf 'default: medium\nlow: feature.txt\nlow: review: none')"
jq --arg merge_base "$(git -C "$repo" rev-parse main)" '.merge_base = $merge_base' "$repo/$review" >"$repo/$review.tmp" &&
  mv "$repo/$review.tmp" "$repo/$review"
claims_changed "$repo"
run_finish "$repo" 12 "Add the marker" || { cat "$repo.out" >&2; fail "a reviewed low-risk feature was refused"; }
grep -Fqx "Review: round 1, PASS, by claude (model-r)" <<<"$(message "$repo")" || fail "the review of a low-risk feature was not used"
# Without 'low: review: none' a low-risk feature needs its review.
repo="$(setup_repo low-policy-reviews PASS "[]")"
without_review "$repo"
policy_on_base "$repo" "$(printf 'default: medium\nlow: feature.txt')"
expect_no_feature_commit "$repo" "a low-risk feature without a review, in a project that reviews low" 12 "Add the marker"
grep -Fq "no review of this feature exists, and it is low risk" "$repo.out" || fail "the missing review of a low-risk feature was not given as the reason"
grep -Fq "low: review: none" "$repo.out" || fail "the refusal does not name the policy line that would allow it"
# A medium feature is never committed without a review: not by the shipped
# policy, and not by a policy that says 'medium: review: none', which is
# refused and reported.
repo="$(setup_repo medium-unreviewed PASS "[]")"
without_review "$repo"
expect_no_commit "$repo" "a medium-risk feature without a review" 12 "Add the marker"
grep -Fq "no review of this feature exists, and it is medium risk" "$repo.out" || fail "the missing review of a medium-risk feature was not given as the reason"
repo="$(setup_repo medium-none-refused PASS "[]")"
without_review "$repo"
policy_on_base "$repo" "$(printf 'default: medium\nmedium: review: none\nlow: review: none')"
expect_no_feature_commit "$repo" "'medium: review: none' is configured" 12 "Add the marker"
grep -Fq "medium: review: none is refused" "$repo.out" || fail "the refused 'medium: review: none' was not reported"
repo="$(setup_repo high-none-refused PASS "[]")"
without_review "$repo"
policy_on_base "$repo" "$(printf 'default: medium\nhigh: scripts\nhigh: review: none\nlow: review: none')"
printf '\n# changed\n' >>"$repo/scripts/publish-feature.sh"
expect_no_feature_commit "$repo" "'high: review: none' is configured" 12 "Add the marker"
grep -Fq "no review of this feature exists, and it is high risk" "$repo.out" || fail "the missing review of a high-risk feature was not given as the reason"
grep -Fq "high: review: none is refused" "$repo.out" || fail "the refused 'high: review: none' was not reported"
# A record that claims low does not make a medium feature unreviewed.
repo="$(setup_repo low-claimed PASS "[]")"
without_review "$repo"
policy_on_base "$repo" "$(printf 'default: medium\nlow: docs\nlow: review: none')"
jq '.risk = "low"' "$repo/.agents/completion/12.json" >"$repo/completion.tmp" && mv "$repo/completion.tmp" "$repo/.agents/completion/12.json"
expect_no_feature_commit "$repo" "a medium-risk feature whose record claims low, without a review" 12 "Add the marker"
grep -Fq "claims risk: low, but the feature is medium" "$repo.out" || fail "the claim of low was not refused"

# The triage mode. A light triage of a medium-risk feature, by 'medium:
# triage: light' on the base, is committed on like any published triage,
# and the commit message does not change. A light triage of a feature that
# is high when it is committed is refused, whatever the policy says, and so
# is an artifact with a mode that does not exist; 'high: triage: light' is
# reported as refused, and the full triage of the same round is accepted.
# set_triage_mode <repo> <mode>
set_triage_mode() {
  jq --arg mode "$2" '.triage.mode = $mode' "$1/$triage" >"$1/triage.tmp" && mv "$1/triage.tmp" "$1/$triage"
}
# policy_for_triage <repo> <policy>: the policy on the base, with the
# fixture review and its triage made current for the moved base.
policy_for_triage() {
  policy_on_base "$1" "$2"
  jq --arg merge_base "$(git -C "$1" rev-parse main)" '.merge_base = $merge_base' "$1/$review" >"$1/$review.tmp" &&
    mv "$1/$review.tmp" "$1/$review"
  claims_changed "$1"
}
repo="$(setup_repo light-medium PASS_WITH_MINOR_FINDINGS "$minor")"
set_impact "$repo" minor
add_triage "$repo" ACCEPT
set_triage_mode "$repo" light
policy_for_triage "$repo" "$(printf 'default: medium\nmedium: triage: light')"
run_finish "$repo" 12 "Add the marker" || {
  cat "$repo.out" >&2
  fail "finishing on a light triage of a medium-risk feature failed"
}
grep -Fq "Triage mode: light (" "$repo.out" || fail "the triage mode of the policy was not shown"
grep -Fq "triage published on #12" <<<"$(message "$repo")" || fail "the commit message does not mention the light triage as published"
if message "$repo" | grep -Fq "Triage mode"; then fail "the commit message carries the triage mode"; fi
repo="$(setup_repo light-high-refused PASS_WITH_MINOR_FINDINGS "$minor")"
set_impact "$repo" minor
add_triage "$repo" ACCEPT
set_triage_mode "$repo" light
printf 'hot\n' >"$repo/hot.txt"
policy_for_triage "$repo" "$(printf 'default: medium\nhigh: hot.txt\nhigh: triage: light')"
expect_no_feature_commit "$repo" "a light triage of a high-risk feature" 12 "Add the marker"
grep -Fq "is a light triage, but the feature is high risk" "$repo.out" || fail "the light triage of a high-risk feature was not given as the reason"
grep -Fq "triage-review.sh" "$repo.out" || fail "the refusal does not say how to triage again"
set_triage_mode "$repo" full
claims_changed "$repo"
run_finish "$repo" 12 "Add the marker" || {
  cat "$repo.out" >&2
  fail "finishing on the full triage of a high-risk feature failed"
}
grep -Fq "Triage mode: full (high: triage: light is refused" "$repo.out" || fail "the refused 'high: triage: light' was not reported"
grep -Fqx "Risk: high" <<<"$(risk_of "$repo")" || fail "the commit does not record the high level"
repo="$(setup_repo mode-invalid PASS_WITH_MINOR_FINDINGS "$minor")"
add_triage "$repo" ACCEPT
set_triage_mode "$repo" maybe
claims_changed "$repo"
expect_no_commit "$repo" "the triage records a mode that does not exist" 12 "Add the marker"
grep -Fq "triage.mode must be full or light" "$repo.out" || fail "the invalid mode was not given as the reason"

# An emptied commit message creates no commit.
repo="$(setup_repo abort PASS "[]")"
EDITOR_COMMAND='sh -c ": > \"\$0\""' expect_no_commit "$repo" "the commit message was emptied" 12 "Add the marker"

# Refusals.
repo="$(setup_repo wrong-branch PASS "[]")"
git -C "$repo" switch -q -c feature/13-other
expect_no_commit "$repo" "the branch belongs to another Issue" 12 "Add the marker"

repo="$(setup_repo nothing PASS "[]")"
rm "$repo/feature.txt"
expect_no_commit "$repo" "there are no changes" 12 "Add the marker"

repo="$(setup_repo verification-fails PASS "[]")"
printf 'broken: false\n' >"$repo/scripts/verify.conf"
record_reviewed_tree "$repo" "$repo/$review"
expect_no_commit "$repo" "verification fails" 12 "Add the marker"

repo="$(setup_repo no-review-file PASS "[]")"
rm "$repo/$review"
expect_no_commit "$repo" "there is no review" 12 "Add the marker"

repo="$(setup_repo stale PASS "[]")"
printf 'more work\n' >>"$repo/feature.txt"
expect_no_commit "$repo" "the review is stale" 12 "Add the marker"

repo="$(setup_repo major CHANGES_REQUIRED "$major")"
expect_no_commit "$repo" "the review has a major finding" 12 "Add the marker"

repo="$(setup_repo untriaged PASS_WITH_MINOR_FINDINGS "$minor")"
expect_no_commit "$repo" "the findings are not triaged" 12 "Add the marker"

repo="$(setup_repo unpublished PASS_WITH_MINOR_FINDINGS "$minor")"
add_triage "$repo" ACCEPT no
expect_no_commit "$repo" "the triage was not published" 12 "Add the marker"
grep -Fq -- "--publish" "$repo.out" || fail "an unpublished triage did not point to --publish"

repo="$(setup_repo fix-pending PASS_WITH_MINOR_FINDINGS "$minor")"
add_triage "$repo" FIX_NOW
expect_no_commit "$repo" "FIX_NOW findings are not applied" 12 "Add the marker"

repo="$(setup_repo empty-reason PASS "[]")"
expect_no_commit "$repo" "--no-review has no reason" 12 "Add the marker" --no-review " "

# An Issue that asks for the owner's approval in its own criteria makes the
# merge need the owner, also when no protected path changed and the review
# calls the change minor: the record can require approval, never grant it.
repo="$(setup_repo completion-owner-pending-only PASS "[]")"
set_impact "$repo" minor
jq '.status = "awaiting_evidence" | .criteria[1] = {criterion: "The owner approves", gate: "owner_approval", status: "pending", evidence: "approval of the final commit"}' \
  "$repo/.agents/completion/12.json" >"$repo/completion.tmp"
mv "$repo/completion.tmp" "$repo/.agents/completion/12.json"
claims_changed "$repo"
run_finish "$repo" 12 "Add the marker" || { cat "$repo.out" >&2; fail "a feature that awaits the owner's approval was refused"; }
grep -Fqx -- "- required from the project owner, for exactly this commit" <<<"$(approval_of "$repo")" ||
  fail "a pending owner_approval criterion did not make the merge need the owner"
grep -Fqx -- "- the completion record leaves a criterion of the owner_approval gate pending: The owner approves" <<<"$(approval_of "$repo")" ||
  fail "the reason of the requirement is not in the commit"
if grep -Fqx -- "- not required" <<<"$(approval_of "$repo")"; then fail "the commit says both required and not required"; fi
grep -Fq "no script or agent may merge it" "$repo.out" || fail "the needed approval was not announced"

# The deadlock of fixing before the triage: round 1 had a finding that was
# fixed, round 2 is a current review, and round 1 is still untriaged. It is
# triaged as a historical review, and then the feature can be committed. A
# historical triage does not excuse a stale latest review.
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "auth status") exit 0 ;;
  "issue view") printf 'Title: Marker\n\nBody.'; exit 0 ;;
  "issue comment") exit 0 ;;
  "api repos/"*"/comments") exec "$(dirname "$0")/gh-comments" "$@" ;;
esac
echo "Unexpected gh invocation: $*" >&2
exit 1
GH
chmod +x "$tmp/bin/gh"
historical_decisions='{"decisions": [{"finding_id": "M1", "decision": "FIX_NOW", "rationale": "Blocks the feature.", "followup": null}]}'
run_triage() {
  (
    cd "$1"
    printf 'y\n' | PATH="$tmp/bin:/usr/bin:/bin" MOCK_AGENT_LOG="$1.agent" MOCK_OUTPUT="$historical_decisions" \
      ./scripts/triage-review.sh "$2"
  ) >"$1.triage.out" 2>&1
}

printf 'triage: claude model-t\n' >"$tmp/agents.conf"
repo="$(setup_repo deadlock CHANGES_REQUIRED "$major")"
git -C "$repo" switch -q feature/12-marker
printf 'fixed before the triage\n' >>"$repo/feature.txt"
cp "$tmp/agents.conf" "$repo/.agents/agents.conf"
add_second_round "$repo"
expect_no_commit "$repo" "round 1 is not triaged" 12 "Add the marker"
grep -Fq "triaged as a historical review" "$repo.out" || fail "the refusal does not name the historical triage"
run_triage "$repo" "$review" || {
  cat "$repo.triage.out" >&2
  fail "the historical triage of round 1 failed"
}
[[ "$(jq -r '.historical' "$repo/$triage")" == "true" ]] || fail "the triage was not recorded as historical"
if grep -Fq "apply-triage.sh" "$repo.triage.out"; then fail "a historical triage points to apply-triage.sh, which refuses a stale review"; fi
grep -Fq "finish-feature.sh" "$repo.triage.out" || fail "a historical triage does not name the next step"
run_finish "$repo" 12 "Add the marker" || {
  cat "$repo.out" >&2
  fail "a feature with a historical triage of an earlier round was refused"
}
grep -Fq "Review: round 2, PASS" <<<"$(message "$repo")" || fail "the commit does not name the latest round"

repo="$(setup_repo historical-latest-stale CHANGES_REQUIRED "$major")"
printf 'fixed before the triage\n' >>"$repo/feature.txt"
cp "$tmp/agents.conf" "$repo/.agents/agents.conf"
add_second_round "$repo"
run_triage "$repo" "$review" || {
  cat "$repo.triage.out" >&2
  fail "the historical triage failed"
}
printf 'changed after the latest review\n' >>"$repo/feature.txt"
expect_no_commit "$repo" "all earlier rounds are triaged but the latest review is stale" 12 "Add the marker"
grep -Fq "is stale" "$repo.out" || fail "a stale latest review was not reported"


# Agent attribution. With 'disabled', a commit of the feature that names an
# agent as a co-author is refused before anything is committed, and a commit
# whose message was given attribution in the editor is undone. A human
# co-author passes, the base is not checked, and 'allowed' or no setting
# commits as before.
set_attribution() {
  printf 'agent-attribution: %s\n' "$2" >"$1/.agents/attribution.conf"
  git -C "$1" add .agents/attribution.conf
}

repo="$(setup_repo attribution-trailer PASS "[]")"
set_attribution "$repo" disabled
git -C "$repo" commit -qm "Earlier work" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -m "Co-authored-by: Jane Doe <jane@example.com>"
record_reviewed_tree "$repo" "$repo/$review"
if run_finish "$repo" 12 "Add the marker"; then fail "a feature commit with an agent trailer was committed although attribution is disabled"; fi
[[ "$(git -C "$repo" rev-list --count HEAD)" -eq 2 ]] || fail "a commit was created on top of an attributed one"
grep -Fq "names an agent as a co-author" "$repo.out" || fail "the agent trailer was not reported"
grep -Fq "Earlier work" "$repo.out" || fail "the attributed commit was not named"
if grep -Fq "jane@example.com" "$repo.out"; then fail "the human co-author was reported"; fi

repo="$(setup_repo attribution-human PASS "[]")"
git -C "$repo" switch -q main
printf 'base\n' >"$repo/base.txt"
git -C "$repo" add base.txt
git -C "$repo" commit -qm "On the base" -m "Co-authored-by: Claude <noreply@anthropic.com>"
git -C "$repo" switch -q feature/12-marker
set_attribution "$repo" disabled
git -C "$repo" commit -qm "Earlier work" -m "Co-authored-by: Jane Doe <jane@example.com>"
record_reviewed_tree "$repo" "$repo/$review"
run_finish "$repo" 12 "Add the marker" || {
  cat "$repo.out" >&2
  fail "a human co-author, or the base's trailer, was refused"
}
[[ "$(git -C "$repo" rev-list --count main..HEAD)" -eq 2 ]] || fail "the feature was not committed next to a human co-author"

# Attribution added to the message in the editor undoes the commit and keeps
# the changes staged.
repo="$(setup_repo attribution-edited PASS "[]")"
set_attribution "$repo" disabled
record_reviewed_tree "$repo" "$repo/$review"
cat >"$tmp/add-trailer.sh" <<'EDITOR'
#!/usr/bin/env bash
printf '\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\n' >>"$1"
EDITOR
chmod +x "$tmp/add-trailer.sh"
if EDITOR_COMMAND="$tmp/add-trailer.sh" run_finish "$repo" 12 "Add the marker"; then
  fail "a message with an agent trailer added in the editor was committed"
fi
[[ "$(git -C "$repo" rev-list --count HEAD)" -eq 1 ]] || fail "the attributed commit was not undone"
grep -Fq "commit message carries it" "$repo.out" || fail "the attribution in the message was not reported"
git -C "$repo" diff --cached --quiet --exit-code -- feature.txt && fail "the changes are not staged after the undone commit"
run_finish "$repo" 12 "Add the marker" || {
  cat "$repo.out" >&2
  fail "finishing again after the undone commit failed"
}
[[ "$(git -C "$repo" rev-list --count HEAD)" -eq 2 ]] || fail "the feature was not committed after the undone commit"
if message "$repo" | grep -Fq "noreply@anthropic.com"; then fail "the second commit carries the trailer"; fi

# Generated attribution text in the message is refused as well: it would
# become the pull request description.
repo="$(setup_repo attribution-text PASS "[]")"
set_attribution "$repo" disabled
record_reviewed_tree "$repo" "$repo/$review"
mkdir -p "$repo/.agents/summaries"
printf -- '- The marker.\n- 🤖 Generated with [Claude Code](https://claude.com/claude-code)\n' >"$repo/.agents/summaries/12.md"
if run_finish "$repo" 12 "Add the marker"; then fail "a message with generated attribution text was committed"; fi
[[ "$(git -C "$repo" rev-list --count HEAD)" -eq 1 ]] || fail "the commit with generated attribution text was not undone"
grep -Fq "Generated with" "$repo.out" || fail "the generated text was not shown"

# Allowed, and no setting, commit an attributed feature as before.
for preference in allowed none; do
  repo="$(setup_repo "attribution-$preference" PASS "[]")"
  [[ "$preference" == "none" ]] || set_attribution "$repo" allowed
  printf 'earlier\n' >"$repo/earlier.txt"
  git -C "$repo" add earlier.txt
  git -C "$repo" commit -qm "Earlier work" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
  record_reviewed_tree "$repo" "$repo/$review"
  EDITOR_COMMAND="$tmp/add-trailer.sh" run_finish "$repo" 12 "Add the marker" || {
    cat "$repo.out" >&2
    fail "an attributed feature was refused although attribution is $preference"
  }
  [[ "$(git -C "$repo" rev-list --count HEAD)" -eq 3 ]] || fail "the attributed feature was not committed although attribution is $preference"
done

# A preference that cannot be read commits nothing.
repo="$(setup_repo attribution-invalid PASS "[]")"
set_attribution "$repo" maybe
record_reviewed_tree "$repo" "$repo/$review"
expect_no_commit "$repo" "the attribution preference cannot be read" 12 "Add the marker"
grep -Fq "unknown value 'maybe'" "$repo.out" || fail "the unreadable preference was not explained"

echo "finish-feature tests passed"
