#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/sync-template-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "sync-template test failed: $*" >&2
  exit 1
}

commit_all() {
  git -C "$1" add -A
  git -C "$1" -c user.name="Sync Test" -c user.email="sync-test@example.com" commit -qm "$2"
}

lines() {
  printf '%s\n' "$@"
}

# A template with two versions. From the first to the second it changes a
# file in three ways, adds one, removes one, and changes a file it does not
# own.
template="$tmp/template"
mkdir -p "$template/scripts" "$template/docs" "$template/.agents"
git -C "$template" init -q -b main
lines "repository: $template" "" "paths: scripts docs/guide.md .agents/template.conf :(exclude)scripts/local.sh" \
  >"$template/.agents/template.conf"
cp "$source_root/scripts/sync-template.sh" "$template/scripts/sync-template.sh"
lines "#!/usr/bin/env bash" "echo untouched one" >"$template/scripts/untouched.sh"
lines "top" "a" "b" "c" "middle" "d" "e" "f" "bottom" >"$template/scripts/both.sh"
lines "first" "contested" "last" >"$template/scripts/conflict.sh"
lines "to be removed" >"$template/scripts/gone.sh"
lines "becomes executable" >"$template/scripts/make-exec.sh"
lines "stops being executable" >"$template/scripts/drop-exec.sh"
chmod +x "$template/scripts/drop-exec.sh"
lines "template readme, before version one" >"$template/README.md"
lines "guide" >"$template/docs/guide.md"
chmod +x "$template/scripts/untouched.sh"
# An earlier version that differs only in a file the project replaced, so it
# matches the project exactly as well as version one does.
commit_all "$template" "Version zero"
lines "template readme" >"$template/README.md"
commit_all "$template" "Version one"
version_one="$(git -C "$template" rev-parse HEAD)"

lines "#!/usr/bin/env bash" "echo untouched two" >"$template/scripts/untouched.sh"
lines "top" "a" "b" "c" "middle" "d" "e" "f" "bottom changed by the template" >"$template/scripts/both.sh"
lines "first" "contested by the template" "last" >"$template/scripts/conflict.sh"
lines "#!/usr/bin/env bash" "echo new" >"$template/scripts/new.sh"
chmod +x "$template/scripts/new.sh"
lines "excluded" >"$template/scripts/local.sh"
git -C "$template" rm -q scripts/gone.sh
chmod +x "$template/scripts/make-exec.sh"
chmod -x "$template/scripts/drop-exec.sh"
lines "template readme, second version" >"$template/README.md"
# The sync script itself changes too, in length, while a sync runs it.
{
  sed -n 1p "$source_root/scripts/sync-template.sh"
  for number in $(seq 1 400); do echo "# line $number added in version two"; done
  sed 1d "$source_root/scripts/sync-template.sh"
} >"$template/scripts/sync-template.sh"
commit_all "$template" "Version two"
version_two="$(git -C "$template" rev-parse HEAD)"

# A later version on its own branch, which changes only one template file.
git -C "$template" switch -q -c three
lines "top" "a" "b" "c" "middle changed in version three" "d" "e" "f" "bottom changed by the template" >"$template/scripts/both.sh"
commit_all "$template" "Version three"
version_three="$(git -C "$template" rev-parse HEAD)"
git -C "$template" switch -q main

# A branch on which a template file changes and is changed back.
git -C "$template" switch -q -c reverted
lines "first" "contested, changed for a while" "last" >"$template/scripts/conflict.sh"
commit_all "$template" "Change a file"
changed_for_a_while="$(git -C "$template" rev-parse HEAD)"
lines "first" "contested by the template" "last" >"$template/scripts/conflict.sh"
commit_all "$template" "Change the file back"
git -C "$template" switch -q main

