#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/fingerprint-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "fingerprint test failed: $*" >&2
  exit 1
}

source "$source_root/scripts/lib/fingerprint.sh"
source "$source_root/tests/lib-fakes.sh"

repo="$tmp/repo"
mkdir -p "$repo/docs" "$repo/.agents/reviews" "$repo/.agents/triage" "$repo/scripts/lib"
cp "$source_root/scripts/check-review.sh" "$repo/scripts/"
cp "$source_root/scripts/lib/"*.sh "$repo/scripts/lib/"
printf 'one\n' >"$repo/a.txt"
printf 'plan\n' >"$repo/docs/plan.md"
printf '*.log\n' >"$repo/.gitignore"
printf 'tracked although ignored\n' >"$repo/kept.log"
git -C "$repo" init -q -b main
git -C "$repo" config user.name "Fingerprint Test"
git -C "$repo" config user.email "fingerprint-test@example.com"
git -C "$repo" add .
git -C "$repo" add -f kept.log
git -C "$repo" commit -qm "Seed"

whole() {
  fingerprint_worktree "$repo" "$tmp"
}
files() {
  fingerprint_files "$repo" "$tmp" docs/plan.md
}

base="$(whole)"
[[ "$(whole)" == "$base" ]] || fail "the fingerprint of unchanged content is not stable"

# Review and triage artifacts and ignored files do not count.
printf '{}\n' >"$repo/.agents/reviews/x-review-01.json"
printf '{}\n' >"$repo/.agents/triage/x-review-01-triage.json"
printf 'build output\n' >"$repo/build.log"
[[ "$(whole)" == "$base" ]] || fail "review artifacts or ignored files changed the fingerprint"

# The metadata the workflow writes while it runs is not content: the record
# of a passed verification, the run records, and the state and logs of a
# run, also where the project does not ignore them.
mkdir -p "$repo/.agents/verification" "$repo/.agents/run/records" "$repo/.agents/records"
printf 'tree: abc\n' >"$repo/.agents/verification/passed"
printf '{"type": "risk", "level": "high"}\n' >"$repo/.agents/run/records/run-1.jsonl"
printf 'implemented\n' >"$repo/.agents/run/5-state"
printf '{"type": "run-end"}\n' >"$repo/.agents/records/feature-5.jsonl"
[[ "$(whole)" == "$base" ]] || fail "the verification record, the run records, or the state of a run changed the fingerprint"
rm -rf "$repo/.agents/verification" "$repo/.agents/run" "$repo/.agents/records"

# A changed, an untracked, and a deleted file each change it.
printf 'two\n' >>"$repo/a.txt"
changed="$(whole)"
[[ "$changed" != "$base" ]] || fail "a modified file did not change the fingerprint"
printf 'new\n' >"$repo/b.txt"
[[ "$(whole)" != "$changed" ]] || fail "an untracked file did not change the fingerprint"
rm "$repo/b.txt"
[[ "$(whole)" == "$changed" ]] || fail "removing the untracked file did not restore the fingerprint"

# Committing unchanged content keeps the fingerprint.
git -C "$repo" add a.txt
git -C "$repo" commit -qm "Commit the change"
[[ "$(whole)" == "$changed" ]] || fail "committing unchanged content changed the fingerprint"

# A tracked file that matches an ignore rule stays covered, also from a subdirectory.
printf 'changed\n' >>"$repo/kept.log"
from_subdirectory="$(cd "$repo/docs" && whole)"
[[ "$from_subdirectory" != "$changed" ]] || fail "a tracked ignored file was not covered"
git -C "$repo" checkout -q -- kept.log

# A file-set fingerprint covers exactly its files.
set_base="$(files)"
printf 'three\n' >>"$repo/a.txt"
[[ "$(files)" == "$set_base" ]] || fail "a file outside the set changed its fingerprint"
printf 'revised\n' >>"$repo/docs/plan.md"
[[ "$(files)" != "$set_base" ]] || fail "a file in the set did not change its fingerprint"
git -C "$repo" checkout -q -- a.txt docs/plan.md

