#!/usr/bin/env bash

set -euo pipefail

# The arguments as given, for a run that records itself (lib/records.sh).
records_arguments=("$@")

usage() {
  echo "Usage: $0 <issue-number> [--wait] [--summary]"
  echo
  echo "Run in the feature worktree after finish-feature.sh. Pushes the branch and"
  echo "opens the pull request. The description is the message of the commit that"
  echo "finish-feature.sh made, also after the base branch was merged into the"
  echo "feature to bring it up to date, and the manual steps; an open pull request"
  echo "gets it again, replacing its description. It never merges."
  echo
  echo "The pull request closes the Issue only when the feature is complete: the"
  echo "commit carries 'Completion: complete' of finish-feature.sh and the"
  echo "completion gate still passes. A feature that awaits evidence of a later gate"
  echo "('Completion: awaiting_evidence') is published for review as well; it closes"
  echo "the Issue unless evidence of the post_merge gate is pending, which"
  echo "record-post-merge.sh records after the merge. Otherwise the pull request is"
  echo "opened as a draft that refers to the Issue and says why it does not close it."
  echo
  echo "The script ends once the pull request is open; follow its checks on the pull"
  echo "request page and merge after they passed. It warns when the base branch does"
  echo "not require a passing status check, since GitHub then allows a merge while a"
  echo "check fails. --wait stays until the checks finish and reports the result: it"
  echo "exits 0 when they pass and 1 when one fails."
  echo
  echo "--summary also posts the totals of the run records on the Issue: the elapsed"
  echo "time, the runs, the review and repair rounds, and the tokens per role and"
  echo "model; no log, no paths, no times of day. It is one comment, replaced when"
  echo "the feature is published again. Off by default; a failure only warns."
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

[[ $# -ge 1 ]] || usage
issue="$1"
shift
wait_for_checks=0
summary_wanted=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait) wait_for_checks=1 ;;
    # Accepted for commands written before waiting became optional.
    --no-wait) ;;
    --summary) summary_wanted=1 ;;
    *) usage ;;
  esac
  shift
done

[[ "$issue" =~ ^[0-9]+$ ]] || fail "issue number must be numeric: $issue"
command -v gh >/dev/null 2>&1 || fail "GitHub CLI 'gh' is not installed."
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/github.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/completion.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/records.sh"
records_wrap feature "$issue" "$0" ${records_arguments[@]+"${records_arguments[@]}"}
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

# The base branch of the feature, as start-feature.sh recorded it.
feature_base="$(git -C "$root" config --get "branch.$branch.workflow-base" || true)"
feature_base="${feature_base:-main}"
base_ref=""
for candidate in "origin/$feature_base" "$feature_base"; do
  if git -C "$root" rev-parse --verify --quiet "$candidate^{commit}" >/dev/null; then
    base_ref="$candidate"
    break
  fi
done

# The commit that finish-feature.sh made. Bringing a finished feature up to
# date with its base merges the base into the branch; such merge commits
# change nothing of the feature itself and come after the finish commit, so
# the statement, the description, and the title are taken from the commit
# before them. Any other commit after the finish needs a new finish.
# in_base <commit>: whether the commit is in the base, local or on the remote,
# whichever is ahead.
in_base() {
  local candidate

  for candidate in "origin/$feature_base" "$feature_base"; do
    git -C "$root" rev-parse --verify --quiet "$candidate^{commit}" >/dev/null || continue
    git -C "$root" merge-base --is-ancestor "$1" "$candidate" 2>/dev/null && return 0
  done
  return 1
}
# A merge of the base has exactly two parents: the feature, and a commit of
# the base. A merge with more parents brings in something else too.
finish_commit="$(git -C "$root" rev-parse HEAD)"
while second_parent="$(git -C "$root" rev-parse --verify --quiet "$finish_commit^2" 2>/dev/null)" &&
  ! git -C "$root" rev-parse --verify --quiet "$finish_commit^3" >/dev/null 2>&1 &&
  in_base "$second_parent"; do
  finish_commit="$(git -C "$root" rev-parse "$finish_commit^1")"
