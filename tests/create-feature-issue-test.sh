#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/create-feature-issue-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "create-feature-issue test failed: $*" >&2
  exit 1
}

mkdir -p "$tmp/bin"
ln -sf "$(command -v jq)" "$tmp/bin/jq"

# The fake GitHub CLI lists the Issues in MOCK_ISSUES and logs created ones.
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "auth status") exit 0 ;;
  "issue list")
    if [[ -n "${MOCK_FAIL_SEARCH:-}" && "$*" == *"$MOCK_FAIL_SEARCH in:title"* ]]; then
      echo "simulated search failure" >&2
      exit 1
    fi
    printf '%s\n' "${MOCK_ISSUES:-[]}"
    exit 0
    ;;
  "issue create")
    shift 2
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --title) echo "TITLE: $2" >>"$MOCK_GH_LOG"; shift 2 ;;
        --body-file) cat "$2" >>"$MOCK_GH_LOG"; shift 2 ;;
        *) shift ;;
      esac
    done
    echo "https://github.com/example/project/issues/50"
    exit 0
    ;;
esac
echo "Unexpected gh invocation: $*" >&2
exit 1
GH
chmod +x "$tmp/bin/gh"

repo="$tmp/repo"
mkdir -p "$repo/scripts/lib" "$repo/docs"
cp "$source_root/scripts/create-feature-issue.sh" "$repo/scripts/"
cp "$source_root"/scripts/lib/*.sh "$repo/scripts/lib/"
git -C "$repo" init -q -b main

# Records a planning approval that matches the current planning documents.
approve_planning() {
  local fingerprint
  fingerprint="$(
    source "$source_root/scripts/lib/fingerprint.sh"
    source "$source_root/scripts/lib/planning.sh"
    fingerprint_files "$repo" "$tmp" "${PLANNING_SCOPE[@]}"
  )"
  printf '# Planning Approval\n\nStatus: Approved\nPlanning fingerprint: %s\n' "$fingerprint" \
    >"$repo/docs/PLANNING_APPROVAL.md"
}

write_roadmap() {
  cat >"$repo/docs/roadmap.md"
}

run_create() {
  local answer="$1"
  shift

  rm -f "$tmp/gh.log"
  (
    cd "$repo"
    printf '%s\n' "$answer" |
      PATH="$tmp/bin:/usr/bin:/bin" MOCK_GH_LOG="$tmp/gh.log" ./scripts/create-feature-issue.sh "$@"
  ) >"$tmp/out.log" 2>&1
}

expect_nothing_created() {
  local description="$1"
  shift

  if run_create y "$@"; then
    cat "$tmp/out.log" >&2
    fail "expected failure: $description"
  fi
  [[ ! -e "$tmp/gh.log" ]] || fail "an Issue was created although: $description"
}

write_roadmap <<'ROADMAP'
# Roadmap

## Phase 1

### F01 — Account sign-in

- Goal: users can sign in.
- Acceptance criteria: sign-in works.

### F02 — Recipe list

- Goal: users see their recipes.
- Dependencies: F01.
- Acceptance criteria:
  - The list shows every recipe.
  - An empty list shows a hint.

#### Notes

Pagination comes later.

### F03 — Sharing

- Goal: share a recipe.
- Example:

  ```bash
  # Share a recipe
  ./share recipe-1
  ```

- Acceptance criteria: a shared link opens the recipe.

## Phase 2

### F10 — Empty feature

### F11 — Duplicate

- First.

### F11 — Duplicate again

- Second.
ROADMAP

# Feature Issues require a planning approval that matches the roadmap.
expect_nothing_created "the planning is not approved" F02
grep -Fq "finish-planning.sh" "$tmp/out.log" || fail "a missing planning approval did not point to finish-planning.sh"
approve_planning
cp "$repo/docs/roadmap.md" "$tmp/roadmap.saved"
printf '\n<!-- changed after approval -->\n' >>"$repo/docs/roadmap.md"
expect_nothing_created "the roadmap changed after the planning approval" F02
cp "$tmp/roadmap.saved" "$repo/docs/roadmap.md"

# After approval, the Issue is created from exactly the feature's block, with
# the feature ID first in its title.
run_create y F02 || {
  cat "$tmp/out.log" >&2
  fail "creating the F02 Issue failed"
}
grep -Fqx "TITLE: F02 — Recipe list" "$tmp/gh.log" || fail "the title does not start with the feature ID"
grep -Fqx "  - An empty list shows a hint." "$tmp/gh.log" || fail "the body lacks the block content"
grep -Fqx "Pagination comes later." "$tmp/gh.log" || fail "the body lacks a subsection of the block"
if grep -Fq "Sharing" "$tmp/gh.log" || grep -Fq "Account sign-in" "$tmp/gh.log"; then
  fail "the body contains another feature's block"
fi
grep -Fq "docs/roadmap.md" "$tmp/gh.log" || fail "the body does not reference the roadmap"

# Heading-like lines inside fenced code do not end a block.
run_create y F03 || {
  cat "$tmp/out.log" >&2
  fail "creating the F03 Issue failed"
}
grep -Fqx -- "- Acceptance criteria: a shared link opens the recipe." "$tmp/gh.log" ||
  fail "a heading-like line in fenced code truncated the block"

# A failing lookup is never ignored: for the feature itself it stops, and for
# a referenced feature it warns.
MOCK_FAIL_SEARCH=F02 expect_nothing_created "the existing Issues cannot be listed" F02
MOCK_FAIL_SEARCH=F01 run_create n F02 || fail "previewing F02 with a failing dependency lookup failed"
grep -Fq "could not check whether F01" "$tmp/out.log" || fail "a failing dependency lookup was not reported"

# Declining creates nothing.
run_create n F03 || fail "declining returned an error"
[[ ! -e "$tmp/gh.log" ]] || fail "an Issue was created after declining"

# An existing Issue for the feature, open or closed, prevents a duplicate;
# an ID that merely starts the same does not.
MOCK_ISSUES='[{"number": 7, "state": "CLOSED", "title": "F03 — Sharing"}]' \
  expect_nothing_created "F03 already has an Issue" F03
grep -Fq "#7" "$tmp/out.log" || fail "the existing Issue was not reported"
MOCK_ISSUES='[{"number": 8, "state": "OPEN", "title": "F030 — Something else"}]' run_create y F03 ||
  fail "an Issue for F030 blocked F03"

# An open Issue of a referenced feature is reported.
MOCK_ISSUES='[{"number": 4, "state": "OPEN", "title": "F01 — Account sign-in"}]' run_create n F02 ||
  fail "previewing F02 with an open dependency failed"
grep -Fq "refers to F01, whose Issue #4 is still open" "$tmp/out.log" || fail "an open dependency was not reported"

# Unknown, duplicated, empty, and malformed feature IDs are rejected.
expect_nothing_created "the feature is not in the roadmap" F99
expect_nothing_created "the feature heading is duplicated" F11
expect_nothing_created "the feature block is empty" F10
expect_nothing_created "the feature ID is malformed" 3

# The explicit title-and-file form still works.
printf 'Body text.\n' >"$tmp/body.md"
run_create y "Maintenance task" "$tmp/body.md" || fail "the title-and-file form failed"
grep -Fqx "TITLE: Maintenance task" "$tmp/gh.log" || fail "the title-and-file form used the wrong title"

echo "create-feature-issue tests passed"
