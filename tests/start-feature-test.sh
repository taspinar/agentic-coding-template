#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/start-feature-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "start-feature test failed: $*" >&2
  exit 1
}

source "$source_root/tests/lib-fakes.sh"
make_fake_agents "$tmp/bin"

cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-} ${2:-}" == "issue view" ]]; then
  [[ -z "${MOCK_GH_FAIL:-}" ]] || exit 1
  printf '%s\n' "${MOCK_ISSUE_TITLE:-F01 — Published site skeleton with the full verification pipeline}"
  exit 0
fi
echo "Unexpected gh invocation: $*" >&2
exit 1
GH
chmod +x "$tmp/bin/gh"

setup_repo() {
  local label="$1"
  local seed="$tmp/$label-seed"
  local remote="$tmp/$label-remote.git"
  local repo="$tmp/$label"

  mkdir -p "$seed"
  copy_workflow "$seed"
  printf 'implementer: codex model-i\n' >"$seed/.agents/agents.conf"
  printf '# Project\n' >"$seed/README.md"
  printf '.agents/run/\n' >"$seed/.gitignore"
  git -C "$seed" init -q -b main
  git -C "$seed" config user.name "Start Feature Test"
  git -C "$seed" config user.email "start-feature-test@example.com"
  git -C "$seed" add .
  git -C "$seed" commit -qm "Seed"
  git init -q --bare -b main "$remote"
  git -C "$seed" push -q "$remote" main
  git clone -q "$remote" "$repo"
  printf '%s\n' "$repo"
}

run_start() {
  local repo="$1"
  shift
  (
    cd "$repo"
    PATH="$tmp/bin:/usr/bin:/bin" MOCK_AGENT_LOG="$repo.log" ./scripts/start-feature.sh "$@" </dev/null
  ) >"$repo.out" 2>&1
}

# Without a slug, the branch and worktree are named after the Issue title,
# and the implementer starts write-capable in the new worktree.
# record <status> <issue>: a write action of the fake implementer that leaves
# a completion record with that status.
record() {
  local remaining='[]'
  local met="met"

  if [[ "$1" != "complete" ]]; then
    remaining='["Plan steps 3 to 9"]'
    met="not_met"
  fi
  printf '%s' "mkdir -p .agents/completion && printf '%s\\n' '{\"schema\": \"completion/v1\", \"status\": \"$1\", \"criteria\": [{\"criterion\": \"The thing works\", \"status\": \"$met\", \"evidence\": \"tests/thing-test.sh\"}], \"remaining\": $remaining}' >.agents/completion/$2.json"
}

repo="$(setup_repo derived)"
MOCK_WRITE_ACTION="$(record complete 3)" run_start "$repo" 3 || {
  cat "$repo.out" >&2
  fail "starting a feature without a slug failed"
}
worktree="$tmp/derived-3-published-site-skeleton-with"
[[ -d "$worktree" ]] || fail "the worktree was not named after the Issue title"
[[ "$(git -C "$worktree" branch --show-current)" == "feature/3-published-site-skeleton-with" ]] ||
  fail "the branch was not named after the Issue title"
[[ "$(git -C "$worktree" rev-parse HEAD)" == "$(git -C "$repo" rev-parse origin/main)" ]] ||
  fail "the feature branch does not start at origin/main"
grep -Fq -- "--sandbox workspace-write" "$repo.log" || fail "the implementer was not started write-capable"
grep -Fq -- "--model model-i" "$repo.log" || fail "the configured model was not passed"
grep -Fq "The implementer reports the Issue as complete" "$repo.out" || fail "a complete record was not reported"
grep -Fq "./scripts/review-feature.sh 3" "$repo.out" || fail "the next steps were not printed"
grep -Fq "GitHub Issue #3" "$repo.log" || fail "the implementer was not given its Issue"