# A project created from version one (or the given version), without the
# template's history, that changed some template files and has files of its
# own.
setup_project() {
  local project="$tmp/$1"

  mkdir -p "$project"
  git -C "$template" archive "${2:-$version_one}" | tar -x -C "$project"
  git -C "$project" init -q -b main
  commit_all "$project" "Create the project from the template"
  sed 's/^top$/top changed by the project/' "$project/scripts/both.sh" >"$project/both.tmp"
  mv "$project/both.tmp" "$project/scripts/both.sh"
  lines "first" "contested by the project" "last" >"$project/scripts/conflict.sh"
  lines "project readme" >"$project/README.md"
  mkdir -p "$project/src"
  lines "project code" >"$project/src/app.txt"
  lines "project script" >"$project/scripts/local.sh"
  commit_all "$project" "Project work"
  printf '%s\n' "$project"
}

run_sync() {
  local project="$1"

  shift
  (cd "$project" && PATH="/usr/bin:/bin" ./scripts/sync-template.sh "$@") >"$project.out" 2>&1
}

# Without a recorded version the base is found from the files: the newest of
# the template versions that match the project best. Each kind of change is
# handled. A conflict fails the run after everything else is done.
project="$(setup_project sync)"
head_before="$(git -C "$project" rev-parse HEAD)"
if run_sync "$project"; then
  cat "$project.out" >&2
  fail "a sync that leaves a conflict returned success"
fi
grep -Fq "matches template commit ${version_one:0:7} best" "$project.out" || {
  cat "$project.out" >&2
  fail "the template version of the project was not found"
}
[[ "$(git -C "$project" branch --show-current)" == "fix/sync-template-${version_two:0:7}" ]] ||
  fail "the sync did not create a branch from main"
[[ "$(git -C "$project" rev-parse HEAD)" == "$head_before" ]] || fail "the sync created a commit"

grep -Fqx "echo untouched two" "$project/scripts/untouched.sh" || fail "an unchanged file was not replaced"
[[ -x "$project/scripts/untouched.sh" ]] || fail "a replaced file lost its executable bit"
[[ "$(tr '\n' ' ' <"$project/scripts/both.sh")" == "top changed by the project a b c middle d e f bottom changed by the template " ]] ||
  fail "changes of both sides were not merged"
grep -Fq "<<<<<<< project" "$project/scripts/conflict.sh" || fail "a conflict was not marked in the file"
grep -Fq "contested by the project" "$project/scripts/conflict.sh" || fail "the project's side of a conflict was lost"
grep -Fq "contested by the template" "$project/scripts/conflict.sh" || fail "the template's side of a conflict is missing"
[[ -x "$project/scripts/new.sh" ]] || fail "a new template file was not added as an executable"
[[ -x "$project/scripts/make-exec.sh" ]] || fail "a file the template made executable is not executable"
[[ ! -x "$project/scripts/drop-exec.sh" ]] || fail "a file the template made non-executable is still executable"
[[ -f "$project/scripts/gone.sh" ]] || fail "a file the template removed was deleted"
grep -Fq "scripts/gone.sh: removed from the template" "$project.out" || fail "a removed template file was not reported"
grep -Eq "^  scripts/conflict.sh$" "$project.out" || fail "the conflict was not reported"

# Files outside the template's list are the project's own.
grep -Fqx "project readme" "$project/README.md" || fail "a file the template does not own was changed"
grep -Fqx "project code" "$project/src/app.txt" || fail "a project file was changed"
grep -Fqx "project script" "$project/scripts/local.sh" || fail "an excluded file was overwritten"

grep -Fqx "commit: $version_two" "$project/.agents/template.conf" || fail "the new template version was not recorded"
grep -Fq "Version two" "$project.out" || fail "the template's changes were not listed"
# The script replaced itself while running and still finished.
grep -Fqx "# line 400 added in version two" "$project/scripts/sync-template.sh" || fail "the sync script was not updated"
grep -Fq "Push the branch and open a pull request." "$project.out" || fail "the sync did not finish after replacing its own script"
if compgen -G "$project/scripts/*.sync-template.*" >/dev/null; then fail "a staging file was left behind"; fi

