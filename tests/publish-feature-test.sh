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
#   MOCK_DRAFT         'true' when the open pull request is a draft
#   MOCK_UNDO_EXIT     exit status of 'pr ready --undo'
mkdir -p "$tmp/bin"
ln -sf "$(command -v jq)" "$tmp/bin/jq"
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
    case "$*" in
      *isDraft*) echo "${MOCK_DRAFT:-false}" ;;
      *) echo "main" ;;
    esac
    ;;
  "pr ready")
    [[ "$*" != *"--undo"* || "${MOCK_UNDO_EXIT:-0}" -eq 0 ]] || exit "$MOCK_UNDO_EXIT"
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

# set_completion <repo> <status>: the implementer's completion record.
set_completion() {
  local remaining='[]'

  [[ "$2" == "complete" ]] || remaining='["Plan steps 3 to 9"]'
  mkdir -p "$1/.agents/completion"
  jq -n --arg status "$2" --argjson remaining "$remaining" '{
    schema: "completion/v1", status: $status,
    criteria: [{criterion: "The marker exists", status: "met", evidence: "feature.txt"}],
    remaining: $remaining
  }' >"$1/.agents/completion/12.json"
}

# Creates a clone on a committed feature branch of Issue 12, with a remote.
# The feature is complete: the commit says so, as finish-feature.sh writes
# it, and the completion record agrees. COMMITTED_COMPLETION sets another
# statement of the commit; 'none' leaves it out.
setup_repo() {
  local label="$1"
  local statement="Completion: ${COMMITTED_COMPLETION:-complete}"
  local remote="$tmp/$label-remote.git"
  local repo="$tmp/$label"

  git init -q --bare -b main "$remote"
  git clone -q "$remote" "$repo" 2>/dev/null
  mkdir -p "$repo/scripts/lib"
  cp "$source_root/scripts/publish-feature.sh" "$repo/scripts/"
  cp "$source_root/scripts/lib/github.sh" "$source_root/scripts/lib/completion.sh" "$repo/scripts/lib/"
  printf '.agents/manual-steps/\n.agents/completion/\n.agents/handoffs/\n' >"$repo/.gitignore"
  git -C "$repo" config user.name "Publish Test"
  git -C "$repo" config user.email "publish-test@example.com"
  git -C "$repo" checkout -q -b main
  git -C "$repo" add .
  git -C "$repo" commit -qm "Seed"
  git -C "$repo" push -q origin main
  git -C "$repo" checkout -q -b feature/12-marker
  printf 'marker\n' >"$repo/feature.txt"
  git -C "$repo" add feature.txt
  if [[ "${COMMITTED_COMPLETION:-}" == "none" ]]; then
    git -C "$repo" commit -qm "Add the marker" -m "Issue: #12" -m "Review: round 1, PASS, by claude (model-r)"
  else
    git -C "$repo" commit -qm "Add the marker" -m "Issue: #12" -m "$statement
- met: The marker exists (feature.txt)" -m "Review: round 1, PASS, by claude (model-r)"
  fi
  set_completion "$repo" complete
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
# commit message and the manual steps, and with --wait passing checks end
# successfully.
repo="$(setup_repo pass)"
mkdir -p "$repo/.agents/manual-steps"
printf -- '- Enable GitHub Pages under Settings, Pages.\n' >"$repo/.agents/manual-steps/12.md"
run_publish "$repo" 12 --wait || {
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
if grep -Fq "merge approval above was decided" "$repo.gh.body"; then
  fail "a commit without a decision of the gate got a commit for one"
fi
grep -Fq "pr checks feature/12-marker --watch" "$repo.gh" || fail "the checks were not awaited"
grep -Fq "All checks passed" "$repo.out" || fail "passing checks were not reported"
grep -Fq "https://github.com/example/project/pull/7" "$repo.out" || fail "the pull request was not named"
grep -Fq "Enable GitHub Pages" "$repo.out" || fail "the manual steps were not shown"
grep -Fq "./scripts/cleanup-worktree.sh 12" "$repo.out" || fail "the next step was not printed"
if grep -Eq "pr merge" "$repo.gh"; then fail "the pull request was merged"; fi
if grep -Fq -- "--draft" "$repo.gh"; then fail "the pull request of a complete feature was opened as a draft"; fi

# The pull request closes the Issue only when the completion gate passed:
# the commit says complete and the record still agrees. Everything else is a
# draft that refers to the Issue and says why it does not close it.
# expect_open <repo> <description> <reason>
expect_open() {
  if grep -Eiq '(^|[^[:alnum:]])(close[sd]?|fix(e[sd])?|resolve[sd]?):? +#12([^0-9]|$)' "$1.gh.body"; then
    cat "$1.gh.body" >&2
    fail "the Issue would be closed although $2"
  fi
  grep -Fqx "Issue #12 stays open after a merge of this pull request: $3." "$1.gh.body" ||
    fail "the description does not say why the Issue stays open although $2"
  grep -Fq -- "--draft" "$1.gh" || fail "the pull request is not a draft although $2"
  grep -Fq "Opened draft pull request" "$1.out" || fail "the draft was not announced although $2"
  grep -Fq "It does not close Issue #12: $3." "$1.out" || fail "the reason was not printed although $2"
}

repo="$(COMMITTED_COMPLETION=partial setup_repo partial)"
set_completion "$repo" partial
run_publish "$repo" 12 || fail "publishing partial work failed"
pushed "$repo" || fail "partial work was not pushed"
expect_open "$repo" "the feature was committed as partial" "the feature was committed as partial"
grep -Fqx "Completion: partial" "$repo.gh.body" || fail "the description of partial work does not carry the completion statement"

repo="$(COMMITTED_COMPLETION=none setup_repo no-statement)"
run_publish "$repo" 12 || fail "publishing a commit without a completion statement failed"
expect_open "$repo" "the commit has no completion statement" "the commit has no completion statement of finish-feature.sh"

# The gate is asked again: a commit that says complete does not close the
# Issue when the record is gone, says something else, or the handoff note
# lists remaining work.
repo="$(setup_repo record-gone)"
rm "$repo/.agents/completion/12.json"
run_publish "$repo" 12 || fail "publishing without a completion record failed"
expect_open "$repo" "the completion record is missing" "the commit says the feature is complete, but the completion gate does not pass now (missing)"

repo="$(setup_repo record-partial)"
set_completion "$repo" partial
run_publish "$repo" 12 || fail "publishing with a record that says partial failed"
expect_open "$repo" "the completion record says partial" "the commit says the feature is complete, but the completion gate does not pass now (partial)"

repo="$(setup_repo handoff-remaining)"
mkdir -p "$repo/.agents/handoffs"
printf 'Remaining: steps 3 to 9\n' >"$repo/.agents/handoffs/12.md"
run_publish "$repo" 12 || fail "publishing with remaining work in the handoff note failed"
expect_open "$repo" "the handoff note lists remaining work" "the commit says the feature is complete, but the completion gate does not pass now (partial)"

# A draft that was opened for partial work is marked ready once the feature
# is complete; an open pull request of work that is not complete stays as it
# is and gets the reason in its description.
repo="$(setup_repo draft-completed)"
MOCK_DRAFT=true MOCK_OPEN_PR="https://github.com/example/project/pull/3" run_publish "$repo" 12 ||
  fail "publishing a completed feature with an open draft failed"
grep -Fqx "Closes #12" "$repo.gh.body" || fail "the completed feature does not close the Issue"
grep -Fq "pr ready https://github.com/example/project/pull/3" "$repo.gh" || fail "the draft was not marked ready"

repo="$(setup_repo open-complete)"
MOCK_OPEN_PR="https://github.com/example/project/pull/3" run_publish "$repo" 12 || fail "publishing to an open pull request failed"
if grep -Fq "pr ready" "$repo.gh"; then fail "a pull request that is not a draft was marked ready"; fi

repo="$(COMMITTED_COMPLETION=partial setup_repo open-partial)"
set_completion "$repo" partial
MOCK_DRAFT=true MOCK_OPEN_PR="https://github.com/example/project/pull/3" run_publish "$repo" 12 ||
  fail "publishing partial work to an open draft failed"
if grep -Fq "Closes #12" "$repo.gh.body"; then fail "partial work closes the Issue through an open pull request"; fi
if grep -Fq "pr ready" "$repo.gh"; then fail "a draft of partial work was marked ready or converted again"; fi

# An open pull request that is ready for review goes back to a draft when the
# work published to it is not complete.
repo="$(COMMITTED_COMPLETION=partial setup_repo ready-to-partial)"
set_completion "$repo" partial
MOCK_DRAFT=false MOCK_OPEN_PR="https://github.com/example/project/pull/3" run_publish "$repo" 12 ||
  fail "publishing partial work to a ready pull request failed"
grep -Fq "pr ready https://github.com/example/project/pull/3 --undo" "$repo.gh" ||
  fail "a ready pull request with partial work was not converted to a draft"
grep -Fq "Converted it to a draft" "$repo.out" || fail "the conversion to a draft was not reported"
if grep -Fq "Closes #12" "$repo.gh.body"; then fail "partial work closes the Issue through a ready pull request"; fi
# The same when the gate does not pass any more for a commit that says complete.
repo="$(setup_repo ready-record-gone)"
rm "$repo/.agents/completion/12.json"
MOCK_OPEN_PR="https://github.com/example/project/pull/3" run_publish "$repo" 12 || fail "publishing without a record to a ready pull request failed"
grep -Fq "pr ready https://github.com/example/project/pull/3 --undo" "$repo.gh" ||
  fail "a ready pull request whose gate does not pass was not converted to a draft"
# When GitHub refuses the conversion, the run says so and the description
# still keeps the Issue open.
repo="$(COMMITTED_COMPLETION=partial setup_repo ready-undo-fails)"
set_completion "$repo" partial
MOCK_UNDO_EXIT=1 MOCK_OPEN_PR="https://github.com/example/project/pull/3" run_publish "$repo" 12 ||
  fail "a refused conversion to a draft failed the publication"
grep -Fq "could not convert https://github.com/example/project/pull/3 to a draft" "$repo.out" ||
  fail "the refused conversion to a draft was not reported"
grep -Fqx "Issue #12 stays open after a merge of this pull request: the feature was committed as partial." "$repo.gh.body" ||
  fail "the description does not keep the Issue open after a refused conversion"

# A closing keyword that the description takes over from the commit message
# or the manual steps becomes a reference when the gate did not pass.
repo="$(COMMITTED_COMPLETION=partial setup_repo keyword-in-steps)"
set_completion "$repo" partial
mkdir -p "$repo/.agents/manual-steps"
printf -- '- After the merge this fixes #12, close the milestone by hand.\n' >"$repo/.agents/manual-steps/12.md"
run_publish "$repo" 12 || fail "publishing partial work with a closing keyword in the manual steps failed"
if grep -Eiq '(^|[^[:alnum:]])(close[sd]?|fix(e[sd])?|resolve[sd]?):? +#12([^0-9]|$)' "$repo.gh.body"; then
  cat "$repo.gh.body" >&2
  fail "the description of partial work kept a closing keyword for the Issue"
fi
grep -Fq "this Refs #12, close the milestone by hand." "$repo.gh.body" || fail "the closing keyword was not turned into a reference"
# The sentence that the script adds itself names the Issue without a keyword.
grep -Fqx "Issue #12 stays open after a merge of this pull request: the feature was committed as partial." "$repo.gh.body" ||
  fail "the description does not say that the Issue stays open"

# GitHub closes an Issue from a merged commit message too, so work that may
# not close the Issue is not published while a commit of the branch says so.
# keyword_commit <label> <message>: a commit made by hand, without the
# completion statement of finish-feature.sh.
keyword_commit() {
  local repo

  repo="$(COMMITTED_COMPLETION=none setup_repo "$1")"
  printf 'more\n' >>"$repo/feature.txt"
  git -C "$repo" commit -qam "Finish the marker" -m "$2"
  printf '%s\n' "$repo"
}
for keyword in "Closes #12" "closes: #12" "This fixes #12." "Resolved example/project#12" \
  "Fixed https://github.com/example/project/issues/12"; do
  keyword_count=$((${keyword_count:-0} + 1))
  repo="$(keyword_commit "keyword-commit-$keyword_count" "$keyword")"
  if run_publish "$repo" 12; then
    cat "$repo.out" >&2
    fail "a commit without a completion statement that says '$keyword' was published"
  fi
  pushed "$repo" && fail "a commit that would close the Issue was pushed: $keyword"
  if grep -Eq "pr (create|edit)" "$repo.gh" 2>/dev/null; then fail "a pull request was opened for a commit that says '$keyword'"; fi
  grep -Fq "a commit of the branch says that it does" "$repo.out" || fail "the closing commit was not given as the reason: $keyword"
  grep -Fq "Finish the marker" "$repo.out" || fail "the closing commit was not named: $keyword"
  grep -Fq "Nothing was pushed" "$repo.out" || fail "the refusal does not say that nothing was pushed: $keyword"
done
# An earlier commit of the branch counts as well, not only the latest.
repo="$(keyword_commit keyword-earlier "Closes #12")"
printf 'again\n' >>"$repo/feature.txt"
git -C "$repo" commit -qam "One more change" -m "Refs #12"
if run_publish "$repo" 12; then fail "an earlier commit that closes the Issue was published"; fi
grep -Fq "Finish the marker" "$repo.out" || fail "the earlier closing commit was not named"
# A keyword for another Issue, or no keyword, does not stop the publication.
for harmless in "Closes #123" "Refs #12" "This encloses #12" "Fixes #1"; do
  harmless_count=$((${harmless_count:-0} + 1))
  repo="$(keyword_commit "keyword-harmless-$harmless_count" "$harmless")"
  run_publish "$repo" 12 || {
    cat "$repo.out" >&2
    fail "a commit that says '$harmless' was refused"
  }
  expect_open "$repo" "the commit has no completion statement" "the commit has no completion statement of finish-feature.sh"
done
# A complete feature may say that it closes its Issue.
repo="$(setup_repo keyword-complete)"
printf 'more\n' >>"$repo/feature.txt"
git -C "$repo" commit -qam "Finish the marker" -m "Completion: complete" -m "Closes #12"
run_publish "$repo" 12 || fail "a complete feature whose commit closes its Issue was refused"
grep -Fqx "Closes #12" "$repo.gh.body" || fail "a complete feature does not close its Issue"

# Without manual steps the description says so.
repo="$(setup_repo no-steps)"
run_publish "$repo" 12 || fail "publishing a feature without manual steps failed"
grep -A2 -Fx "## Manual steps" "$repo.gh.body" | grep -Fqx "None." ||
  fail "the description does not say that there are no manual steps"

# With --wait a failing check fails the run and tells the user not to merge.
repo="$(setup_repo checks-fail)"
if MOCK_CHECKS=fail run_publish "$repo" 12 --wait; then fail "a failed check returned success"; fi
grep -Fq "Do not merge" "$repo.out" || fail "a failed check did not warn against merging"
if grep -Fq "All checks passed" "$repo.out"; then fail "a failed check was reported as passed"; fi

# A repository without checks is reported as unverified, not as passed.
repo="$(setup_repo no-checks)"
MOCK_CHECKS=none run_publish "$repo" 12 --wait || fail "a pull request without checks failed the run"
grep -Fq "No checks were reported" "$repo.out" || fail "missing checks were not reported"
if grep -Fq "All checks passed" "$repo.out"; then fail "missing checks were reported as passed"; fi
if grep -Fq -- "--watch" "$repo.gh"; then fail "checks that never started were awaited"; fi

# An open pull request is reused and gets the current description, so manual
# steps that a fix round changed are not left outdated. --no-wait, from before
# waiting became optional, is still accepted.
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

# Without --wait the script ends once the pull request is open, whatever the
# checks do, and names the pull request and the next step.
repo="$(setup_repo no-wait-default)"
MOCK_REQUIRED=1 MOCK_CHECKS=fail run_publish "$repo" 12 || {
  cat "$repo.out" >&2
  fail "publishing without waiting failed"
}
grep -Fq "pr create" "$repo.gh" || fail "the pull request was not opened"
if grep -Fq "pr checks" "$repo.gh"; then fail "the script waited for the checks without --wait"; fi
grep -Fq "https://github.com/example/project/pull/7" "$repo.out" || fail "the pull request was not named"
grep -Fq "requires a passing status check" "$repo.out" || fail "the required check was not mentioned"
if grep -Fq "Warning" "$repo.out"; then fail "a protected base branch gave a warning"; fi
grep -Fq "./scripts/cleanup-worktree.sh 12" "$repo.out" || fail "the next step was not printed"

# A base branch without a required check lets a failing pull request be
# merged, so the script warns; it still does not wait.
repo="$(setup_repo unprotected)"
MOCK_REQUIRED=0 run_publish "$repo" 12 || fail "publishing to an unprotected branch failed"
grep -Fq "Warning: branch 'main' does not require a passing status check" "$repo.out" ||
  fail "the unprotected base branch was not reported"
if grep -Fq "pr checks" "$repo.gh"; then fail "the script waited for the checks without --wait"; fi

# Rules that cannot be read give neither a claim nor a warning.
repo="$(setup_repo rules-unreadable)"
MOCK_REQUIRED=unreadable run_publish "$repo" 12 || fail "publishing with unreadable rules failed"
if grep -Fq "Warning" "$repo.out" || grep -Fq "requires a passing status check" "$repo.out"; then
  fail "unreadable rules were reported as known"
fi

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

# The decision of the merge approval gate is in the commit message; the pull
# request names the commit it was made for, so it cannot be read as covering
# a later one.
repo="$(setup_repo approval)"
git -C "$repo" commit -q --amend -m "Add the marker" -m "Merge approval:" -m "- required from the project owner, for exactly this commit"
run_publish "$repo" 12 || fail "publishing a feature that needs approval failed"
grep -Fqx -- "- required from the project owner, for exactly this commit" "$repo.gh.body" ||
  fail "the pull request does not show that the owner must approve"
grep -Fqx "The merge approval above was decided for commit \`$(git -C "$repo" rev-parse HEAD)\`." "$repo.gh.body" ||
  fail "the pull request does not name the commit the decision was made for"

echo "publish-feature tests passed"