# An explicit slug is used as given, and untracked files in the checkout do
# not prevent starting.
repo="$(setup_repo explicit)"
printf 'notes\n' >"$repo/notes.txt"
run_start "$repo" 4 recipes || {
  cat "$repo.out" >&2
  fail "starting a feature with a slug and an untracked file failed"
}
[[ "$(git -C "$tmp/explicit-4-recipes" branch --show-current)" == "feature/4-recipes" ]] ||
  fail "the explicit slug was not used"

# An optional scripts/worktree-setup.sh prepares the new worktree before the
# agent starts. It runs in the worktree and receives the primary checkout.
add_setup_script() {
  local repo="$1"
  local mode="$2"
  local body="$3"

  printf '#!/usr/bin/env bash\n%s\n' "$body" >"$repo/scripts/worktree-setup.sh"
  chmod "$mode" "$repo/scripts/worktree-setup.sh"
  git -C "$repo" add scripts/worktree-setup.sh
  git -C "$repo" -c user.name="Start Feature Test" -c user.email="start-feature-test@example.com" \
    commit -qm "Add worktree setup"
  git -C "$repo" push -q origin main
}

repo="$(setup_repo prepared)"
add_setup_script "$repo" 755 'printf "%s\n%s\n" "$PWD" "$1" >prepared.txt'
worktree="$tmp/prepared-8-thing"
MOCK_WRITE_ACTION="cp '$worktree/prepared.txt' '$repo.seen-by-agent'" run_start "$repo" 8 thing || {
  cat "$repo.out" >&2
  fail "starting a feature with a worktree setup script failed"
}
[[ -f "$repo.seen-by-agent" ]] || fail "the worktree was not prepared before the agent started"
[[ "$(sed -n 1p "$repo.seen-by-agent")" == "$(cd "$worktree" && pwd -P)" ]] ||
  fail "the setup script did not run in the new worktree"
[[ "$(sed -n 2p "$repo.seen-by-agent")" == "$(cd "$repo" && pwd -P)" ]] ||
  fail "the setup script did not receive the primary checkout"

# A failing or non-executable setup script is reported and does not stop the
# feature.
repo="$(setup_repo setup-fails)"
add_setup_script "$repo" 755 'exit 9'
run_start "$repo" 8 thing || fail "a failing setup script stopped the feature"
grep -Fq "worktree-setup.sh failed with status 9" "$repo.out" || fail "the failed setup was not reported"
[[ -e "$repo.log" ]] || fail "the agent did not start after a failed setup"

repo="$(setup_repo setup-not-executable)"
add_setup_script "$repo" 644 'touch prepared.txt'
run_start "$repo" 8 thing || fail "a non-executable setup script stopped the feature"
grep -Fq "worktree-setup.sh is not executable" "$repo.out" || fail "the skipped setup was not reported"
[[ ! -e "$tmp/setup-not-executable-8-thing/prepared.txt" ]] || fail "a non-executable setup script ran"

# A verification record that the agent session leaves is kept, so the review
# that follows can reuse it.
repo="$(setup_repo session-record)"
worktree="$tmp/session-record-9-thing"
MOCK_WRITE_ACTION="mkdir -p '$worktree/.agents/verification' && printf 'tree: recorded\n' >'$worktree/.agents/verification/passed'" \
  run_start "$repo" 9 thing || fail "starting a feature failed"
grep -Fqx "tree: recorded" "$worktree/.agents/verification/passed" ||
  fail "the verification record of the agent session was discarded"

# --resume starts a new implementer session in the existing worktree of the
# Issue, without creating a branch or a worktree, and tells it to read the
# state from the repository instead of an earlier conversation.
repo="$(setup_repo resumed)"
run_start "$repo" 10 thing || fail "starting the feature to resume failed"
worktree="$tmp/resumed-10-thing"
printf 'half done\n' >"$worktree/work.txt"
head_before="$(git -C "$worktree" rev-parse HEAD)"
rm -f "$repo.log" "$repo.log.called"
MOCK_AGENT_ACTION="pwd -P >'$repo.cwd'" run_start "$repo" 10 --resume --agent claude --model model-c || {
  cat "$repo.out" >&2
  fail "resuming a feature failed"
}
[[ "$(cat "$repo.cwd")" == "$worktree" ]] || fail "the resumed session did not run in the existing worktree"
grep -Fq -- "--permission-mode acceptEdits --model model-c" "$repo.log" ||
  fail "the resumed session did not use the overridden agent and model"
