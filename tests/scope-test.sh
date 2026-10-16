#!/usr/bin/env bash

set -euo pipefail

# The snapshot that the planning scripts compare before and after an agent
# session: what it covers, what it leaves out, and that it stays fast.

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/scope-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "scope test failed: $*" >&2
  exit 1
}

source "$source_root/scripts/lib/scope.sh"

# The planner's scope: the architecture, the roadmap, and direct ADRs.
allowed() {
  scope_planner_allowed "$1"
}

repo="$tmp/project"
mkdir -p "$repo/docs/decisions" "$repo/.agents/reviews" "$repo/.agents/run" "$repo/.venv/lib" "$repo/src"
printf '.venv/\n.env\n.pytest_cache/\nnode_modules/\n.agents/reviews/*\n.agents/run/\n' >"$repo/.gitignore"
printf '# Architecture\n' >"$repo/docs/architecture.md"
printf '# ADR 001\n' >"$repo/docs/decisions/001-first.md"
printf '# Roadmap\n' >"$repo/docs/roadmap.md"
printf '# Requirements\n' >"$repo/docs/PROJECT_REQUIREMENTS.md"
printf 'print("app")\n' >"$repo/src/app.py"
printf 'x\n' >"$repo/-tracked"
printf '{"round": 1}\n' >"$repo/.agents/reviews/planning-review-01.json"
printf 'final message\n' >"$repo/.agents/run/1-implementer.md"
printf 'TOKEN=secret\n' >"$repo/.env"
for i in $(seq 1 2000); do printf '%s\n' "$i" >"$repo/.venv/lib/module$i.py"; done
git -C "$repo" init -q -b main
git -C "$repo" config user.name "Scope Test"
git -C "$repo" config user.email "scope-test@example.com"
git -C "$repo" add .
git -C "$repo" commit -qm "Seed"

before="$tmp/before.tsv"
scope_snapshot "$repo" allowed "$before"

# expect <description> <reported|unreported> <action> [<restore>] [<path in the difference>]
expect() {
  local description="$1"
  local expected="$2"
  local after="$tmp/after.tsv"

  (cd "$repo" && eval "$3")
  scope_snapshot "$repo" allowed "$after"
  if [[ "$expected" == "reported" ]]; then
    scope_unchanged "$before" "$after" 2>"$tmp/diff" && fail "not reported: $description"
    if [[ -n "${5:-}" ]]; then
      grep -Fq -- "$5" <<<"$(grep -Ev '^(\+\+\+|---) ' "$tmp/diff" | grep -E '^[+-]')" || {
        cat "$tmp/diff" >&2
        fail "the difference does not name $5: $description"
      }
    fi
  else
    scope_unchanged "$before" "$after" 2>"$tmp/diff" || {
      cat "$tmp/diff" >&2
      fail "reported although it may change: $description"
    }
  fi
  # Each case starts from the seed again.
  git -C "$repo" reset -q --hard
  git -C "$repo" clean -q -fd
  (cd "$repo" && eval "${4:-true}")
  scope_snapshot "$repo" allowed "$tmp/reset.tsv"
  cmp -s "$before" "$tmp/reset.tsv" || fail "the test could not restore the seed after: $description"
}

# What a session may change, or leave behind by running a command.
expect "the architecture" unreported "printf 'more\\n' >>docs/architecture.md"
expect "a new ADR" unreported "printf '# ADR\\n' >docs/decisions/013-new.md"
expect "a new test cache, ignored as a whole" unreported "mkdir -p .pytest_cache/v && printf '[]\\n' >.pytest_cache/v/nodeids"
expect "a file inside the Python environment" unreported "printf 'changed\\n' >.venv/lib/module7.py"
expect "a new file in the Python environment" unreported "printf 'new\\n' >.venv/lib/new.py"
expect "a new dependency directory" unreported "mkdir -p node_modules/x && printf 'x\\n' >node_modules/x/index.js"

# What it may not change, ignored or not.
expect "a tracked file outside the scope" reported "printf 'more\\n' >>src/app.py"
expect "the requirements" reported "printf 'more\\n' >>docs/PROJECT_REQUIREMENTS.md"
expect "a new untracked file" reported "printf 'x\\n' >notes.txt"
expect "a deleted tracked file" reported "rm src/app.py"
expect "a changed mode" reported "chmod 755 src/app.py"
expect "a file in a subdirectory of the ADRs" reported "mkdir -p docs/decisions/sub && printf 'x\\n' >docs/decisions/sub/a.md"
expect "a changed ignored file outside an ignored directory" reported "printf 'TOKEN=other\\n' >.env" \
  "printf 'TOKEN=secret\\n' >.env"
expect "a new ignored file outside an ignored directory" reported "printf 'TOKEN=new\\n' >.env.local && printf '.env.local\\n' >>.git/info/exclude" \
  "rm -f .env.local" ".env.local"