# Artifacts are excluded from a file set too, also when it names a directory.
dir_base="$(fingerprint_files "$repo" "$tmp" . docs)"
printf '{"changed": true}\n' >"$repo/.agents/reviews/x-review-01.json"
[[ "$(fingerprint_files "$repo" "$tmp" . docs)" == "$dir_base" ]] ||
  fail "a review artifact changed a file-set fingerprint"

# A dangling symlink in a file set counts: its target and its removal matter.
ln -s missing-target "$repo/docs/link"
link_base="$(fingerprint_files "$repo" "$tmp" docs/link)"
[[ "$link_base" != "$(fingerprint_files "$repo" "$tmp" docs/absent)" ]] ||
  fail "a dangling symlink was treated as absent"
rm "$repo/docs/link"
ln -s other-target "$repo/docs/link"
[[ "$(fingerprint_files "$repo" "$tmp" docs/link)" != "$link_base" ]] ||
  fail "a changed symlink target did not change the fingerprint"
rm "$repo/docs/link"

# check-review.sh reports current and stale reviews for both kinds of review.
review="$repo/.agents/reviews/feature-1-x-review-01.json"
jq -n '{
  schema: "review/v1", issue: 1, round: 1, branch: "feature/1-x", base: "main",
  merge_base: "aaaa", head: "bbbb", reviewed_tree: "", reviewed_paths: null,
  reviewer: {agent: "codex", model: "m"}, created_at: "2026-01-01T00:00:00Z",
  verdict: "PASS", limitations: "", findings: []
}' >"$review"
record_reviewed_tree "$repo" "$review"
(cd "$repo" && ./scripts/check-review.sh "$review" >/dev/null) || fail "a current review was reported as stale"
printf 'four\n' >>"$repo/a.txt"
printf 'new\n' >"$repo/added.txt"
status=0
(cd "$repo" && ./scripts/check-review.sh "$review" >/dev/null 2>"$tmp/stale.err") || status=$?
[[ "$status" -eq 1 ]] || fail "a stale review was not reported as stale (status $status)"
# A stale review names what changed, and nothing else.
grep -Eq "^  M[[:space:]]+a.txt$" "$tmp/stale.err" || fail "the stale review did not name the modified file"
grep -Eq "^  A[[:space:]]+added.txt$" "$tmp/stale.err" || fail "the stale review did not name the added file"
[[ "$(grep -c '^  [AMD]' "$tmp/stale.err")" -eq 2 ]] || fail "the stale review named an unchanged file"
git -C "$repo" checkout -q -- a.txt
rm "$repo/added.txt"

