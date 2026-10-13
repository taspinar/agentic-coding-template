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

  jq -n --arg verdict "$2" --argjson findings "$3" '{
    schema: "review/v1", kind: "feature", issue: 12, round: 1,
    branch: "feature/12-marker", base: "main", merge_base: "aaaa", head: "bbbb",
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
  message "$repo" | grep -Fqx "$line" || fail "the commit message lacks: $line"
done
git -C "$repo" show --name-only --format= HEAD | grep -Fqx "feature.txt" || fail "the feature change was not committed"
if git -C "$repo" show --name-only --format= HEAD | grep -Fq ".agents/reviews/"; then
  fail "a review file was committed"
fi
grep -Fq "./scripts/publish-feature.sh 12" "$repo.out" || fail "the next steps do not name publish-feature.sh"
message "$repo" | grep -A1 -Fx "Manual steps:" | grep -Fqx -- "- none" ||
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
if git -C "$repo" show --name-only --format= HEAD | grep -Fq "manual-steps"; then
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
message "$repo" | grep -Fqx "Review: round 3, PASS, by claude (model-r)" ||
  fail "the commit message does not name the review of the complete feature"

# Minor findings that were triaged without FIX_NOW and published are fine.
repo="$(setup_repo minor PASS_WITH_MINOR_FINDINGS "$minor")"
add_triage "$repo" DEFER
run_finish "$repo" 12 "Add the marker" || {
  cat "$repo.out" >&2
  fail "finishing with published, deferred minor findings failed"
}
message "$repo" | grep -Fq "triage published on #12" || fail "the commit message does not mention the published triage"

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
message "$repo" | grep -Fq "Review: round 2, PASS" || fail "the commit message does not name the final round"

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
message "$repo" | grep -Fqx "Review: no independent review (low risk: documentation typo)" ||
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
if git -C "$repo" show --name-only --format= HEAD | grep -Fq "summaries"; then
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
message "$repo" | grep -Fqx "Review: round 1, PASS, by claude (model-r)" || fail "the unattended commit lacks its review"

# The completion gate. A feature is committed as done only on a completion
# record of the implementer that says complete; the commit message carries
# the statement with the evidence per criterion.
repo="$(setup_repo completion-complete PASS "[]")"
run_finish "$repo" 12 "Add the marker" || fail "finishing a complete feature failed"
[[ "$(message "$repo" | sed -n '/^Completion: /,/^$/p')" == "Completion: complete
- met: The marker exists (feature.txt)
- met: The marker is documented (docs/marker.md)" ]] || fail "the commit message does not carry the completion statement"
if git -C "$repo" show --name-only --format= HEAD | grep -Fq "completion"; then
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
run_finish "$repo" 12 "Add the first part of the marker" --partial || fail "partial work with a corrected record was refused"
message "$repo" | grep -Fqx "Completion: partial" || fail "the corrected record was not committed as partial"
if message "$repo" | grep -Fqx "Completion: complete"; then fail "work with remaining steps was committed as complete"; fi

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
approval_of "$repo" | grep -Fqx -- "- not required" || fail "a minor impact without a protected path needed approval"
approval_of "$repo" | grep -Fqx -- "- decided for the reviewed content $(jq -r '.reviewed_tree' "$repo/$review")" ||
  fail "the decision does not name the reviewed content it was made for"

for level in major breaking; do
  repo="$(setup_repo "gate-$level" PASS "[]")"
  set_impact "$repo" "$level"
  run_finish "$repo" 12 "Add the marker" || fail "finishing a feature with a $level impact failed"
  approval_of "$repo" | grep -Fqx -- "- required from the project owner, for exactly this commit" ||
    fail "a $level impact did not need the owner's approval"
  approval_of "$repo" | grep -Fq "classified the impact on the architecture as $level: Because of the marker." ||
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
approval_of "$repo" | grep -Fqx -- "- required from the project owner, for exactly this commit" ||
  fail "a new ADR did not need the owner's approval although the reviewer said minor"
approval_of "$repo" | grep -Fq "docs/decisions/002-marker.md: an ADR is added, changed, or removed" ||
  fail "the added ADR was not given as the reason"

# No classification gives no permission: a review without one, an invalid
# one, and a feature without a review.
repo="$(setup_repo gate-unclassified PASS "[]")"
run_finish "$repo" 12 "Add the marker" || fail "finishing a feature with an unclassified review failed"
approval_of "$repo" | grep -Fq "no valid classification of the impact" || fail "a review without a classification gave permission"

repo="$(setup_repo gate-invalid PASS "[]")"
jq '.architecture_impact = {level: "harmless"}' "$repo/$review" >"$repo/$review.tmp" && mv "$repo/$review.tmp" "$repo/$review"
if run_finish "$repo" 12 "Add the marker"; then
  approval_of "$repo" | grep -Fq "no valid classification of the impact" || fail "an invalid classification gave permission"
fi

repo="$(setup_repo gate-no-review PASS "[]")"
rm "$repo/$review"
run_finish "$repo" 12 "Fix a typo" --no-review "documentation typo" || fail "finishing without a review failed"
approval_of "$repo" | grep -Fqx -- "- required from the project owner, for exactly this commit" ||
  fail "a feature without a review did not need the owner's approval"

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

echo "finish-feature tests passed"
