#!/usr/bin/env bash

set -euo pipefail

# Recording the evidence of post_merge criteria after a merge: the Issue
# stays open until every one has its evidence, and then it is closed.

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$source_root/tests/lib-fakes.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/record-post-merge-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "record-post-merge test failed: $*" >&2
  exit 1
}

# A fake GitHub CLI. MOCK_PRS is the JSON of the merged pull requests,
# MOCK_COMMENTS the JSON of the comments of the Issue,
# MOCK_STATE the state of the Issue.
mkdir -p "$tmp/bin"
ln -sf "$(command -v jq)" "$tmp/bin/jq"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$MOCK_GH_LOG"
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "${MOCK_PRS:-[]}" ;;
  "api repos/{owner}/{repo}/issues/12/comments")
    # The comments as the API returns them; the --jq filter of the script runs
    # here, as it does in gh.
    filter=""
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
      if [[ "${args[$i]}" == "--jq" ]]; then filter="${args[$((i + 1))]}"; fi
    done
    jq -r "$filter" <<<"${MOCK_COMMENTS:-[]}"
    ;;
  "issue comment")
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
      if [[ "${args[$i]}" == "--body-file" ]]; then cp "${args[$((i + 1))]}" "$MOCK_GH_LOG.comment"; fi
    done
    ;;
  "issue view") echo "${MOCK_STATE:-OPEN}" ;;
  "issue close") ;;
  *)
    echo "Unexpected gh invocation: $*" >&2
    exit 97
    ;;
esac
GH
chmod +x "$tmp/bin/gh"

body='Completion: awaiting_evidence
- met: The marker exists (feature.txt)
- pending at pr_ci: CI passes (after publication)
- pending at post_merge: main verifies (the run on main)
- pending at post_merge: The page is live (open the site)
Post-merge criterion: "main verifies"
Post-merge criterion: "The page is live"

Closes #12'
prs="$(jq -n --arg body "$body" '[
  {number: 3, headRefName: "feature/12-marker", body: "old"},
  {number: 5, headRefName: "feature/120-other", body: "Post-merge criterion: \"other\""},
  {number: 7, headRefName: "feature/12-marker", body: $body}]')"

# comments <criterion>...: the Issue comments of this script for these
# criteria, with a human comment among them.
comments() {
  local criterion
  local out='[{"body": "Looks good. Criterion: main verifies"}'

  for criterion in "$@"; do
    out+=", $(jq -n --arg c "$criterion" '{body: ("<!-- post-merge-evidence -->\nPost-merge evidence (recorded by record-post-merge.sh)\n\nCriterion: " + $c + "\n\nEvidence: seen")}')"
  done
  printf '%s]' "$out"
}

n=0
# run_record <description> [args...]: the log is per call.
run_record() {
  n=$((n + 1))
  log="$tmp/call-$n"
  : >"$log"
  PATH="$tmp/bin:/usr/bin:/bin" MOCK_GH_LOG="$log" "$source_root/scripts/record-post-merge.sh" "$@" >"$log.out" 2>&1
}

# Wrong use is refused before GitHub is asked.
run_record 12 "main verifies" && fail "a missing evidence was accepted"
run_record abc "main verifies" "the run" && fail "a non-numeric Issue was accepted"
run_record 12 "main verifies" " " && fail "empty evidence was accepted"
[[ ! -s "$log" ]] || fail "GitHub was asked before the input was checked"

# No merged pull request of the feature: nothing to record.
MOCK_PRS='[]' run_record 12 "main verifies" "the run on main" && fail "evidence was recorded without a merged pull request"
grep -Fq "no merged pull request of feature/12-*" "$log.out" || fail "the missing merge was not explained"

# A criterion that is not pending at post_merge, even one of another gate.
MOCK_PRS="$prs" run_record 12 "CI passes" "green" && fail "a pr_ci criterion was recorded as post-merge evidence"
grep -Fqx "  main verifies" "$log.out" || fail "the pending criteria were not listed"
grep -Fqx "  The page is live" "$log.out" || fail "the second pending criterion was not listed"
if grep -Fq "issue comment" "$log"; then fail "a comment was posted for an unknown criterion"; fi

# The first piece of evidence is a comment; the Issue stays open.
MOCK_PRS="$prs" MOCK_COMMENTS="$(comments)" run_record 12 "main verifies" "verify run 123 on main passed" || { cat "$log.out" >&2; fail "recording the first evidence failed"; }
for line in "<!-- post-merge-evidence -->" "Criterion: main verifies" "Evidence: verify run 123 on main passed"; do
  grep -Fqx -- "$line" "$log.comment" || fail "the comment lacks: $line"
done
grep -Fqx "  The page is live" "$log.out" || fail "the criterion that is still pending was not named"
if grep -Fq "issue close" "$log"; then fail "the Issue was closed with evidence pending"; fi

# The same criterion is not recorded twice.
MOCK_PRS="$prs" MOCK_COMMENTS="$(comments "main verifies")" run_record 12 "main verifies" "again" && fail "evidence was recorded twice"
grep -Fq "recorded already" "$log.out" || fail "the repetition was not explained"

# The last piece of evidence closes the Issue.
MOCK_PRS="$prs" MOCK_COMMENTS="$(comments "main verifies")" run_record 12 "The page is live" "https://example.com shows the page" || { cat "$log.out" >&2; fail "recording the last evidence failed"; }
grep -Fq "issue close 12" "$log" || fail "the Issue was not closed after the last evidence"
grep -Fq "closed Issue #12" "$log.out" || fail "the closing was not reported"