done
if [[ "$finish_commit" != "$(git -C "$root" rev-parse HEAD)" ]]; then
  echo "The branch merged its base after the feature was finished; the pull request is described by the finish commit $(git -C "$root" rev-parse --short "$finish_commit")."
fi

# Whether this pull request may close the Issue. finish-feature.sh recorded
# the outcome of the completion gate in the commit; the gate is asked again
# here, because the pull request is what closes the Issue on a merge. A
# commit without the statement, for example one made by hand, closes nothing.
committed_completion="$(git -C "$root" log -1 --format=%b "$finish_commit" | sed -n 's/^Completion: //p' | sed -n 1p)"
gate="$(completion_gate "$root" "$issue")"
gate_status="$(printf '%s\n' "$gate" | sed -n 1p)"
closes=0
# ready: the pull request is for review, not a draft. closes: it also closes
# the Issue on a merge. They differ for a feature that awaits evidence of the
# post_merge gate: it is ready, but the Issue stays open until that evidence
# is recorded (record-post-merge.sh).
ready=0
if [[ "$committed_completion" == "complete" && "$gate_status" == "complete" ]]; then
  ready=1
  closes=1
elif [[ "$committed_completion" == "awaiting_evidence" && "$gate_status" == "awaiting_evidence" ]] &&
  ! diff -q <(git -C "$root" log -1 --format=%b "$finish_commit" | grep -E -- "^(- pending at (post_merge|owner_approval): |Post-merge criterion: )" | sort) \
    <(completion_commit_lines "$root" "$issue" | grep -E -- "^(- pending at (post_merge|owner_approval): |Post-merge criterion: )" | sort) >/dev/null; then
  # The pull request states, and record-post-merge.sh reads after the merge,
  # the post_merge evidence of the finish commit, and the finish commit
  # decided whether the merge needs the owner (a pending owner_approval
  # criterion makes it need the owner). A record edited since then may
  # differ: only a new finish may change what the pull request states.
  not_closing="the commit and the completion record disagree on the pending post_merge or owner_approval evidence; run ./scripts/finish-feature.sh again so that the commit states it"
elif [[ "$committed_completion" == "awaiting_evidence" && "$gate_status" == "awaiting_evidence" ]]; then
  ready=1
  pending_gates="$(completion_pending_gates "$root" "$issue" | paste -sd, - | sed 's/,/, /g')"
  if completion_pending_gates "$root" "$issue" | grep -qx "post_merge"; then
    not_closing="evidence of the post_merge gate is pending; record it with ./scripts/record-post-merge.sh after the merge (pending: $pending_gates)"
  else
    closes=1
  fi
elif [[ "$committed_completion" == "awaiting_evidence" && "$gate_status" == "complete" ]]; then
  # A record changed after the finish commit could claim evidence of the
  # post_merge gate before the merge: only a new finish may say so.
  not_closing="the commit says the feature awaits evidence, but the completion record says complete now; run ./scripts/finish-feature.sh again so that the commit states it"
elif [[ "$committed_completion" == "complete" && "$gate_status" == "awaiting_evidence" ]]; then
  not_closing="the commit says the feature is complete, but the completion record awaits evidence now, which is weaker; run ./scripts/finish-feature.sh again so that the commit states it"
elif [[ "$committed_completion" == "complete" || "$committed_completion" == "awaiting_evidence" ]]; then
  not_closing="the commit says the feature is $committed_completion, but the completion gate does not pass now ($gate_status)"
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
  commit_range="HEAD -1"
  [[ -z "$base_ref" ]] || commit_range="$base_ref..HEAD"
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

