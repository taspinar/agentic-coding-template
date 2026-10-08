#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/publish-feature-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "publish-feature test failed: $*" >&2
  exit 1
}

# A fake GitHub CLI. It records every call, keeps the body of a created pull
# request, and answers 'pr checks' as the test sets it up:
#   MOCK_OPEN_PR       URL of a pull request that is already open
#   MOCK_CHECKS        'pass' (default), 'fail', or 'none' (no checks reported)
#   MOCK_CREATE_EXIT   exit status of 'pr create'
#   MOCK_REQUIRED      number of status checks the base branch requires
#                      (default 0); 'unreadable' makes the question fail
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$MOCK_GH_LOG"
case "${1:-} ${2:-}" in
  "pr list")
    printf '%s\n' "${MOCK_OPEN_PR:-}"
    ;;
  "pr create" | "pr edit")
    [[ "$2" != "create" || "${MOCK_CREATE_EXIT:-0}" -eq 0 ]] || exit "$MOCK_CREATE_EXIT"
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
      if [[ "${args[$i]}" == "--body-file" ]]; then cp "${args[$((i + 1))]}" "$MOCK_GH_LOG.body"; fi
    done
    [[ "$2" != "create" ]] || echo "https://github.com/example/project/pull/7"
    ;;
  "pr view")
    echo "main"
    ;;
  "api repos/{owner}/{repo}/rules/branches/main")
    [[ "${MOCK_REQUIRED:-0}" != "unreadable" ]] || exit 1
    echo "${MOCK_REQUIRED:-0}"
    ;;
  "api repos/{owner}/{repo}/branches/main")
    [[ "${MOCK_REQUIRED:-0}" != "unreadable" ]] || exit 1
    echo "0"
    ;;
  "pr checks")
    case "${MOCK_CHECKS:-pass}" in
      pass) echo "verify pass" ;;
      fail) echo "verify fail"; exit 1 ;;
      none) echo "no checks reported on the 'feature' branch" >&2; exit 1 ;;
    esac
    ;;
  *)
    echo "Unexpected gh invocation: $*" >&2
    exit 97
    ;;
esac
GH
chmod +x "$tmp/bin/gh"

# Creates a clone on a committed feature branch of Issue 12, with a remote.
setup_repo() {
  local label="$1"
  local remote="$tmp/$label-remote.git"
  local repo="$tmp/$label"

  git init -q --bare -b main "$remote"
  git clone -q "$remote" "$repo" 2>/dev/null
  mkdir -p "$repo/scripts/lib"
  cp "$source_root/scripts/publish-feature.sh" "$repo/scripts/"
  cp "$source_root/scripts/lib/github.sh" "$repo/scripts/lib/"
  printf '.agents/manual-steps/\n' >"$repo/.gitignore"
  git -C "$repo" config user.name "Publish Test"
  git -C "$repo" config user.email "publish-test@example.com"
  git -C "$repo" checkout -q -b main
  git -C "$repo" add .
  git -C "$repo" commit -qm "Seed"
  git -C "$repo" push -q origin main
  git -C "$repo" checkout -q -b feature/12-marker
  printf 'marker\n' >"$repo/feature.txt"
  git -C "$repo" add feature.txt
  git -C "$repo" commit -qm "Add the marker" -m "Issue: #12" -m "Review: round 1, PASS, by claude (model-r)"
  printf '%s\n' "$repo"
}

run_publish() {
  local repo="$1"
  shift
  (
    cd "$repo"
    PATH="$tmp/bin:/usr/bin:/bin" MOCK_GH_LOG="$repo.gh" \
      PUBLISH_POLL_SECONDS=0 PUBLISH_START_ATTEMPTS=2 ./scripts/publish-feature.sh "$@"
  ) >"$repo.out" 2>&1
}

pushed() {
  git -C "$1" ls-remote --exit-code --heads origin feature/12-marker >/dev/null 2>&1
}

# The branch is pushed, the pull request closes the Issue and carries the
# commit message and the manual steps, and passing checks end successfully.
repo="$(setup_repo pass)"
mkdir -p "$repo/.agents/manual-steps"
printf -- '- Enable GitHub Pages under Settings, Pages.\n' >"$repo/.agents/manual-steps/12.md"
run_publish "$repo" 12 || {
  cat "$repo.out" >&2
  fail "publishing a committed feature failed"
}
pushed "$repo" || fail "the branch was not pushed"
grep -Fq "pr create --head feature/12-marker --title Add the marker" "$repo.gh" ||
  fail "the pull request was not opened with the commit summary as its title"
for line in "Issue: #12" "Review: round 1, PASS, by claude (model-r)" "## Manual steps" \
  "- Enable GitHub Pages under Settings, Pages." "Closes #12"; do
  grep -Fqx -- "$line" "$repo.gh.body" || fail "the pull request description lacks: $line"
done
grep -Fq "pr checks feature/12-marker --watch" "$repo.gh" || fail "the checks were not awaited"
grep -Fq "does not require a status check" "$repo.out" || fail "the reason for waiting was not given"
grep -Fq "All checks passed" "$repo.out" || fail "passing checks were not reported"
grep -Fq "https://github.com/example/project/pull/7" "$repo.out" || fail "the pull request was not named"
grep -Fq "Enable GitHub Pages" "$repo.out" || fail "the manual steps were not shown"
grep -Fq "./scripts/cleanup-worktree.sh 12" "$repo.out" || fail "the next step was not printed"
if grep -Eq "pr merge" "$repo.gh"; then fail "the pull request was merged"; fi

