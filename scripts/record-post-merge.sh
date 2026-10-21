#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 <issue-number> \"<criterion>\" \"<evidence>\""
  echo
  echo "Records the evidence of a post_merge criterion after the pull request of the"
  echo "feature was merged. A feature that was published as 'awaiting_evidence' lists"
  echo "such criteria in its pull request; the Issue stays open until each has its"
  echo "evidence."
  echo
  echo "<criterion> is the text of a pending post_merge criterion of the merged pull"
  echo "request. <evidence> names what shows it: a command and its result, a link, a"
  echo "check of the merged default branch. The script posts both as a comment on the"
  echo "Issue and closes the Issue when no post_merge criterion is pending any more."
  echo "No pull request and no review round is needed; the comments are the audit"
  echo "trail. Run from any checkout."
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

[[ $# -eq 3 ]] || usage
issue="$1"
criterion="$2"
evidence="$3"
marker="<!-- post-merge-evidence -->"

[[ "$issue" =~ ^[0-9]+$ ]] || fail "issue number must be numeric: $issue"
[[ "$criterion" =~ [^[:space:]] ]] || fail "the criterion is empty."
[[ "$evidence" =~ [^[:space:]] ]] || fail "the evidence is empty: say what shows the criterion."
[[ "$criterion" != *$'\n'* ]] || fail "the criterion must be one line, as the pull request lists it."
command -v gh >/dev/null 2>&1 || fail "GitHub CLI 'gh' is not installed."
command -v jq >/dev/null 2>&1 || fail "jq is required."

# The merged pull request of the feature lists what is pending. A pull request
# that is not merged yet has no post-merge evidence to record.
pull_requests="$(gh pr list --state merged --limit 1000 --json number,headRefName,body)" ||
  fail "could not ask GitHub for the merged pull requests."
body="$(printf '%s' "$pull_requests" | jq -r --arg prefix "feature/$issue-" '
  [.[] | select(.headRefName | startswith($prefix))] | sort_by(.number) | last | .body // empty' | tr -d '\r')"
[[ -n "$body" ]] || fail "no merged pull request of feature/$issue-* was found. Merge it first."

# finish-feature.sh wrote one line per pending post_merge criterion into the
# commit message that the pull request description repeats:
#   Post-merge criterion: "<criterion, as a JSON string>"
# The criterion is a JSON string so that it is exact: parentheses, quotes, or
# a criterion that begins like another cannot make two criteria look alike.
criteria_lines="$(printf '%s\n' "$body" | sed -n 's/^Post-merge criterion: //p')"
[[ -n "$criteria_lines" ]] || fail "the merged pull request lists no pending post_merge criterion."

pending=""
while IFS= read -r line; do
  decoded="$(printf '%s' "$line" | jq -r 'if type == "string" and length > 0 then . else empty end' 2>/dev/null)" || decoded=""
  [[ -n "$decoded" ]] || fail "the merged pull request holds a 'Post-merge criterion:' line that is not a JSON string: $line"
  pending+="$decoded"$'\n'
done <<<"$criteria_lines"
pending="${pending%$'\n'}"

if ! printf '%s\n' "$pending" | grep -Fqx -- "$criterion"; then
  echo "Error: that is not a pending post_merge criterion of the merged pull request. They are:" >&2
  printf '%s\n' "$pending" | sed 's/^/  /' >&2
  exit 1
fi

recorded="$(gh api "repos/{owner}/{repo}/issues/$issue/comments" --paginate \
  --jq ".[] | select(.body | startswith(\"$marker\")) | .body | split(\"\\n\") | map(select(startswith(\"Criterion: \"))) | first // empty | .[11:]")" ||
  fail "could not read the comments of Issue #$issue."
if printf '%s\n' "$recorded" | grep -Fqx -- "$criterion"; then
  fail "the evidence of this criterion is recorded already on Issue #$issue."
fi

comment="$(mktemp "${TMPDIR:-/tmp}/post-merge-evidence.XXXXXX")"
trap 'rm -f "$comment"' EXIT
{
  echo "$marker"
  echo "Post-merge evidence (recorded by record-post-merge.sh)"
  echo
  echo "Criterion: $criterion"
  echo
  echo "Evidence: $evidence"
} >"$comment"
gh issue comment "$issue" --body-file "$comment" >/dev/null ||
  fail "could not post the evidence on Issue #$issue."
echo "Recorded the evidence on Issue #$issue."

# What still has no evidence: the criteria that are not recorded, and not the
# one just recorded. Every comparison is exact.
open_criteria=""
while IFS= read -r line; do
  [[ "$line" != "$criterion" ]] || continue
  if ! printf '%s\n' "$recorded" | grep -Fqx -- "$line"; then
    open_criteria+="$line"$'\n'
  fi
done <<<"$pending"
open_criteria="${open_criteria%$'\n'}"
if [[ -n "$open_criteria" ]]; then
  echo "Still pending at the post_merge gate; the Issue stays open:"
  printf '%s\n' "$open_criteria" | sed 's/^/  /'
  exit 0
fi

state="$(gh issue view "$issue" --json state --jq '.state')" ||
  fail "could not read Issue #$issue. The evidence is recorded; close the Issue by hand."
if [[ "$state" == "OPEN" ]]; then
  gh issue close "$issue" >/dev/null ||
    fail "could not close Issue #$issue. The evidence is recorded; close it by hand."
  echo "Every post_merge criterion has its evidence: closed Issue #$issue."
else
  echo "Every post_merge criterion has its evidence. Issue #$issue is closed already."
fi
