#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 <issue-number> [--wait | --no-wait]"
  echo
  echo "Run in the feature worktree after finish-feature.sh. Pushes the branch and"
  echo "opens the pull request that closes the Issue. The description is the latest"
  echo "commit message and the manual steps; an open pull request gets it again,"
  echo "replacing its description. It never merges."
  echo
  echo "When the base branch requires a passing status check, GitHub refuses a merge"
  echo "while a check fails, so the script stops once the pull request is open."
  echo "Otherwise it waits for the checks, so that a failure is seen before the"
  echo "merge: it exits 0 when they pass and 1 when one fails. --wait always waits;"
  echo "--no-wait never does."
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

[[ $# -eq 1 || ( $# -eq 2 && ( "$2" == "--no-wait" || "$2" == "--wait" ) ) ]] || usage
issue="$1"
# 'auto' waits unless the base branch requires a passing status check.
wait_mode="auto"
case "${2:-}" in
  --wait) wait_mode="yes" ;;
  --no-wait) wait_mode="no" ;;
esac

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

if [[ "$wait_mode" == "auto" ]]; then
  # Waiting shows a failed check before the merge. A base branch that requires
  # a passing check makes GitHub refuse that merge, so the wait adds nothing.
  base_branch="$(gh pr view "$url" --json baseRefName --jq '.baseRefName' 2>/dev/null)" || base_branch=""
  required=""
  [[ -z "$base_branch" ]] || required="$(github_required_checks "$base_branch")"
  if [[ "$required" =~ ^[0-9]+$ && "$required" -gt 0 ]]; then
    echo "Branch '$base_branch' requires a passing status check, so GitHub refuses a merge"
    echo "while a check fails. Not waiting for the checks; follow them with:"
    echo "  gh pr checks $branch --watch"
    echo "The pull request: $url"
    print_manual_steps
    echo
    echo "After the merge, from the primary checkout:"
    echo "  ./scripts/cleanup-worktree.sh $issue"
    exit 0
  fi
  if [[ "$required" == "0" ]]; then
    echo "Branch '$base_branch' does not require a status check, so nothing stops a merge"
    echo "while a check fails. Waiting for the checks; see docs/repository-setup.md."
  else
    echo "Could not read whether the base branch requires a status check; waiting for the checks."
  fi
  echo
elif [[ "$wait_mode" == "no" ]]; then
  echo "Not waiting for the checks. Merge only after they pass:"
  echo "  gh pr checks $branch --watch"
  print_manual_steps
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