# With the version recorded, a second sync has nothing to do and changes nothing.
git -C "$project" checkout -q -- scripts/conflict.sh
commit_all "$project" "Sync"
before="$(git -C "$project" rev-parse HEAD)$(git -C "$project" status --porcelain)"
run_sync "$project" || fail "a second sync failed"
grep -Fq "Already up to date" "$project.out" || fail "a second sync was not reported as up to date"
[[ "$(git -C "$project" rev-parse HEAD)$(git -C "$project" status --porcelain)" == "$before" ]] ||
  fail "a second sync changed something"

# Without a conflict the sync succeeds; --from and --to select the versions.
project="$(setup_project clean)"
git -C "$project" checkout -q HEAD~1 -- scripts/conflict.sh
commit_all "$project" "Drop the conflicting change"
git -C "$project" switch -q -c chore/sync
run_sync "$project" --from "$version_one" --to "$version_two" || {
  cat "$project.out" >&2
  fail "a sync without conflicts failed"
}
[[ "$(git -C "$project" branch --show-current)" == "chore/sync" ]] || fail "the sync left the current branch"
grep -Fqx "contested by the template" "$project/scripts/conflict.sh" || fail "an unchanged file was not replaced with --from"
if grep -Fq "best" "$project.out"; then fail "--from did not replace the search for a base"; fi

# The project decides what is its own: a file it excludes in its own list is
# not taken over, although the template lists it. A template file that the
# project replaced with a symbolic link is not written through.
project="$(setup_project owned)"
git -C "$project" checkout -q HEAD~1 -- scripts/conflict.sh
sed 's|^paths: .*|& :(exclude)scripts/untouched.sh|' "$project/.agents/template.conf" >"$project/conf.tmp"
mv "$project/conf.tmp" "$project/.agents/template.conf"
rm "$project/scripts/new.sh" 2>/dev/null || true
ln -s ../src/app.txt "$project/scripts/new.sh"
commit_all "$project" "Own a script and link another"
run_sync "$project" || {
  cat "$project.out" >&2
  fail "a sync with a project exclusion failed"
}
grep -Fqx "echo untouched one" "$project/scripts/untouched.sh" || fail "a file the project excludes was taken over"
[[ -L "$project/scripts/new.sh" ]] || fail "a symbolic link in the project was replaced"
grep -Fqx "project code" "$project/src/app.txt" || fail "the sync wrote through a symbolic link"
grep -Fq "scripts/new.sh: is, or lies under, a symbolic link" "$project.out" || fail "the symbolic link was not reported"

# When several template versions match the project equally well and differ in
# template files, the base is not guessed: taking the newest would skip a
# template change to a file the project changed too.
project="$(setup_project ambiguous "$version_two")"
if run_sync "$project" --to three; then
  cat "$project.out" >&2
  fail "an ambiguous template version was guessed"
fi
grep -Fq "cannot be determined" "$project.out" || fail "the ambiguity was not reported"
grep -Fq "${version_two:0:7}" "$project.out" || fail "the candidate versions were not listed"
[[ -z "$(git -C "$project" status --porcelain)" && "$(git -C "$project" branch --show-current)" == "main" ]] ||
  fail "an ambiguous sync changed the project"
run_sync "$project" --to three --from "$version_two" || {
  cat "$project.out" >&2
  fail "a sync with an explicit base failed"
}
[[ "$(tr '\n' ' ' <"$project/scripts/both.sh")" == "top changed by the project a b c middle changed in version three d e f bottom changed by the template " ]] ||
  fail "the template change was not merged with an explicit base"
grep -Fqx "commit: $version_three" "$project/.agents/template.conf" || fail "the version was not recorded"

# The same holds when the equally good versions lie between two that are
# identical: a file that changed and was changed back.
project="$(setup_project reverted "$changed_for_a_while")"
if run_sync "$project" --to reverted; then
  cat "$project.out" >&2
  fail "a version between a change and its revert was guessed"
fi
grep -Fq "cannot be determined" "$project.out" || fail "the ambiguity around a revert was not reported"