# Without manual steps the description says so.
repo="$(setup_repo no-steps)"
run_publish "$repo" 12 || fail "publishing a feature without manual steps failed"
grep -A2 -Fx "## Manual steps" "$repo.gh.body" | grep -Fqx "None." ||
  fail "the description does not say that there are no manual steps"

# A failing check fails the run and tells the user not to merge.
repo="$(setup_repo checks-fail)"
if MOCK_CHECKS=fail run_publish "$repo" 12; then fail "a failed check returned success"; fi
grep -Fq "Do not merge" "$repo.out" || fail "a failed check did not warn against merging"
if grep -Fq "All checks passed" "$repo.out"; then fail "a failed check was reported as passed"; fi

# A repository without checks is reported as unverified, not as passed.
repo="$(setup_repo no-checks)"
MOCK_CHECKS=none run_publish "$repo" 12 || fail "a pull request without checks failed the run"
grep -Fq "No checks were reported" "$repo.out" || fail "missing checks were not reported"
if grep -Fq "All checks passed" "$repo.out"; then fail "missing checks were reported as passed"; fi
if grep -Fq -- "--watch" "$repo.gh"; then fail "checks that never started were awaited"; fi

# An open pull request is reused and gets the current description, so manual
# steps that a fix round changed are not left outdated. --no-wait stops before
# the checks.
repo="$(setup_repo reuse)"
mkdir -p "$repo/.agents/manual-steps"
printf -- '- Add the secret API_KEY.\n' >"$repo/.agents/manual-steps/12.md"
MOCK_OPEN_PR="https://github.com/example/project/pull/3" run_publish "$repo" 12 --no-wait ||
  fail "publishing to an open pull request failed"
pushed "$repo" || fail "the branch was not pushed for an open pull request"
if grep -Fq "pr create" "$repo.gh"; then fail "a second pull request was opened"; fi
grep -Fq "pr edit https://github.com/example/project/pull/3 --body-file" "$repo.gh" ||
  fail "the description of the open pull request was not updated"
grep -Fqx -- "- Add the secret API_KEY." "$repo.gh.body" || fail "the updated description lacks the manual steps"
grep -Fqx "Closes #12" "$repo.gh.body" || fail "the updated description no longer closes the Issue"
if grep -Fq "pr checks" "$repo.gh"; then fail "--no-wait waited for the checks"; fi
grep -Fq "gh pr checks feature/12-marker --watch" "$repo.out" || fail "--no-wait did not say how to watch the checks"

# When the base branch requires a passing status check, GitHub refuses a merge
# while a check fails, so the script does not wait. --wait waits anyway.
repo="$(setup_repo required-check)"
MOCK_REQUIRED=1 MOCK_CHECKS=fail run_publish "$repo" 12 || {
  cat "$repo.out" >&2
  fail "publishing to a branch with a required check failed"
}
grep -Fq "pr create" "$repo.gh" || fail "the pull request was not opened"
if grep -Fq "pr checks" "$repo.gh"; then fail "the script waited although the base branch requires a check"; fi
grep -Fq "requires a passing status check" "$repo.out" || fail "the reason for not waiting was not given"
grep -Fq "gh pr checks feature/12-marker --watch" "$repo.out" || fail "the command to follow the checks was not printed"
grep -Fq "./scripts/cleanup-worktree.sh 12" "$repo.out" || fail "the next step was not printed"

repo="$(setup_repo required-but-wait)"
if MOCK_REQUIRED=1 MOCK_CHECKS=fail run_publish "$repo" 12 --wait; then
  fail "--wait did not wait for a failing check"
fi
grep -Fq "Do not merge" "$repo.out" || fail "--wait did not report the failed check"

# Without a required check, and when the rules cannot be read, it waits.
repo="$(setup_repo rules-unreadable)"
if MOCK_REQUIRED=unreadable MOCK_CHECKS=fail run_publish "$repo" 12; then
  fail "unreadable rules were treated as a required check"
fi
grep -Fq "Could not read" "$repo.out" || fail "the unreadable rules were not reported"
grep -Fq -- "--watch" "$repo.gh" || fail "the script did not wait with unreadable rules"

# A pull request that cannot be opened fails after the push and says so.
repo="$(setup_repo create-fails)"
if MOCK_CREATE_EXIT=1 run_publish "$repo" 12; then fail "a pull request that could not be opened returned success"; fi
grep -Fq "The branch is pushed" "$repo.out" || fail "the failure did not say that the branch is pushed"

# Uncommitted work, another branch, and invalid arguments are refused before
# anything is pushed or asked from GitHub.
repo="$(setup_repo refused)"
printf 'more\n' >>"$repo/feature.txt"
if run_publish "$repo" 12; then fail "uncommitted changes were published"; fi
grep -Fq "finish-feature.sh 12" "$repo.out" || fail "uncommitted changes did not point to finish-feature.sh"
git -C "$repo" checkout -q -- feature.txt
if run_publish "$repo" 13; then fail "a branch of another Issue was published"; fi
if run_publish "$repo" twelve; then fail "a non-numeric issue was accepted"; fi
if run_publish "$repo" 12 --force; then fail "an unknown option was accepted"; fi
if pushed "$repo"; then fail "a refused run pushed the branch"; fi
[[ ! -e "$repo.gh" ]] || fail "a refused run called GitHub"

echo "publish-feature tests passed"