grep -Fq "You are resuming interrupted work on GitHub Issue #10" "$repo.log" || fail "the session was not told that it resumes"
grep -Fq "left no handoff note" "$repo.log" || fail "the session was not told that there is no handoff note"
[[ "$(git -C "$worktree" rev-parse HEAD)" == "$head_before" ]] || fail "resuming changed the branch"
grep -Fqx "half done" "$worktree/work.txt" || fail "resuming lost the work in progress"
[[ "$(git -C "$repo" worktree list | grep -c .)" -eq 2 ]] || fail "resuming created another worktree"
# A session that ends is not a feature that is complete: without a completion
# record the review is not offered as the next step.
grep -Fq "The Issue is not complete (missing)" "$repo.out" || fail "a session without a completion record was not reported as not complete"
grep -Fq "./scripts/start-feature.sh 10 --resume" "$repo.out" || fail "resuming was not offered for work that is not complete"
if grep -Fq "./scripts/review-feature.sh 10" "$repo.out"; then fail "the review was offered for work that is not complete"; fi

# The same for a record that says partial, with what remains, and for a
# record that says complete while the handoff note lists remaining work.
MOCK_WRITE_ACTION="$(record partial 10)" run_start "$repo" 10 --resume || fail "resuming with a partial record failed"
grep -Fq "The Issue is not complete (partial)" "$repo.out" || fail "a partial record was not reported"
grep -Fq "remaining: Plan steps 3 to 9" "$repo.out" || fail "the remaining work of the record was not shown"
if grep -Fq "./scripts/review-feature.sh 10" "$repo.out"; then fail "the review was offered for partial work"; fi

mkdir -p "$worktree/.agents/handoffs"
printf '**Done:** steps 1 and 2.\n**Remaining:** steps 3 to 9.\n' >"$worktree/.agents/handoffs/10.md"
MOCK_WRITE_ACTION="$(record complete 10)" run_start "$repo" 10 --resume || fail "resuming with a contradicted record failed"
grep -Fq "The Issue is not complete (partial)" "$repo.out" ||
  fail "a record that says complete was believed although the handoff note lists remaining work"
grep -Fq "remaining: steps 3 to 9." "$repo.out" || fail "the remaining work of the handoff note was not shown"
printf 'Issue 10 is complete.\n' >"$worktree/.agents/handoffs/10.md"
MOCK_WRITE_ACTION="$(record complete 10)" run_start "$repo" 10 --resume || fail "resuming with a complete record failed"
grep -Fq "./scripts/review-feature.sh 10" "$repo.out" || fail "the next steps were not printed after resuming"

# With a handoff note, the session is pointed at it. Changed files that are
# newer than the note are named as not described by it; older ones are not.
mkdir -p "$worktree/.agents/handoffs"
printf 'Done: the first part.\n' >"$worktree/.agents/handoffs/10.md"
printf 'older\n' >"$worktree/older.txt"
touch -t 202001010000 "$worktree/older.txt" "$worktree/work.txt"
touch -t 202101010000 "$worktree/.agents/handoffs/10.md"
printf 'changed after the note\n' >"$worktree/newer.txt"
printf 'spaced\n' >"$worktree/a file with spaces.txt"
# A tracked file that is deleted, and one that is renamed, after the note.
git -C "$worktree" rm -q README.md
git -C "$worktree" mv scripts/check-review.sh scripts/renamed-check.sh
touch "$worktree/scripts/renamed-check.sh"
rm -f "$repo.log"
run_start "$repo" 10 --resume || fail "resuming with a handoff note failed"
grep -Fq "handoff note: .agents/handoffs/10.md" "$repo.log" || fail "the session was not pointed at the handoff note"
grep -Fq "The note is STALE in part" "$repo.log" || fail "a note older than changed files was not reported as stale"
grep -Fqx -- "- newer.txt" "$repo.log" || fail "the file changed after the note was not named"
grep -Fqx -- "- a file with spaces.txt" "$repo.log" || fail "a file name with spaces was not named as it is"
grep -Fqx -- "- README.md (deleted)" "$repo.log" || fail "a deleted file was not named"
grep -Fqx -- "- scripts/renamed-check.sh" "$repo.log" || fail "the new name of a renamed file was not named"
if grep -Fq -- "- scripts/check-review.sh" "$repo.log"; then fail "the old name of a renamed file was named"; fi
if grep -Fqx -- "- older.txt" "$repo.log"; then fail "a file older than the note was named as newer"; fi
git -C "$worktree" reset -q --hard

