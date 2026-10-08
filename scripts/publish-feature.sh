#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 <issue-number> [--wait]"
  echo
  echo "Run in the feature worktree after finish-feature.sh. Pushes the branch and"
  echo "opens the pull request that closes the Issue. The description is the latest"
  echo "commit message and the manual steps; an open pull request gets it again,"
  echo "replacing its description. It never merges."
  echo
  echo "The script ends once the pull request is open; follow its checks on the pull"
  echo "request page and merge after they passed. It warns when the base branch does"
  echo "not require a passing status check, since GitHub then allows a merge while a"
  echo "check fails. --wait stays until the checks finish and reports the result: it"
  echo "exits 0 when they pass and 1 when one fails."
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

# --no-wait is accepted for commands written before waiting became optional.
[[ $# -eq 1 || ( $# -eq 2 && ( "$2" == "--wait" || "$2" == "--no-wait" ) ) ]] || usage
issue="$1"
wait_for_checks=0
[[ "${2:-}" != "--wait" ]] || wait_for_checks=1

[[ "$issue" =~ ^[0-9]+$ ]] || fail "issue number must be numeric: $issue"
command -v gh >/dev/null 2>&1 || fail "GitHub CLI 'gh' is not installed."
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/github.sh"

root="$(git rev-parse --show-toplevel)"
branch="$(git branch --show-current)"
[[ "$branch" == feature/${issue}-* ]] ||
  fail "publish-feature.sh must run on feature/${issue}-*. Current branch: $branch"
[[ -z "$(git -C "$root" status --porcelain)" ]] ||
  fail "there are uncommitted changes. Commit the feature first: ./scripts/finish-feature.sh $issue \"<commit summary>\""

# The steps the implementer recorded for the human; finish-feature.sh put the
# same steps in the commit message.
manual_steps=""
manual_file="$root/.agents/manual-steps/$issue.md"
if [[ -f "$manual_file" ]] && grep -q '[^[:space:]]' "$manual_file"; then
  manual_steps="$(grep '[^[:space:]]' "$manual_file")"
fi

echo "Pushing $branch..."
git -C "$root" push -u origin "$branch" || fail "could not push $branch."
echo

url="$(gh pr list --head "$branch" --state open --json url --jq '.[0].url // empty')" ||
  fail "could not ask GitHub for the pull request of $branch."

# The description is generated from the latest commit and the current manual
# steps, also for a pull request that is already open: a fix round can change
# both.
body="$(mktemp "${TMPDIR:-/tmp}/publish-feature-body.XXXXXX")"
trap 'rm -f "$body"' EXIT
{
  git -C "$root" log -1 --format=%b
  echo
  echo "## Manual steps"
  echo
  printf '%s\n' "${manual_steps:-None.}"
  echo
  echo "Closes #$issue"
} >"$body"

if [[ -n "$url" ]]; then
  echo "Pull request already open: $url"
  gh pr edit "$url" --body-file "$body" >/dev/null ||
    fail "could not update the description of $url. The branch is pushed."
  echo "Updated its description from the latest commit."
else
  url="$(gh pr create --head "$branch" --title "$(git -C "$root" log -1 --format=%s)" --body-file "$body")" ||
    fail "could not open the pull request. The branch is pushed; open it by hand with 'Closes #$issue' in its description."
  url="$(printf '%s\n' "$url" | tail -n 1)"
  echo "Opened pull request: $url"
fi
echo

print_manual_steps() {
  [[ -n "$manual_steps" ]] || return 0
  echo
  echo "This feature needs these manual steps from you:"
  printf '%s\n' "$manual_steps" | sed 's/^/  /'
}

if [[ "$wait_for_checks" -eq 0 ]]; then
  # The checks are followed on the pull request. Whether GitHub also refuses
  # a merge while one fails depends on the base branch, so say which it is.
  base_branch="$(gh pr view "$url" --json baseRefName --jq '.baseRefName' 2>/dev/null)" || base_branch=""
  required=""
  [[ -z "$base_branch" ]] || required="$(github_required_checks "$base_branch")"

  echo "Follow the checks on the pull request, and merge it after they passed:"
  echo "  $url"
  if [[ "$required" =~ ^[0-9]+$ && "$required" -gt 0 ]]; then
    echo "Branch '$base_branch' requires a passing status check, so GitHub refuses the merge"
    echo "while a check fails."
  elif [[ "$required" == "0" ]]; then
    echo
    echo "Warning: branch '$base_branch' does not require a passing status check, so GitHub" >&2
    echo "lets you merge while a check fails. Look at the checks before you merge, or add" >&2
    echo "the rule: docs/repository-setup.md." >&2
  fi
  print_manual_steps
  echo
  echo "After the merge, from the primary checkout:"
  echo "  ./scripts/cleanup-worktree.sh $issue"
  exit 0
fi

# Checks appear some time after the push. Without any after the grace period,
# the repository has no CI for pull requests.
poll="${PUBLISH_POLL_SECONDS:-5}"
attempts="${PUBLISH_START_ATTEMPTS:-12}"
started=0
echo "Waiting for the checks to start..."
for ((attempt = 1; attempt <= attempts; attempt++)); do
  if output="$(gh pr checks "$branch" 2>&1)" || [[ "$output" != *"no checks reported"* ]]; then
    started=1
    break
  fi
  sleep "$poll"
done

if [[ "$started" -eq 0 ]]; then
  echo "No checks were reported for the pull request. Nothing verified it on GitHub."
  echo "Review it before merging: $url"
  print_manual_steps
  exit 0
fi

status=0
gh pr checks "$branch" --watch --interval "${PUBLISH_WATCH_SECONDS:-15}" || status=$?
echo
if [[ "$status" -ne 0 ]]; then
  echo "Error: a check of the pull request failed or did not finish. Do not merge it." >&2
  echo "  See which check failed, with its link:  gh pr checks $branch" >&2
  echo "  Fix it in this worktree, then review, finish, and publish again." >&2
  exit 1
fi

echo "All checks passed. The pull request is ready for you to merge:"
echo "  $url"
print_manual_steps
echo
echo "After the merge, from the primary checkout:"
echo "  ./scripts/cleanup-worktree.sh $issue"
