#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/check-docs-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "check-docs test failed: $*" >&2
  exit 1
}

# A repository with a guide that names an existing script, an existing
# document, and a working file that Git ignores.
setup_repo() {
  local repo="$tmp/$1"

  mkdir -p "$repo/docs" "$repo/scripts" "$repo/.agents/reviews"
  cp "$source_root/scripts/check-docs.sh" "$repo/scripts/check-docs.sh"
  printf '.agents/reviews/\n' >"$repo/.gitignore"
  printf '# Workflow\n' >"$repo/docs/workflow.md"
  {
    printf '# Guide\n\n'
    printf 'Read [the workflow](workflow.md#flow) and run `scripts/check-docs.sh`.\n'
    printf 'A review is stored as `.agents/reviews/feature-1-review-01.json`.\n'
    printf 'A plan is `docs/plans/<issue>.md`; see https://example.org/x.md and `README.md`.\n'
  } >"$repo/docs/guide.md"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.name "Check Docs Test"
  git -C "$repo" config user.email "check-docs-test@example.com"
  git -C "$repo" add .
  git -C "$repo" commit -qm "Seed"
  printf '%s\n' "$repo"
}

# check <repo> [argument...]: runs the check; sets 'status' and '<repo>.out'.
check() {
  local repo="$1"

  shift
  status=0
  (cd "$repo" && ./scripts/check-docs.sh "$@") >"$repo.out" 2>&1 || status=$?
}

# References that hold: a link with an anchor, an existing script, an ignored
# working file, a path with a placeholder, an external link, a bare file name.
repo="$(setup_repo holds)"
check "$repo"
[[ "$status" -eq 0 ]] || {
  cat "$repo.out" >&2
  fail "a guide whose references hold was refused"
}

# A document that another change removed, named in backticks: the case this
# check exists for.
repo="$(setup_repo removed)"
printf 'The principles are in `docs/principles.md`.\n' >>"$repo/docs/guide.md"
git -C "$repo" commit -qam "Name a document"
check "$repo"
[[ "$status" -eq 1 ]] || fail "a path in backticks to a missing file was accepted ($status)"
grep -Fq "docs/guide.md names docs/principles.md" "$repo.out" || fail "the missing file was not named"

# The same path is accepted when the caller says it comes later, by itself or
# by a directory above it.
check "$repo" --later docs/principles.md
[[ "$status" -eq 0 ]] || fail "--later with the path did not accept it"
check "$repo" --later docs
[[ "$status" -eq 0 ]] || fail "--later with a directory above the path did not accept it"
check "$repo" --later scripts
[[ "$status" -eq 1 ]] || fail "--later with another directory accepted the path"

# A broken relative link, resolved from the file that holds it.
repo="$(setup_repo link)"
printf 'See [the map](project-map.md) and [the script](../scripts/check-docs.sh).\n' >>"$repo/docs/guide.md"
git -C "$repo" commit -qam "Add links"
check "$repo"
[[ "$status" -eq 1 ]] || fail "a link to a missing file was accepted ($status)"
grep -Fq "docs/guide.md links to project-map.md" "$repo.out" || fail "the broken link was not named"
if grep -Fq "check-docs.sh, which" "$repo.out"; then fail "a link that holds was reported"; fi

# Every form of a link is read: with a title, in angle brackets, and as the
# definition of a reference link.
repo="$(setup_repo forms)"
{
  printf 'See [one](gone-one.md "A title"), [two](<gone-two.md>), and [three][ref].\n\n'
  printf '[ref]: gone-three.md\n'
  printf '[kept]: workflow.md "The workflow"\n'
} >>"$repo/docs/guide.md"
git -C "$repo" commit -qam "Add links in other forms"
check "$repo"
[[ "$status" -eq 1 ]] || fail "links with a title, in brackets, or by reference were not read ($status)"
for target in gone-one.md gone-two.md gone-three.md; do
  grep -Fq "links to $target" "$repo.out" || fail "the link to $target was not reported"
done
if grep -Fq "links to workflow.md" "$repo.out"; then fail "a reference link that holds was reported"; fi

# A destination with spaces in angle brackets, a definition whose destination
# stands on the next line, and a link that leaves the repository.
repo="$(setup_repo edges)"
printf '# Notes\n' >"$repo/docs/release notes.md"
{
  printf 'See [the notes](<release notes.md>) and [more](<gone notes.md> "Gone").\n\n'
  printf '[held]:\n  workflow.md\n\n'
  printf '[broken]:\n  gone-below.md\n'
} >>"$repo/docs/guide.md"
printf 'Outside: [a sibling](../outside-of-the-repository.md).\n' >"$repo/TOP.md"
git -C "$repo" add .
git -C "$repo" commit -qm "Add edge cases"
check "$repo"
[[ "$status" -eq 1 ]] || fail "edge cases of links were accepted ($status)"
for target in "gone notes.md" gone-below.md ../outside-of-the-repository.md; do
  grep -Fq "links to $target" "$repo.out" || {
    cat "$repo.out" >&2
    fail "the link to '$target' was not reported"
  }
done
if grep -Eq "links to (release notes.md|workflow.md)" "$repo.out"; then
  cat "$repo.out" >&2
  fail "a link that holds was reported"