rm -f "$worktree/newer.txt" "$worktree/a file with spaces.txt"
touch -t 203001010000 "$worktree/.agents/handoffs/10.md"
rm -f "$repo.log"
run_start "$repo" 10 --resume || fail "resuming with a current handoff note failed"
grep -Fq "handoff note: .agents/handoffs/10.md" "$repo.log" || fail "the session was not pointed at the current note"
if grep -Fq "STALE" "$repo.log"; then fail "a current note was reported as stale"; fi

# A failed resumed session is reported with the way to continue.
if MOCK_WRITE_EXIT=6 run_start "$repo" 10 --resume; then fail "a failed resumed session returned success"; fi
grep -Fq "10 --resume" "$repo.out" || fail "a failed session did not say how to continue"

# The resumed session compares with the base the feature was created from.
repo="$(setup_repo other-base)"
git -C "$repo" push -q origin main:develop
run_start "$repo" 12 thing develop || fail "starting a feature from another base failed"
rm -f "$repo.log"
run_start "$repo" 12 --resume || fail "resuming a feature from another base failed"
grep -Fq "git merge-base HEAD origin/develop" "$repo.log" || fail "the resumed session was not given the feature's base"

# There must be exactly one worktree to resume, and --resume takes no slug.
repo="$(setup_repo nothing-to-resume)"
if run_start "$repo" 11 --resume; then fail "resuming without a worktree was accepted"; fi
grep -Fq "nothing to resume" "$repo.out" || fail "the missing worktree was not reported"
[[ ! -e "$repo.log" ]] || fail "an agent started although there was nothing to resume"
if compgen -G "$tmp/nothing-to-resume-11-*" >/dev/null; then fail "resuming created a worktree"; fi
if run_start "$repo" 11 thing --resume; then fail "--resume with a slug was accepted"; fi

# Modified tracked files, an unreadable Issue title, and an unsafe slug fail
# before a worktree is created.
repo="$(setup_repo refused)"
printf 'changed\n' >>"$repo/README.md"
if run_start "$repo" 5 thing; then fail "a checkout with modified tracked files was accepted"; fi
git -C "$repo" checkout -q -- README.md
if MOCK_GH_FAIL=1 run_start "$repo" 5; then fail "an unreadable Issue title was accepted"; fi
if run_start "$repo" 5 "../escape"; then fail "an unsafe slug was accepted"; fi
if run_start "$repo" five; then fail "a non-numeric issue was accepted"; fi
if compgen -G "$tmp/refused-5-*" >/dev/null; then fail "a refused start created a worktree"; fi
[[ ! -e "$repo.log" ]] || fail "an agent started although the start was refused"

# A failing implementer is reported and the worktree is kept.
repo="$(setup_repo agent-fails)"
if MOCK_WRITE_EXIT=6 run_start "$repo" 6 thing; then fail "a failed implementer returned success"; fi
[[ -d "$tmp/agent-fails-6-thing" ]] || fail "the worktree was removed after a failed implementer"

