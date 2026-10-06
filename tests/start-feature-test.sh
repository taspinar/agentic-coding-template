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
repo="$(setup_repo derived)"
run_start "$repo" 3 || {
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

echo "start-feature tests passed"