fi
printf 'A sibling.\n' >"$tmp/outside-of-the-repository.md"
check "$repo"
if grep -Fq "outside-of-the-repository.md" "$repo.out"; then fail "an existing file outside the repository was reported"; fi
rm "$tmp/outside-of-the-repository.md"

# A destination may hold balanced parentheses, and a link that is shown as an
# example, in a fenced code block or in inline code, is not a link.
repo="$(setup_repo shown)"
printf '# Guide, second version\n' >"$repo/docs/guide(v2).md"
{
  printf 'Read [the second version](guide(v2).md) and [a lost one](lost(v3).md "Lost").\n\n'
  printf 'Write a link as `[text](no-such-file.md)`.\n\n'
  printf '```markdown\n[an example](example-that-is-not-there.md)\n[ref]: nowhere.md\n```\n\n'
  printf '~~~\n[another](also-not-there.md)\n~~~\n\n'
  printf 'After the blocks: [gone](gone-after.md).\n'
} >>"$repo/docs/guide.md"
git -C "$repo" add .
git -C "$repo" commit -qm "Show links as examples"
check "$repo"
[[ "$status" -eq 1 ]] || fail "links around code blocks were accepted ($status)"
for target in "lost(v3).md" gone-after.md; do
  grep -Fq "links to $target" "$repo.out" || {
    cat "$repo.out" >&2
    fail "the link to '$target' was not reported"
  }
done
if grep -Eq "guide\(v2\)|no-such-file|example-that-is-not-there|nowhere|also-not-there" "$repo.out"; then
  cat "$repo.out" >&2
  fail "a destination with parentheses that exists, or a link shown as an example, was reported"
fi
[[ "$(grep -c "links to" "$repo.out")" -eq 2 ]] || {
  cat "$repo.out" >&2
  fail "more or fewer links were reported than the two that are broken"
}

# A fence closes only with its own character and at least its own length, so
# another fence inside a block is text, and a link after the block is read.
# Inline code may be delimited by more than one backtick.
repo="$(setup_repo fences)"
{
  printf '```markdown\n~~~\n[inside one](inside-one.md)\n```\n\n'
  printf 'Between: [between](gone-between.md).\n\n'
  printf '````markdown\n```\n[inside two](inside-two.md)\n```\n[still inside](still-inside.md)\n````\n\n'
  printf '~~~~\n~~~\n[inside three](inside-three.md)\n~~~~\n\n'
  printf 'Write ``[text](double-backticks.md)`` or ```[text](triple `one` inside.md)```.\n\n'
  printf 'After: [after](gone-after-fences.md) and an unclosed ``run [open](gone-open.md).\n'
} >>"$repo/docs/guide.md"
git -C "$repo" commit -qam "Nest fences and inline code"
check "$repo"
[[ "$status" -eq 1 ]] || fail "links around nested fences were accepted ($status)"
for target in gone-between.md gone-after-fences.md gone-open.md; do
  grep -Fq "links to $target" "$repo.out" || {
    cat "$repo.out" >&2
    fail "the link to '$target' was not reported"
  }
done
if grep -Eq "inside-one|inside-two|still-inside|inside-three|double-backticks|triple" "$repo.out"; then
  cat "$repo.out" >&2
  fail "a link inside a fenced block or inline code was reported"
fi
[[ "$(grep -c "links to" "$repo.out")" -eq 3 ]] || {
  cat "$repo.out" >&2
  fail "more or fewer links were reported than the three that are broken"
}

# A link is exempt like a path: an ignored working file, a placeholder, and a
# file that comes later, also when the link climbs out of its directory.
repo="$(setup_repo exempt)"
{
  printf 'The [review](../.agents/reviews/feature-1-review-01.json) of [an Issue](plans/<issue>.md).\n'
  printf 'Later: [the approval](../docs/APPROVAL.md).\n'
} >>"$repo/docs/guide.md"
git -C "$repo" commit -qam "Link to working files"
check "$repo"
[[ "$status" -eq 1 ]] || fail "a link to a file that does not exist yet was accepted without --later"
grep -Fq "links to ../docs/APPROVAL.md" "$repo.out" || fail "the link to the later file was not reported"
if grep -Eq "review-01.json|issue" "$repo.out"; then
  cat "$repo.out" >&2
  fail "a link to an ignored file or with a placeholder was reported"
fi
check "$repo" --later docs/APPROVAL.md
[[ "$status" -eq 0 ]] || {
  cat "$repo.out" >&2
  fail "--later did not accept a link that reaches the path through '..'"
}

# Only tracked Markdown files are read, and only paths into a tracked
# top-level directory are judged.
repo="$(setup_repo scope)"
printf 'Not committed: `docs/missing.md`.\n' >"$repo/docs/draft.md"
printf 'Elsewhere: `vendor/readme.md`.\n' >>"$repo/docs/guide.md"
git -C "$repo" commit -qm "Name a path outside the repository layout" -- docs/guide.md
check "$repo"
[[ "$status" -eq 0 ]] || {
  cat "$repo.out" >&2
  fail "an untracked file or a path outside the tracked directories was judged"
}

# Refusals.
repo="$(setup_repo refusals)"
check "$repo" --later
[[ "$status" -eq 2 ]] || fail "--later without a path was accepted"
check "$repo" --everything
[[ "$status" -eq 2 ]] || fail "an unknown option was accepted"

echo "check-docs tests passed"