# --unattended runs the implementer without a terminal: it is told not to
# ask, and its final message is stored in the worktree and shown.
repo="$(setup_repo unattended)"
MOCK_OUTPUT="The feature is implemented." run_start "$repo" 7 thing --unattended || {
  cat "$repo.out" >&2
  fail "an unattended start failed"
}
worktree="$tmp/unattended-7-thing"
grep -Fq -- "exec --ignore-user-config" "$repo.log" || fail "the unattended implementer did not run without a terminal"
grep -Fq "This session is unattended" "$repo.log" || fail "the unattended implementer was not told to ask nothing"
grep -Fq "GitHub Issue #7" "$repo.log" || fail "the unattended implementer was not given its Issue"
[[ "$(cat "$worktree/.agents/run/7-implementer.md")" == "The feature is implemented." ]] ||
  fail "the final message of the unattended implementer was not stored"
grep -Fq "The feature is implemented." "$repo.out" || fail "the final message of the unattended implementer was not shown"

# A resumed session can run unattended too, with the other provider.
rm -f "$repo.log"
MOCK_OUTPUT="Continued." run_start "$repo" 7 --resume --unattended --agent claude --model model-c || {
  cat "$repo.out" >&2
  fail "an unattended resume failed"
}
grep -Fq -- "--permission-mode auto --permission-prompts none" "$repo.log" ||
  fail "the unattended claude implementer did not run without prompts"
[[ "$(cat "$worktree/.agents/run/7-implementer.md")" == "Continued." ]] ||
  fail "the final message of the resumed session did not replace the previous one"

# An agent that reports it needs the human stops the run with status 3.
status=0
MOCK_OUTPUT="I stopped.
BLOCKED: the Issue contradicts ADR 002" run_start "$repo" 7 --resume --unattended || status=$?
[[ "$status" -eq 3 ]] || fail "a blocked unattended session exited with $status instead of 3"
grep -Fq "needs you: the Issue contradicts ADR 002" "$repo.out" || fail "the reason of a blocked session was not reported"
grep -Fq "7 --resume" "$repo.out" || fail "a blocked session did not say how to continue"
if grep -Fq "review-feature.sh 7" "$repo.out"; then fail "a blocked session was followed by the next steps"; fi

# A failed unattended session is a failure, not a blocked one.
status=0
MOCK_WRITE_EXIT=6 run_start "$repo" 7 --resume --unattended || status=$?
[[ "$status" -eq 6 ]] || fail "a failed unattended session exited with $status"
status=0
MOCK_WRITE_EXIT=3 run_start "$repo" 7 --resume --unattended || status=$?
[[ "$status" -eq 1 ]] || fail "an agent that failed with status 3 was reported as blocked ($status)"
if grep -Fq "needs you" "$repo.out"; then fail "a failed session was reported as blocked"; fi

# The stored final message and the session log may not end up in the feature.
repo="$(setup_repo not-ignored)"
git -C "$repo" rm -q .gitignore
git -C "$repo" -c user.name="Start Feature Test" -c user.email="start-feature-test@example.com" \
  commit -qm "Remove the ignore rules"
git -C "$repo" push -q origin main
if run_start "$repo" 8 thing --unattended; then fail "an unattended start ran although .agents/run/ is not ignored"; fi
grep -Fq ".agents/run/" "$repo.out" || fail "the missing ignore rule was not named"
grep -Fq "8 --resume --unattended" "$repo.out" || fail "a refused unattended start did not say how to continue"
[[ ! -e "$repo.log" ]] || fail "an agent started although .agents/run/ is not ignored"
printf '.agents/run/\n' >"$tmp/not-ignored-8-thing/.gitignore"
MOCK_OUTPUT="Done." run_start "$repo" 8 --resume --unattended || fail "the refused start could not be continued after adding the rule"

# A session with a terminal is not told that it is unattended, and a line
# that starts with BLOCKED in its output does not stop anything.
repo="$(setup_repo attended)"
MOCK_OUTPUT="BLOCKED: nothing" run_start "$repo" 7 thing || fail "an attended start failed"
if grep -Fq "This session is unattended" "$repo.log"; then fail "an attended session was told it is unattended"; fi
[[ ! -e "$tmp/attended-7-thing/.agents/run" ]] || fail "an attended session stored a final message"

echo "start-feature tests passed"