# The description is generated from the finish commit and the current manual
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
  git -C "$root" log -1 --format=%b "$finish_commit" | closing_allowed
  echo
  echo "## Manual steps"
  echo
  printf '%s\n' "${manual_steps:-None.}" | closing_allowed
  echo
  # The decision of the merge approval gate was made for this commit; a
  # later commit on the branch needs a new decision by finish-feature.sh.
  if git -C "$root" log -1 --format=%b "$finish_commit" | grep -Fqx "Merge approval:"; then
    echo "The merge approval above was decided for commit \`$finish_commit\`."
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
  echo "Updated its description from the finish commit."
  is_draft="$(gh pr view "$url" --json isDraft --jq '.isDraft' 2>/dev/null)" || is_draft=""
  if [[ "$ready" -eq 1 && "$is_draft" == "true" ]]; then
    # Opened as a draft for partial work that is complete now.
    gh pr ready "$url" >/dev/null ||
      echo "Warning: could not mark $url as ready for review; do that on GitHub." >&2
  elif [[ "$ready" -eq 0 && "$is_draft" != "true" ]]; then
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
  [[ "$ready" -eq 1 ]] || create_options=(--draft)
  url="$(gh pr create --head "$branch" --title "$(git -C "$root" log -1 --format=%s "$finish_commit")" --body-file "$body" ${create_options[@]+"${create_options[@]}"})" ||
    fail "could not open the pull request. The branch is pushed; open it by hand, with 'Closes #$issue' in its description only when the feature is complete."
  url="$(printf '%s\n' "$url" | tail -n 1)"
  if [[ "$ready" -eq 1 ]]; then
    echo "Opened pull request: $url"
  else
    echo "Opened draft pull request: $url"
  fi
fi
if [[ "$closes" -eq 0 ]]; then
  echo "It does not close Issue #$issue: $not_closing."
fi
echo

# The runs of the feature together in the primary checkout
# (.agents/records/), also those of this publication, which is still running.
if ! records_consolidate feature "$issue"; then
  echo "Warning: the run records of Issue #$issue could not be copied to .agents/records/; cleanup-worktree.sh tries again." >&2
fi

# post_summary: the totals of the run records as one comment on the Issue,
# replacing the one of an earlier publication. Only report-runs.sh
# --github-summary writes its text, from numeric fields. A failure warns and
# changes nothing else.
post_summary() {
  local summary
  local comment

  summary="$(mktemp "${TMPDIR:-/tmp}/run-summary.XXXXXX")" || return 1
  if ! "$root/scripts/report-runs.sh" --github-summary "$issue" >"$summary"; then
    rm -f "$summary"
    return 1
  fi
  comment="$(gh api "repos/{owner}/{repo}/issues/$issue/comments" --paginate \
    --jq '.[] | select(.body | startswith("<!-- run-records-summary -->")) | .id' | head -n 1)" || {
    rm -f "$summary"
    return 1
  }
  if [[ -n "$comment" ]]; then
    gh api --method PATCH "repos/{owner}/{repo}/issues/comments/$comment" -F "body=@$summary" >/dev/null || {
      rm -f "$summary"
      return 1
    }
    echo "Replaced the run summary on Issue #$issue."
  else
    gh issue comment "$issue" --body-file "$summary" >/dev/null || {
      rm -f "$summary"
      return 1
    }
    echo "Posted the run summary on Issue #$issue."
  fi
  rm -f "$summary"
}

if [[ "$summary_wanted" -eq 1 ]] && ! post_summary; then
  echo "Warning: the run summary could not be posted on Issue #$issue; the pull request is published." >&2
fi

# print_post_merge_hint: a feature that awaits evidence of the post_merge gate
# leaves its Issue open; say what closes it.
print_post_merge_hint() {
  [[ "$ready" -eq 1 && "$closes" -eq 0 ]] || return 0
  completion_pending_gates "$root" "$issue" | grep -qx "post_merge" || return 0
  echo
  echo "After the merge, record the post_merge evidence with"
  echo "  ./scripts/record-post-merge.sh $issue \"<criterion>\" \"<evidence>\""
  echo "The Issue is closed when none is left."
}

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
  print_post_merge_hint
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
  print_post_merge_hint
  echo
  echo "After the merge, from the primary checkout:"
  echo "  ./scripts/cleanup-worktree.sh $issue"
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
print_post_merge_hint
echo
echo "After the merge, from the primary checkout:"
echo "  ./scripts/cleanup-worktree.sh $issue"