# The claims of the implementer about the feature, which Git ignores, are
# part of what a feature review covers, since the reviewer judged them: a
# changed completion record or handoff note makes the review stale. They
# are not part of the content fingerprint that a verification is recorded
# for: a note about the verification does not change what was verified.
printf '.agents/completion/\n.agents/handoffs/\n' >>"$repo/.gitignore"
mkdir -p "$repo/.agents/completion" "$repo/.agents/handoffs"
printf '{"schema": "completion/v1", "status": "complete"}\n' >"$repo/.agents/completion/1.json"
printf 'Done.\n' >"$repo/.agents/handoffs/1.md"
record_reviewed_tree "$repo" "$review"
content="$(whole)"
(cd "$repo" && ./scripts/check-review.sh "$review" >/dev/null) || fail "a review with the claims recorded was reported as stale"
printf '{"schema": "completion/v1", "status": "partial"}\n' >"$repo/.agents/completion/1.json"
status=0
(cd "$repo" && ./scripts/check-review.sh "$review" >/dev/null 2>"$tmp/stale.err") || status=$?
[[ "$status" -eq 1 ]] || fail "a changed completion record did not make the feature review stale (status $status)"
grep -Eq "^  M[[:space:]]+.agents/completion/1.json$" "$tmp/stale.err" || fail "the stale review did not name the changed completion record"
[[ "$(whole)" == "$content" ]] || fail "a changed completion record changed the content fingerprint of the verification"
record_reviewed_tree "$repo" "$review"
printf 'Remaining: the docs.\n' >>"$repo/.agents/handoffs/1.md"
status=0
(cd "$repo" && ./scripts/check-review.sh "$review" >/dev/null 2>&1) || status=$?
[[ "$status" -eq 1 ]] || fail "a changed handoff note did not make the feature review stale (status $status)"
[[ "$(whole)" == "$content" ]] || fail "a changed handoff note changed the content fingerprint of the verification"
# The claims of another Issue, and the artifacts of the review itself, are
# not part of it.
record_reviewed_tree "$repo" "$review"
printf 'Other.\n' >"$repo/.agents/handoffs/2.md"
printf '{"changed": true}\n' >"$repo/.agents/reviews/x-review-01.json"
(cd "$repo" && ./scripts/check-review.sh "$review" >/dev/null) || fail "the claims of another Issue, or a review artifact, made the review stale"
rm -rf "$repo/.agents/completion" "$repo/.agents/handoffs/1.md" "$repo/.agents/handoffs/2.md"
record_reviewed_tree "$repo" "$review"

jq --arg tree "$(files)" '.reviewed_paths = ["docs/plan.md"] | .reviewed_tree = $tree' "$review" >"$review.tmp"
mv "$review.tmp" "$review"
printf 'five\n' >>"$repo/a.txt"
(cd "$repo" && ./scripts/check-review.sh "$review" >/dev/null) ||
  fail "a change outside the reviewed paths made the review stale"
printf 'revised\n' >>"$repo/docs/plan.md"
status=0
(cd "$repo" && ./scripts/check-review.sh "$review" >/dev/null 2>"$tmp/stale.err") || status=$?
[[ "$status" -eq 1 ]] || fail "a change to a reviewed path did not make the review stale"
# Only the reviewed paths are compared, so the change outside them is not named.
grep -Eq "^  M[[:space:]]+docs/plan.md$" "$tmp/stale.err" || fail "the stale review did not name the reviewed path"
if grep -Fq "a.txt" "$tmp/stale.err"; then fail "the stale review named a path it does not cover"; fi

# A long list of changes is cut off with a count, and the review is still
# reported as stale with its normal status.
for number in $(seq 1 30); do printf 'x\n' >"$repo/docs/extra-$number.md"; done
jq '.reviewed_paths = ["docs"]' "$review" >"$review.tmp"
mv "$review.tmp" "$review"
status=0
(cd "$repo" && ./scripts/check-review.sh "$review" >/dev/null 2>"$tmp/stale.err") || status=$?
[[ "$status" -eq 1 ]] || fail "a review with many changes was not reported as stale (status $status)"
[[ "$(grep -c '^  [AMD]' "$tmp/stale.err")" -eq 20 ]] || fail "a long list of changes was not cut off at 20"
grep -Eq "and [0-9]+ more" "$tmp/stale.err" || fail "the remaining changes were not counted"
rm "$repo"/docs/extra-*.md

# A reviewed tree that is not in the object database gives no notice and
# still reports the review as stale.
jq '.reviewed_tree = "0123456789012345678901234567890123456789"' "$review" >"$review.tmp"
mv "$review.tmp" "$review"
status=0
(cd "$repo" && ./scripts/check-review.sh "$review" >/dev/null 2>"$tmp/stale.err") || status=$?
[[ "$status" -eq 1 ]] || fail "a review with an unknown tree was not reported as stale (status $status)"
if grep -Fq "Changed since the review" "$tmp/stale.err"; then fail "a notice was printed for an unknown tree"; fi

echo "fingerprint tests passed"
