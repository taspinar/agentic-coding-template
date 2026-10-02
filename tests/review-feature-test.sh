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

# The fake reviewer records its arguments and standard input, then behaves
# according to MOCK_REVIEW_MODE.
cat >"$tmp/bin/claude" <<'AGENT'
#!/usr/bin/env bash
set -euo pipefail

agent="$(basename "$0")"
{
  echo "AGENT=$agent"
  echo "ARGS=$*"
} >>"$MOCK_AGENT_LOG"
cat >"$MOCK_AGENT_LOG.stdin"

output_file=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--output-last-message" ]]; then
    output_file="$2"
  fi
  shift
done

report() {
  if [[ -n "$output_file" ]]; then
    cat >"$output_file"
  else
    cat
  fi
}

case "${MOCK_REVIEW_MODE:-success}" in
  fail)
    exit 43
    ;;
  large)
    {
      printf '## Critical\n\nNone.\n\n## Major\n\nNone.\n\n## Minor\n\nNone.\n\n## Suggestions\n\n'
      for ((line = 0; line < 6000; line++)); do
        printf -- '- Suggestion detail line %s that pads the report beyond a pipe buffer.\n' "$line"
      done
      printf '\n## Verdict\n\nPASS WITH MINOR FINDINGS\n'
    } | report
    exit 0
    ;;
  no-verdict)
    printf '## Critical\n\nNone.\n\n## Major\n\nNone.\n' | report
    exit 0
    ;;
  modify)
    printf 'changed by the reviewer\n' >>feature.txt
    ;;
  create)
    printf 'created by the reviewer\n' >reviewer-note.txt
    ;;
esac

report <<'REPORT'
Preface that is not part of the review.

## Critical

None.

## Major

### M1. Marker content is unchecked

The marker file is created but never read.

## Minor

None.

## Suggestions

None.

## Verdict

**CHANGES REQUIRED**
REPORT
AGENT
cp "$tmp/bin/claude" "$tmp/bin/codex"
chmod +x "$tmp/bin/gh" "$tmp/bin/claude" "$tmp/bin/codex"

# Creates a repository on feature/7-marker with one committed, one modified,
# and one untracked file relative to main.
setup_repo() {
  local repo="$tmp/$1"

  mkdir -p "$repo/scripts/lib" "$repo/.agents/prompts"
  cp "$source_root/scripts/review-feature.sh" "$repo/scripts/review-feature.sh"
  cp "$source_root/scripts/lib/agent.sh" "$repo/scripts/lib/agent.sh"
  cp "$source_root/.agents/prompts/reviewer.md" "$repo/.agents/prompts/reviewer.md"
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
  if compgen -G "$repo/.agents/reviews/*.md" >/dev/null; then
    fail "a review was stored although: $description"
  fi
}

# The script stores the returned report; the reviewer runs read-only and
# receives the Issue and the complete diff on standard input.
repo="$(setup_repo claude)"
run_review "$repo" 7 || {
  cat "$repo.out" >&2
  fail "review with the configured agent failed"
}
artifact="$repo/.agents/reviews/feature-7-marker-review-01.md"
[[ -f "$artifact" ]] || fail "the script did not store the review"
grep -Fqx "Issue: #7" "$artifact" || fail "stored review lacks the Issue reference"
grep -Fqx "### M1. Marker content is unchecked" "$artifact" || fail "stored review lacks the returned finding"
if grep -Fq "Preface that is not part of the review" "$artifact"; then
  fail "text before the first section was stored"
fi
grep -Fq -- "--permission-mode plan --tools Read,Glob,Grep" "$repo.log" ||
  fail "Claude reviewer was not restricted to read tools"
grep -Fq -- "--model model-r" "$repo.log" || fail "configured model was not passed to the reviewer"
grep -Fq "The marker file must exist." "$repo.log.stdin" || fail "Issue was not supplied to the reviewer"
for change in "+committed change" "+uncommitted change" "+untracked marker"; do
  grep -Fqx -- "$change" "$repo.log.stdin" || fail "diff supplied to the reviewer lacks: $change"
done
[[ -z "$(git -C "$repo" status --porcelain -- feature.txt marker.txt | grep -v '^ M feature.txt$' | grep -v '^?? marker.txt$')" ]] ||
  fail "the review changed the state of the reviewed files"

# A second round is numbered and points the reviewer at the previous review,
# which is not part of the reviewed diff.
run_review "$repo" 7 --agent codex --model model-c || {
  cat "$repo.out" >&2
  fail "re-review with an overridden agent failed"
}
[[ -f "$repo/.agents/reviews/feature-7-marker-review-02.md" ]] || fail "re-review was not numbered"
grep -Fq "feature-7-marker-review-01.md" "$repo.log" || fail "re-review did not reference the previous review"
grep -Fq -- "exec --sandbox read-only" "$repo.log" || fail "Codex reviewer was not sandboxed read-only"
if grep -Fq "Marker content is unchecked" "$repo.log.stdin"; then
  fail "previous review artifact was included in the reviewed diff"
fi

# A reviewer that changes or creates files is detected.
repo="$(setup_repo modify)"
MOCK_REVIEW_MODE=modify expect_no_review "$repo" "the reviewer modified a file" 7
grep -Fq "modified the working tree" "$repo.out" || fail "modification was not reported"

repo="$(setup_repo create)"
MOCK_REVIEW_MODE=create expect_no_review "$repo" "the reviewer created a file" 7

# A large valid report is stored.
repo="$(setup_repo large)"
MOCK_REVIEW_MODE=large run_review "$repo" 7 || {
  cat "$repo.out" >&2
  fail "a large valid report was rejected"
}

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

# A failed reviewer or an unusable report stores nothing.
repo="$(setup_repo agent-fails)"
MOCK_REVIEW_MODE=fail expect_no_review "$repo" "the reviewer failed" 7

repo="$(setup_repo no-verdict)"
MOCK_REVIEW_MODE=no-verdict expect_no_review "$repo" "the report has no verdict" 7

# Invalid invocations fail before a reviewer starts.
repo="$(setup_repo preconditions)"
expect_no_review "$repo" "the branch belongs to another Issue" 8
expect_no_review "$repo" "the agent is unsupported" 7 --agent copilot --model model-x
MOCK_GH_AUTH_EXIT=1 expect_no_review "$repo" "the GitHub CLI is not authenticated" 7
expect_no_review "$repo" "the base branch does not exist" 7 missing-base
[[ ! -e "$repo.log" ]] || fail "a reviewer was started despite failed preconditions"

echo "review-feature tests passed"