# An Issue that is closed already is not closed again.
MOCK_PRS="$prs" MOCK_COMMENTS="$(comments "main verifies")" MOCK_STATE=CLOSED run_record 12 "The page is live" "seen" || fail "recording evidence on a closed Issue failed"
if grep -Fq "issue close" "$log"; then fail "a closed Issue was closed again"; fi

# A merged pull request without pending post_merge criteria has nothing to record.
MOCK_PRS='[{"number": 7, "headRefName": "feature/12-marker", "body": "Closes #12"}]' run_record 12 "x" "y" && fail "evidence was recorded without a pending criterion"
grep -Fq "lists no pending post_merge criterion" "$log.out" || fail "the absence of pending criteria was not explained"

# Criteria are matched exactly, as the JSON strings of the finish commit say
# them, so a criterion that begins like another, or holds parentheses, can
# never stand for it. Recording "main verifies" must not clear
# "main verifies (production)", and must leave the Issue open.
exact_body='Post-merge criterion: "main verifies"
Post-merge criterion: "main verifies (production)"
Post-merge criterion: "The page (index) is live"'
exact_prs="$(jq -n --arg body "$exact_body" '[{number: 9, headRefName: "feature/12-marker", body: $body}]')"
MOCK_PRS="$exact_prs" MOCK_COMMENTS="$(comments)" run_record 12 "main verifies" "run 1 passed" || { cat "$log.out" >&2; fail "recording the shorter criterion failed"; }
grep -Fq "Criterion: main verifies" "$log.comment" || fail "the shorter criterion was not recorded"
if grep -Fq "issue close" "$log"; then fail "the Issue was closed while two criteria were left"; fi
grep -Fqx "  main verifies (production)" "$log.out" || fail "the criterion that begins like the recorded one was cleared"
grep -Fqx "  The page (index) is live" "$log.out" || fail "the criterion with parentheses was not listed"
# With the shorter one recorded, the longer one is still pending and is
# recorded exactly by its own text; the Issue closes only after the last one.
MOCK_PRS="$exact_prs" MOCK_COMMENTS="$(comments "main verifies")" run_record 12 "main verifies (production)" "run in production passed" || { cat "$log.out" >&2; fail "recording the longer criterion failed"; }
if grep -Fq "issue close" "$log"; then fail "the Issue was closed while one criterion was left"; fi
grep -Fqx "  The page (index) is live" "$log.out" || fail "the remaining criterion was not listed"
MOCK_PRS="$exact_prs" MOCK_COMMENTS="$(comments "main verifies" "main verifies (production)")" run_record 12 "The page (index) is live" "seen" || { cat "$log.out" >&2; fail "recording the last criterion failed"; }
grep -Fq "issue close 12" "$log" || fail "the Issue was not closed after the last criterion"
# A prefix is not a criterion, and the longer one is not recorded by the shorter text.
MOCK_PRS="$exact_prs" MOCK_COMMENTS="$(comments)" run_record 12 "main" "x" && fail "a prefix of a criterion was accepted"
grep -Fqx "  main verifies (production)" "$log.out" || fail "the error listing does not print the criteria whole"
# A description that holds a malformed criterion line is refused, not guessed at.
bad_prs="$(jq -n '[{number: 9, headRefName: "feature/12-marker", body: "Post-merge criterion: main verifies"}]')"
MOCK_PRS="$bad_prs" MOCK_COMMENTS="$(comments)" run_record 12 "main verifies" "x" && fail "a malformed criterion line was accepted"
grep -Fq "not a JSON string" "$log.out" || fail "the malformed criterion line was not explained"

# A pull request description edited on GitHub has CRLF line endings: the
# criterion lines still match.
crlf_prs="$(jq -n --arg body "$(printf '%s\r\n%s\r\n' 'Post-merge criterion: "main verifies"' 'Post-merge criterion: "The page is live"')" '[{number: 9, headRefName: "feature/12-marker", body: $body}]')"
MOCK_PRS="$crlf_prs" MOCK_COMMENTS="$(comments)" run_record 12 "main verifies" "run 1 passed" || { cat "$log.out" >&2; fail "a criterion of a description with CRLF line endings could not be recorded"; }
grep -Fqx "  The page is live" "$log.out" || fail "the CRLF listing keeps a carriage return"

# An evidence text is free text: a line of it that reads like a criterion line
# does not record that other criterion. Only the first "Criterion: " line of a
# comment counts.
tricky="$(jq -n '[{body: ("<!-- post-merge-evidence -->\nPost-merge evidence (recorded by record-post-merge.sh)\n\nCriterion: main verifies\n\nEvidence: see the run\nCriterion: The page is live was checked too")}]')"
MOCK_PRS="$prs" MOCK_COMMENTS="$tricky" run_record 12 "The page is live" "https://example.com shows the page" || { cat "$log.out" >&2; fail "evidence text that reads like a criterion line recorded another criterion"; }
if grep -Fq "recorded already" "$log.out"; then fail "a criterion was taken as recorded from the evidence of another"; fi
grep -Fq "issue close 12" "$log" || fail "the Issue was not closed after the last criterion although the other was recorded"
# The same tricky comment does not close the Issue by itself while the other criterion is open.
MOCK_PRS="$prs" MOCK_COMMENTS="[]" run_record 12 "main verifies" "see the run
Criterion: The page is live was checked too" || fail "recording multi-line evidence failed"
if grep -Fq "issue close" "$log"; then fail "the Issue was closed with a criterion left open"; fi

echo "record-post-merge tests passed"
