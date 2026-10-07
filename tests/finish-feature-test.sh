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

# Creates a feature repository with an uncommitted change and a current review.
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

# A latest review of changes only counts when it builds on the content that
# the round before it reviewed, back to a review of the complete feature.
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

repo="$(setup_repo changes-chain PASS "[]")"
second="$(add_changes_review "$repo")"
run_finish "$repo" 12 "Add the marker" || {
  cat "$repo.out" >&2
  fail "finishing after a review of changes only failed"
}
message "$repo" | grep -Fqx "Review: round 2 (changes since round 1 only), PASS, by claude (model-r)" ||
  fail "the commit message does not say that the last round reviewed changes only"

repo="$(setup_repo changes-broken PASS "[]")"
second="$(add_changes_review "$repo")"
jq '.scope.base_tree = "0123456789012345678901234567890123456789"' "$second" >"$second.tmp" && mv "$second.tmp" "$second"
expect_no_commit "$repo" "a review of changes does not build on the previous round" 12 "Add the marker"
grep -Fq "Run a complete review" "$repo.out" || fail "the broken chain did not ask for a complete review"

repo="$(setup_repo changes-orphan PASS "[]")"
second="$(add_changes_review "$repo")"
rm "$repo/$review"
expect_no_commit "$repo" "the round a review of changes builds on is missing" 12 "Add the marker"
grep -Fq "whose review is missing" "$repo.out" || fail "the missing earlier round was not reported"

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
