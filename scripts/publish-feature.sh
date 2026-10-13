#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 <issue-number> [--wait]"
  echo
  echo "Run in the feature worktree after finish-feature.sh. Pushes the branch and"
  echo "opens the pull request. The description is the latest commit message and"
  echo "the manual steps; an open pull request gets it again, replacing its"
  echo "description. It never merges."
  echo
  echo "The pull request closes the Issue only when the feature is complete: the"
  echo "commit carries 'Completion: complete' of finish-feature.sh and the"
  echo "completion gate still passes. Otherwise it is opened as a draft that"
  echo "refers to the Issue and says why it does not close it."
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
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/completion.sh"
command -v jq >/dev/null 2>&1 || fail "jq is required."

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

# Whether this pull request may close the Issue. finish-feature.sh recorded
# the outcome of the completion gate in the commit; the gate is asked again
# here, because the pull request is what closes the Issue on a merge. A
# commit without the statement, for example one made by hand, closes nothing.
committed_completion="$(git -C "$root" log -1 --format=%b | sed -n 's/^Completion: //p' | sed -n 1p)"
gate="$(completion_gate "$root" "$issue")"
gate_status="$(printf '%s\n' "$gate" | sed -n 1p)"
closes=0
if [[ "$committed_completion" == "complete" && "$gate_status" == "complete" ]]; then
  closes=1
elif [[ "$committed_completion" == "complete" ]]; then
  not_closing="the commit says the feature is complete, but the completion gate does not pass now ($gate_status)"
elif [[ -n "$committed_completion" ]]; then
  not_closing="the feature was committed as $committed_completion"
else
  not_closing="the commit has no completion statement of finish-feature.sh"
fi

# GitHub also closes an Issue from the message of a commit that reaches the
# default branch, whatever the pull request says. Work that may not close the
# Issue is therefore not published while a commit of the branch carries a
# closing keyword for it: nothing here can take that back after a merge.
if [[ "$closes" -eq 0 ]]; then
  feature_base="$(git -C "$root" config --get "branch.$branch.workflow-base" || true)"
  feature_base="${feature_base:-main}"
  commit_range="HEAD -1"
  for candidate in "origin/$feature_base" "$feature_base"; do
    if git -C "$root" rev-parse --verify --quiet "$candidate^{commit}" >/dev/null; then
      commit_range="$candidate..HEAD"
      break
    fi
  done
  # shellcheck disable=SC2086
  closing_commits="$(git -C "$root" log --format='%h%x09%s%x09%B%x00' $commit_range |
    tr '\n' ' ' | tr '\0' '\n' | sed 's/^ *//' |
    grep -Ei "$(completion_closing_pattern "$issue")" | cut -f1,2 | tr '\t' ' ' || true)"
  if [[ -n "$closing_commits" ]]; then
    echo "Error: this work may not close Issue #$issue ($not_closing), but a commit of the branch says that it does:" >&2
    printf '%s\n' "$closing_commits" | sed 's/^/  /' >&2
    echo "GitHub closes the Issue when such a commit is merged, whatever the pull request says." >&2
    echo "Reword the commit (for example 'Refs #$issue'), or complete the feature and commit it with ./scripts/finish-feature.sh. Nothing was pushed." >&2
    exit 1
  fi
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
# closing_allowed: copies standard input; in a description that may not close
# the Issue, a closing keyword for it becomes a reference.
closing_allowed() {
  if [[ "$closes" -eq 1 ]]; then
    cat
  else
    completion_neutralize_closing "$issue"
  fi
}
{
  git -C "$root" log -1 --format=%b | closing_allowed
  echo
  echo "## Manual steps"
  echo
  printf '%s\n' "${manual_steps:-None.}" | closing_allowed
  echo
  # The decision of the merge approval gate was made for this commit; a
  # later commit on the branch needs a new decision by finish-feature.sh.
  if git -C "$root" log -1 --format=%b | grep -Fqx "Merge approval:"; then
    echo "The merge approval above was decided for commit \`$(git -C "$root" rev-parse HEAD)\`."
    echo
  fi
  if [[ "$closes" -eq 1 ]]; then
    echo "Closes #$issue"
  else
    # Worded without a closing keyword next to the number: GitHub would
    # follow "does not close #<issue>" too.
    echo "Issue #$issue stays open after a merge of this pull request: $not_closing."
  fi
} >"$body"

if [[ -n "$url" ]]; then
  echo "Pull request already open: $url"
  gh pr edit "$url" --body-file "$body" >/dev/null ||
    fail "could not update the description of $url. The branch is pushed."
  echo "Updated its description from the latest commit."
  is_draft="$(gh pr view "$url" --json isDraft --jq '.isDraft' 2>/dev/null)" || is_draft=""
  if [[ "$closes" -eq 1 && "$is_draft" == "true" ]]; then
    # Opened as a draft for partial work that is complete now.
    gh pr ready "$url" >/dev/null ||
      echo "Warning: could not mark $url as ready for review; do that on GitHub." >&2
  elif [[ "$closes" -eq 0 && "$is_draft" != "true" ]]; then
    # A pull request that is ready for review, with work that is not
    # complete: back to a draft, so that it is not merged as a finished
    # feature. When that fails, the description still says that the Issue
    # stays open, and the script says so.
    if gh pr ready "$url" --undo >/dev/null; then
      echo "Converted it to a draft: the work is not complete."
    else
      echo "Warning: could not convert $url to a draft; do that on GitHub. Its description says that it does not close Issue #$issue." >&2
    fi
  fi
else
  create_options=()
  [[ "$closes" -eq 1 ]] || create_options=(--draft)
  url="$(gh pr create --head "$branch" --title "$(git -C "$root" log -1 --format=%s)" --body-file "$body" ${create_options[@]+"${create_options[@]}"})" ||
    fail "could not open the pull request. The branch is pushed; open it by hand, with 'Closes #$issue' in its description only when the feature is complete."
  url="$(printf '%s\n' "$url" | tail -n 1)"
  if [[ "$closes" -eq 1 ]]; then
    echo "Opened pull request: $url"
  else
    echo "Opened draft pull request: $url"
  fi
fi
if [[ "$closes" -eq 0 ]]; then
  echo "It does not close Issue #$issue: $not_closing."
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
