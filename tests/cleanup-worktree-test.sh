#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cleanup-worktree-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "cleanup-worktree test failed: $*" >&2
  exit 1
}

mkdir -p "$tmp/bin"
ln -sf "$(command -v jq)" "$tmp/bin/jq"

# The fake GitHub CLI reports a merged pull request for each
# "<branch> <head> [<number>]" line in MOCK_MERGED_FILE, as the head and the
# number separated by a tab.
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-} ${2:-}" == "pr list" ]]; then
  [[ -z "${MOCK_GH_FAIL:-}" ]] || exit 1
  head=""
  while [[ $# -gt 0 ]]; do
    [[ "$1" != "--head" ]] || head="$2"
    shift
  done
  awk -v branch="$head" '$1 == branch { print $2 "\t" ($3 == "" ? 1 : $3) }' "$MOCK_MERGED_FILE" 2>/dev/null || true
  exit 0
fi
echo "Unexpected gh invocation: $*" >&2
exit 1
GH
chmod +x "$tmp/bin/gh"

# Creates a primary checkout with a remote, and returns its path.
setup_repo() {
  local label="$1"
  local seed="$tmp/$label-seed"
  local remote="$tmp/$label-remote.git"
  local repo="$tmp/$label"

  mkdir -p "$seed/scripts/lib"
  cp "$source_root/scripts/cleanup-worktree.sh" "$seed/scripts/"
  cp "$source_root/scripts/lib/records.sh" "$seed/scripts/lib/"
  cp "$source_root/.gitignore" "$seed/.gitignore"
  printf '# Project\n' >"$seed/README.md"
  git -C "$seed" init -q -b main
  git -C "$seed" config user.name "Cleanup Test"
  git -C "$seed" config user.email "cleanup-test@example.com"
  git -C "$seed" add .
  git -C "$seed" commit -qm "Seed"
  git init -q --bare -b main "$remote"
  git -C "$seed" push -q "$remote" main
  git clone -q "$remote" "$repo"
  git -C "$repo" config user.name "Cleanup Test"
  git -C "$repo" config user.email "cleanup-test@example.com"
  : >"$repo.merged"
  printf '%s\n' "$repo"
}

# add_worktree <repo> <branch> <directory>: a worktree with one commit.
add_worktree() {
  git -C "$1" worktree add -q "$tmp/$3" -b "$2" origin/main
  printf '%s\n' "$2" >"$tmp/$3/work.txt"
  git -C "$tmp/$3" add work.txt
  git -C "$tmp/$3" commit -qm "Work on $2"
}

# merge <repo> <branch> <directory>: squash-merges the branch on the remote
# and records its head as the merged pull request head.
merge() {
  local other="$tmp/merge-$RANDOM"
  git clone -q "$(git -C "$1" remote get-url origin)" "$other"
  git -C "$other" config user.name "Cleanup Test"
  git -C "$other" config user.email "cleanup-test@example.com"
  git -C "$other" checkout -q "$(git -C "$tmp/$3" rev-parse HEAD)" -- . 2>/dev/null ||
    cp "$tmp/$3/work.txt" "$other/work.txt"
  git -C "$other" add -A
  git -C "$other" commit -qm "Squash merge $2"
  git -C "$other" push -q origin main
  printf '%s %s\n' "$2" "$(git -C "$tmp/$3" rev-parse HEAD)" >>"$1.merged"
}

run_cleanup() {
  local repo="$1"
  shift
  (
    cd "$repo"
    PATH="$tmp/bin:/usr/bin:/bin" MOCK_MERGED_FILE="$repo.merged" ./scripts/cleanup-worktree.sh "$@"
  ) >"$repo.out" 2>&1
}

branch_exists() {
  git -C "$1" show-ref --verify --quiet "refs/heads/$2"
}

# A merged feature worktree is removed with its branch, also with ignored
# review files in it, and main is updated.
repo="$(setup_repo merged)"
add_worktree "$repo" feature/12-recipes merged-12-recipes
mkdir -p "$tmp/merged-12-recipes/.agents/reviews"
printf '{}\n' >"$tmp/merged-12-recipes/.agents/reviews/feature-12-recipes-review-01.json"
merge "$repo" feature/12-recipes merged-12-recipes
run_cleanup "$repo" 12 || {
  cat "$repo.out" >&2
  fail "cleaning a merged feature worktree failed"
}
[[ ! -e "$tmp/merged-12-recipes" ]] || fail "the merged worktree was not removed"
! branch_exists "$repo" feature/12-recipes || fail "the merged branch was not deleted"
[[ -f "$repo/work.txt" ]] || fail "main was not updated with the merged work"

# A planning worktree is found by its branch name. Untracked files in the
# primary checkout do not prevent updating main, and after the merge an
# untracked copy of the project description is removed while other files stay.
repo="$(setup_repo planning)"
git -C "$repo" worktree add -q "$tmp/planning-wt" -b planning/project-bootstrap origin/main
mkdir -p "$tmp/planning-wt/docs"
printf 'The project idea.\n' >"$tmp/planning-wt/docs/PROJECT_DESCRIPTION.md"
mkdir -p "$tmp/planning-wt/docs/changes"
printf 'Add a shopping list.\n' >"$tmp/planning-wt/docs/changes/shopping-list.md"
git -C "$tmp/planning-wt" add docs/PROJECT_DESCRIPTION.md docs/changes
git -C "$tmp/planning-wt" commit -qm "Plan project bootstrap"
other="$tmp/merge-planning"
git clone -q "$(git -C "$repo" remote get-url origin)" "$other"
git -C "$other" config user.name "Cleanup Test"
git -C "$other" config user.email "cleanup-test@example.com"
mkdir -p "$other/docs"
cp -R "$tmp/planning-wt/docs/." "$other/docs/"
git -C "$other" add -A
git -C "$other" commit -qm "Squash merge planning"
git -C "$other" push -q origin main
printf 'planning/project-bootstrap %s\n' "$(git -C "$tmp/planning-wt" rev-parse HEAD)" >>"$repo.merged"
printf 'The project idea.\n' >"$repo/idea.md"
printf 'Add a shopping list.\n' >"$repo/change.md"
printf 'Something else.\n' >"$repo/notes.md"
run_cleanup "$repo" planning/project-bootstrap || {
  cat "$repo.out" >&2
  fail "cleaning a merged planning worktree failed"
}
[[ ! -e "$tmp/planning-wt" ]] || fail "the merged planning worktree was not removed"
[[ -f "$repo/docs/PROJECT_DESCRIPTION.md" ]] || fail "main was not updated although only untracked files were present"
[[ ! -e "$repo/idea.md" ]] || fail "the identical copy of the project description was not removed"
[[ ! -e "$repo/change.md" ]] || fail "the identical copy of a merged change request was not removed"
[[ -f "$repo/docs/changes/shopping-list.md" ]] || fail "the change request in the repository was removed"
[[ -f "$repo/notes.md" ]] || fail "an unrelated untracked file was removed"
grep -Fq "create-feature-issue.sh" "$repo.out" || fail "the next step after a planning cleanup was not printed"


repo="$(setup_repo by-path)"
add_worktree "$repo" feature/13-plan by-path-13
merge "$repo" feature/13-plan by-path-13
run_cleanup "$repo" "$tmp/by-path-13" || {
  cat "$repo.out" >&2
  fail "cleaning by path failed"
}
[[ ! -e "$tmp/by-path-13" ]] || fail "the worktree given by path was not removed"

# Unmerged, ahead-of-PR, and dirty worktrees are kept.
repo="$(setup_repo kept)"
add_worktree "$repo" feature/20-unmerged kept-20
if run_cleanup "$repo" 20; then fail "an unmerged worktree was removed"; fi
[[ -d "$tmp/kept-20" ]] && branch_exists "$repo" feature/20-unmerged || fail "an unmerged worktree or branch is gone"
grep -Fq "not merged" "$repo.out" || fail "an unmerged worktree was not reported"

add_worktree "$repo" feature/21-ahead kept-21
merge "$repo" feature/21-ahead kept-21
printf 'later\n' >>"$tmp/kept-21/work.txt"
git -C "$tmp/kept-21" commit -qam "Commit after the merge"
if run_cleanup "$repo" 21; then fail "a worktree with commits after its merge was removed"; fi
[[ -d "$tmp/kept-21" ]] || fail "a worktree with commits after its merge is gone"

add_worktree "$repo" feature/22-dirty kept-22
merge "$repo" feature/22-dirty kept-22
printf 'uncommitted\n' >>"$tmp/kept-22/work.txt"
if run_cleanup "$repo" 22; then fail "a dirty worktree was removed"; fi
[[ -d "$tmp/kept-22" ]] || fail "a dirty worktree is gone"

if MOCK_GH_FAIL=1 run_cleanup "$repo" 20; then fail "a failed GitHub lookup removed a worktree"; fi

# --merged removes exactly the merged worktrees.
repo="$(setup_repo all-merged)"
add_worktree "$repo" feature/30-done all-30
add_worktree "$repo" feature/31-open all-31
merge "$repo" feature/30-done all-30
run_cleanup "$repo" --merged || {
  cat "$repo.out" >&2
  fail "--merged failed"
}
[[ ! -e "$tmp/all-30" ]] || fail "--merged kept a merged worktree"
[[ -d "$tmp/all-31" ]] || fail "--merged removed an unmerged worktree"
grep -Fq "Kept feature/31-open" "$repo.out" || fail "--merged did not report the kept worktree"

# --discard removes an unmerged worktree only after confirmation.
repo="$(setup_repo discard)"
add_worktree "$repo" feature/40-abandoned discard-40
( cd "$repo" && printf 'n\n' | PATH="$tmp/bin:/usr/bin:/bin" MOCK_MERGED_FILE="$repo.merged" ./scripts/cleanup-worktree.sh 40 --discard ) >/dev/null 2>&1 || true
[[ -d "$tmp/discard-40" ]] || fail "--discard removed a worktree without confirmation"
( cd "$repo" && printf 'y\n' | PATH="$tmp/bin:/usr/bin:/bin" MOCK_MERGED_FILE="$repo.merged" ./scripts/cleanup-worktree.sh 40 --discard ) >"$repo.out" 2>&1 || {
  cat "$repo.out" >&2
  fail "--discard with confirmation failed"
}
[[ ! -e "$tmp/discard-40" ]] && ! branch_exists "$repo" feature/40-abandoned || fail "--discard did not remove the worktree and branch"

# Discarding an unmerged planning never removes a description copy: only a
# merged planning has put the description into the repository.
repo="$(setup_repo discard-planning)"
mkdir -p "$repo/docs"
printf 'The project idea.\n' >"$repo/docs/PROJECT_DESCRIPTION.md"
git -C "$repo" add docs/PROJECT_DESCRIPTION.md
git -C "$repo" commit -qm "Earlier planning"
git -C "$repo" push -q origin main
add_worktree "$repo" planning/change-request discard-planning-wt
printf 'The project idea.\n' >"$repo/idea.md"
( cd "$repo" && printf 'y\n' | PATH="$tmp/bin:/usr/bin:/bin" MOCK_MERGED_FILE="$repo.merged" ./scripts/cleanup-worktree.sh planning/change-request --discard ) >"$repo.out" 2>&1 || {
  cat "$repo.out" >&2
  fail "discarding an unmerged planning failed"
}
[[ -f "$repo/idea.md" ]] || fail "discarding an unmerged planning removed a description copy"

# The script runs only from the primary checkout, so it never removes the
# worktree it runs in or one next to it.
repo="$(setup_repo self)"
add_worktree "$repo" feature/50-self self-50
add_worktree "$repo" feature/51-other self-51
merge "$repo" feature/50-self self-50
merge "$repo" feature/51-other self-51
for target in 50 51; do
  if ( cd "$tmp/self-50" && PATH="$tmp/bin:/usr/bin:/bin" MOCK_MERGED_FILE="$repo.merged" ./scripts/cleanup-worktree.sh "$target" ) >"$repo.out" 2>&1; then
    fail "cleanup ran from a linked worktree (target $target)"
  fi
done
[[ -d "$tmp/self-50" && -d "$tmp/self-51" ]] || fail "a worktree was removed when run from a linked worktree"
grep -Fq "primary checkout" "$repo.out" || fail "running from a linked worktree was not explained"

# A worktree that Git refuses to remove is reported as an error and its branch
# is kept.
repo="$(setup_repo locked)"
add_worktree "$repo" feature/60-locked locked-60
merge "$repo" feature/60-locked locked-60
git -C "$repo" worktree lock "$tmp/locked-60"
if run_cleanup "$repo" 60; then fail "a failed removal reported success"; fi
grep -Fq "could not remove the worktree" "$repo.out" || fail "a failed removal was not reported"
branch_exists "$repo" feature/60-locked || fail "the branch was deleted although its worktree remained"
git -C "$repo" worktree unlock "$tmp/locked-60"

# An explicit path also works for a worktree on another kind of branch.
repo="$(setup_repo other-branch)"
add_worktree "$repo" fix/70-typo fix-70
merge "$repo" fix/70-typo fix-70
run_cleanup "$repo" "$tmp/fix-70" || {
  cat "$repo.out" >&2
  fail "cleaning a merged fix/ worktree by path failed"
}
[[ ! -e "$tmp/fix-70" ]] || fail "the merged fix/ worktree was not removed"

# An unknown target fails.
if run_cleanup "$repo" 99; then fail "an unknown target succeeded"; fi

# The run records of a feature are copied to .agents/records/ before its
# worktree goes; a copy that cannot be written keeps the worktree.
repo="$(setup_repo records)"
add_worktree "$repo" feature/41-records records-41
merge "$repo" feature/41-records records-41
(
  cd "$tmp/records-41"
  unset RECORDS_RUN_ID RECORDS_FILE
  source "$source_root/scripts/lib/records.sh"
  records_begin feature 41 run-feature.sh
  records_step "review, round 1 of at most 5" 0 30
  records_end 0
)
mkdir -p "$repo/.agents/records"
chmod 500 "$repo/.agents/records"
if run_cleanup "$repo" 41; then fail "a worktree was removed although its run records could not be copied"; fi
chmod 700 "$repo/.agents/records"
[[ -d "$tmp/records-41" ]] || fail "the worktree is gone although its run records could not be copied"
grep -Fq "its run records could not be copied" "$repo.out" || fail "the failed copy of the run records was not given as the reason"
run_cleanup "$repo" 41 || {
  cat "$repo.out" >&2
  fail "cleaning a worktree with run records failed"
}
[[ ! -d "$tmp/records-41" ]] || fail "the worktree with run records was not removed"
jq -e -s 'any(.type == "step" and .name == "review, round 1 of at most 5")' "$repo/.agents/records/feature-41.jsonl" >/dev/null ||
  fail "the run records of the feature were not copied before the worktree went"

# The branch on GitHub can be ahead of the local one: "Update branch" on the
# pull request merged main into it, and the pull request was merged with that
# head. The local tip is an ancestor of the merged head, so the branch holds
# nothing that was not merged: the worktree is removed. The merged head is
# not in the local repository; it is fetched from the pull request ref.
# update_on_github <repo> <branch> <directory> <number>: merges main into the
# branch in another clone, pushes the result only to refs/pull/<number>/head,
# and records it as the head of the merged pull request.
update_on_github() {
  local other="$tmp/update-$RANDOM"
  local updated

  git clone -q "$(git -C "$1" remote get-url origin)" "$other"
  git -C "$other" config user.name "Cleanup Test"
  git -C "$other" config user.email "cleanup-test@example.com"
  git -C "$other" fetch -q "$tmp/$3" "$2"
  git -C "$other" checkout -q -b updated FETCH_HEAD
  printf 'on main meanwhile\n' >"$other/main-$4.txt"
  git -C "$other" commit -q --allow-empty -m "Merge main into $2"
  updated="$(git -C "$other" rev-parse HEAD)"
  git -C "$other" push -q origin "HEAD:refs/pull/$4/head"
  printf '%s %s %s\n' "$2" "$updated" "$4" >>"$1.merged"
}

repo="$(setup_repo updated-on-github)"
add_worktree "$repo" feature/31-updated updated-31
update_on_github "$repo" feature/31-updated updated-31 7
merged_head="$(awk '{ print $2 }' "$repo.merged")"
if git -C "$repo" cat-file -e "$merged_head^{commit}" 2>/dev/null; then
  fail "the test meant the merged head to be missing locally"
fi
run_cleanup "$repo" 31 || {
  cat "$repo.out" >&2
  fail "a worktree whose tip the merged head contains was kept"
}
[[ ! -d "$tmp/updated-31" ]] || fail "the worktree of a branch updated on GitHub is still there"
if branch_exists "$repo" feature/31-updated; then fail "the branch of a branch updated on GitHub is still there"; fi
grep -Fq "Removed feature/31-updated" "$repo.out" || fail "the removal was not reported"

# The same with --merged, beside a worktree that is not merged.
repo="$(setup_repo updated-on-github-all)"
add_worktree "$repo" feature/32-updated updated-32
update_on_github "$repo" feature/32-updated updated-32 8
add_worktree "$repo" feature/33-open open-33
run_cleanup "$repo" --merged || {
  cat "$repo.out" >&2
  fail "--merged failed with a branch updated on GitHub"
}
[[ ! -d "$tmp/updated-32" ]] || fail "--merged kept a worktree whose tip the merged head contains"
[[ -d "$tmp/open-33" ]] || fail "--merged removed a worktree that is not merged"

# A local commit after the updated head still keeps the worktree.
repo="$(setup_repo updated-then-more)"
add_worktree "$repo" feature/34-more more-34
update_on_github "$repo" feature/34-more more-34 9
printf 'after the merge\n' >>"$tmp/more-34/work.txt"
git -C "$tmp/more-34" commit -qam "Work after the merge"
if run_cleanup "$repo" 34; then fail "a worktree with a commit that the merged head does not contain was removed"; fi
[[ -d "$tmp/more-34" ]] || fail "a worktree with a commit after the merged head is gone"
grep -Fq "it has commits after its merged pull request" "$repo.out" || fail "the commit after the merge was not given as the reason"

# A merged head that cannot be fetched keeps the worktree, and says why.
repo="$(setup_repo head-unknown)"
add_worktree "$repo" feature/35-unknown unknown-35
printf 'feature/35-unknown 0123456789abcdef0123456789abcdef01234567 10\n' >>"$repo.merged"
if run_cleanup "$repo" 35; then fail "a worktree was removed although the merged head could not be fetched"; fi
[[ -d "$tmp/unknown-35" ]] || fail "a worktree whose merged head is unknown is gone"
grep -Fq "could not be fetched from GitHub" "$repo.out" || fail "the unknown merged head was not given as the reason"

echo "cleanup-worktree tests passed"