expect "a changed review artifact, which Git ignores" reported "printf '{\"round\": 2}\\n' >.agents/reviews/planning-review-01.json" \
  "printf '{\"round\": 1}\\n' >.agents/reviews/planning-review-01.json"
expect "a file in an ignored directory under .agents" reported "printf 'other\\n' >.agents/run/1-implementer.md" \
  "printf 'final message\\n' >.agents/run/1-implementer.md"
expect "a symbolic link" reported "ln -s src/app.py link"
# Names that a command could take for an option or for Git quoting.
expect "a name that starts with a quote" reported "printf 'x\\n' >'\"quoted'" "" '"quoted'
expect "a name that starts with a hyphen" reported "printf 'x\\n' >./-n" "" "-n"
expect "a changed file whose name starts with a hyphen" reported "printf 'y\\n' >./-tracked" \
  "" "-tracked"
expect "a name with a tab" reported "printf 'x\\n' >\$'docs/architecture.md\\textra'"
expect "a name with a newline" reported "printf 'x\\n' >\$'docs/roadmap.md\\nextra'"

# A name with a tab or a newline is written escaped, so it cannot pass for an
# allowed path.
(cd "$repo" && printf 'x\n' >$'docs/roadmap.md\nextra')
scope_snapshot "$repo" allowed "$tmp/odd.tsv"
grep -Fq "\$'docs/roadmap.md\\nextra'" "$tmp/odd.tsv" || fail "a name with a newline was not escaped"
rm "$repo/"$'docs/roadmap.md\nextra'

# The snapshot does not go through an ignored directory. Deterministic: the
# number of commands it starts does not depend on the number of files in the
# Python environment, and none of them is in the snapshot. (It used to start
# three processes per file.)
grep -Fq ".venv" "$before" && fail "the snapshot holds files of an ignored directory"
mkdir -p "$tmp/counting"
cat >"$tmp/counting/git" <<COUNT
#!/usr/bin/env bash
echo git >>"$tmp/calls"
exec "$(command -v git)" "\$@"
COUNT
cat >"$tmp/counting/stat" <<COUNT
#!/usr/bin/env bash
echo stat >>"$tmp/calls"
exec "$(command -v stat)" "\$@"
COUNT
chmod +x "$tmp/counting/git" "$tmp/counting/stat"
calls() {
  : >"$tmp/calls"
  PATH="$tmp/counting:$PATH" scope_snapshot "$repo" allowed "$tmp/counted.tsv"
  grep -c . "$tmp/calls"
}
with_2000="$(calls)"
for i in $(seq 2001 6000); do printf '%s\n' "$i" >"$repo/.venv/lib/module$i.py"; done
with_6000="$(calls)"
[[ "$with_2000" -eq "$with_6000" ]] ||
  fail "the snapshot started $with_2000 commands with 2000 ignored files and $with_6000 with 6000"
rm -rf "$repo/.venv"
without="$(calls)"
[[ "$without" -eq "$with_2000" ]] ||
  fail "the snapshot started $without commands without the ignored directory and $with_2000 with it"
# The run records grow while a session runs and are not content: a new or
# longer record changes nothing in the snapshot.
scope_snapshot "$repo" allowed "$tmp/records-before.tsv"
mkdir -p "$repo/.agents/run/records/.sequence/feature-1" "$repo/.agents/records"
printf '{"type":"run-start"}\n' >"$repo/.agents/run/records/run.jsonl"
ln -s run "$repo/.agents/run/records/.sequence/feature-1/1"
printf '{"type":"run-start"}\n' >"$repo/.agents/records/feature-1.jsonl"
scope_snapshot "$repo" allowed "$tmp/records-after.tsv"
scope_unchanged "$tmp/records-before.tsv" "$tmp/records-after.tsv" 2>"$tmp/diff" || {
  cat "$tmp/diff" >&2
  fail "the run records counted as a change"
}
rm -rf "$repo/.agents/run" "$repo/.agents/records"

# And the time: three snapshots with 6000 ignored files take at most a few
# seconds longer than three without them.
mkdir -p "$repo/.venv/lib"
for i in $(seq 1 6000); do printf '%s\n' "$i" >"$repo/.venv/lib/module$i.py"; done
start="$(date +%s)"
for _ in 1 2 3; do scope_snapshot "$repo" allowed "$tmp/timed.tsv"; done
with_files=$(($(date +%s) - start))
rm -rf "$repo/.venv"
start="$(date +%s)"
for _ in 1 2 3; do scope_snapshot "$repo" allowed "$tmp/timed.tsv"; done
without_files=$(($(date +%s) - start))
[[ "$with_files" -le $((without_files + 3)) ]] ||
  fail "three snapshots took $with_files seconds with 6000 ignored files and $without_files without them"

echo "scope tests passed"