# A project that already has the target version, but no record of it, gets
# the record and nothing else.
project="$tmp/unrecorded"
mkdir -p "$project"
git -C "$template" archive "$version_two" | tar -x -C "$project"
git -C "$project" init -q -b main
commit_all "$project" "Create the project from the template"
run_sync "$project" || {
  cat "$project.out" >&2
  fail "recording the version of an up-to-date project failed"
}
[[ "$(git -C "$project" status --porcelain)" == " M .agents/template.conf" ]] ||
  fail "recording the version changed more than the configuration"
grep -Fqx "commit: $version_two" "$project/.agents/template.conf" || fail "the version was not recorded"
[[ "$(git -C "$project" branch --show-current)" != "main" ]] || fail "the version was recorded on main"

# A sync from another location, such as a fork, records that location, so
# the next sync continues from there without the option.
fork="$tmp/fork"
git clone -q "$template" "$fork" 2>/dev/null
lines "#!/usr/bin/env bash" "echo untouched in the fork" >"$fork/scripts/untouched.sh"
commit_all "$fork" "Fork change"
project="$tmp/forked"
mkdir -p "$project"
git -C "$template" archive "$version_two" | tar -x -C "$project"
git -C "$project" init -q -b main
commit_all "$project" "Create the project from the template"
run_sync "$project" --template "$fork" --from "$version_two" || {
  cat "$project.out" >&2
  fail "a sync from a fork failed"
}
grep -Fqx "echo untouched in the fork" "$project/scripts/untouched.sh" || fail "the fork's change was not taken over"
grep -Fqx "repository: $fork" "$project/.agents/template.conf" || fail "the fork was not recorded as the template"
commit_all "$project" "Sync from the fork"
run_sync "$project" || {
  cat "$project.out" >&2
  fail "the next sync did not continue from the recorded fork"
}
grep -Fq "Already up to date" "$project.out" || fail "the next sync from the fork was not up to date"

# Switching to another location that is at the recorded commit records the
# location, although no file changes.
same="$tmp/same-fork"
git clone -q "$fork" "$same" 2>/dev/null
run_sync "$project" --template "$same" || {
  cat "$project.out" >&2
  fail "switching to a location at the same commit failed"
}
grep -Fqx "repository: $same" "$project/.agents/template.conf" || fail "the new location at the same commit was not recorded"

# The configuration is written by the sync, so a linked configuration file or
# a linked .agents directory stops it before anything changes.
project="$(setup_project linked-config)"
rm "$project/.agents/template.conf"
ln -s ../src/app.txt "$project/.agents/template.conf"
commit_all "$project" "Link the configuration"
if run_sync "$project" --template "$template"; then fail "a linked configuration file was accepted"; fi
grep -Fqx "project code" "$project/src/app.txt" || fail "the sync wrote through a linked configuration file"
[[ -z "$(git -C "$project" status --porcelain)" ]] || fail "a refused sync changed the project"

project="$(setup_project linked-directory)"
mv "$project/.agents" "$project/agents-elsewhere"
ln -s agents-elsewhere "$project/.agents"
commit_all "$project" "Link the directory"
if run_sync "$project"; then fail "a linked .agents directory was accepted"; fi
[[ -z "$(git -C "$project" status --porcelain)" ]] || fail "a refused sync changed the project"

# Uncommitted changes, an unknown version, and an unknown option are refused
# before anything changes.
project="$(setup_project refused)"
printf 'uncommitted\n' >>"$project/README.md"
if run_sync "$project"; then fail "a checkout with uncommitted changes was synced"; fi
git -C "$project" checkout -q -- README.md
if run_sync "$project" --to no-such-version; then fail "an unknown template version was accepted"; fi
if run_sync "$project" --from 0123456789012345678901234567890123456789; then fail "an unknown base commit was accepted"; fi
if run_sync "$project" --everything; then fail "an unknown option was accepted"; fi
if run_sync "$project" --template "$tmp/no-such-template"; then fail "a missing template was accepted"; fi
[[ -z "$(git -C "$project" status --porcelain)" ]] || fail "a refused sync changed the project"
[[ "$(git -C "$project" branch --show-current)" == "main" ]] || fail "a refused sync created a branch"

echo "sync-template tests passed"
