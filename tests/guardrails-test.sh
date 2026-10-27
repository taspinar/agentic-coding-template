#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/guardrails-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "guardrails test failed: $*" >&2
  exit 1
}

source "$source_root/tests/lib-fakes.sh"

# A project with an ADR, two checks, and a gate configuration, on a feature
# branch without changes.
setup_repo() {
  local repo="$tmp/$1"

  mkdir -p "$repo/docs/decisions" "$repo/site" "$repo/src" "$repo/.agents/policies"
  copy_workflow "$repo"
  printf 'protected: site/_quarto.yml deploy\nsensitive: pyproject.toml docs/architecture.md\n' \
    >"$repo/.agents/policies/guardrails.conf"
  printf '# ADR 001: Quarto\n\nStatus: Accepted\n' >"$repo/docs/decisions/001-quarto.md"
  printf '# Architecture\n' >"$repo/docs/architecture.md"
  printf 'project: site\n' >"$repo/site/_quarto.yml"
  printf '[project]\nname = "x"\n' >"$repo/pyproject.toml"
  printf 'lint: true\nunit: true\n' >"$repo/scripts/verify.conf"
  printf 'print("x")\n' >"$repo/src/code.py"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.name "Guardrails Test"
  git -C "$repo" config user.email "guardrails-test@example.com"
  git -C "$repo" add .
  git -C "$repo" commit -qm "Seed"
  git -C "$repo" switch -q -c feature/5-thing
  printf '%s\n' "$repo"
}

# check <repo> [argument...]: runs the gate; sets 'status' and '<repo>.out'.
check() {
  local repo="$1"

  shift
  status=0
  (cd "$repo" && PATH="/usr/bin:/bin" ./scripts/check-guardrails.sh "$@") >"$repo.out" 2>&1 || status=$?
}

expect_level() {
  local repo="$1"
  local level="$2"
  local description="$3"

  check "$repo"
  [[ "$status" -eq 0 ]] || {
    cat "$repo.out" >&2
    fail "the gate failed although: $description"
  }
  [[ "$(sed -n 1p "$repo.out")" == "level: $level" ]] || {
    cat "$repo.out" >&2
    fail "expected level $level: $description"
  }
}

# Ordinary work of a feature needs nobody.
repo="$(setup_repo plain)"
printf 'print("y")\n' >>"$repo/src/code.py"
printf 'new\n' >"$repo/src/new.py"
expect_level "$repo" none "a feature changes only its own code"

# Every ADR that is added, changed, or removed needs the owner: a new ADR can
# replace an accepted one without touching its file.
repo="$(setup_repo adr-added)"
printf '# ADR 002: Replace Quarto with another generator\n\nStatus: Proposed\n' >"$repo/docs/decisions/002-other.md"
expect_level "$repo" protected "a feature adds an ADR"
grep -Fq "docs/decisions/002-other.md" "$repo.out" || fail "the added ADR was not named"

repo="$(setup_repo adr-changed)"
printf '\nSuperseded.\n' >>"$repo/docs/decisions/001-quarto.md"
expect_level "$repo" protected "a feature changes an accepted ADR"

repo="$(setup_repo adr-removed)"
git -C "$repo" rm -q docs/decisions/001-quarto.md
expect_level "$repo" protected "a feature removes an ADR"

# The paths the project lists: protected needs the owner, sensitive does not.
repo="$(setup_repo listed-protected)"
printf 'project: other\n' >"$repo/site/_quarto.yml"
expect_level "$repo" protected "a feature changes a path the project protects"
grep -Fq "site/_quarto.yml" "$repo.out" || fail "the protected path was not named"

repo="$(setup_repo listed-new-file)"
mkdir -p "$repo/deploy"
printf 'target: elsewhere\n' >"$repo/deploy/config.yml"
expect_level "$repo" protected "a feature adds an untracked file under a protected path"

repo="$(setup_repo listed-sensitive)"
printf 'dependencies = ["y"]\n' >>"$repo/pyproject.toml"
printf '\nMore.\n' >>"$repo/docs/architecture.md"
expect_level "$repo" sensitive "a feature changes sensitive paths only"
grep -Fq "pyproject.toml" "$repo.out" || fail "the sensitive path was not named"

# The verification: adding a check is sensitive, changing or removing one
# is protected.
repo="$(setup_repo check-added)"
printf 'new-check: true\n' >>"$repo/scripts/verify.conf"
expect_level "$repo" sensitive "a feature adds a check"

repo="$(setup_repo check-changed)"
printf 'lint: true\nunit: echo skipped\n' >"$repo/scripts/verify.conf"
expect_level "$repo" protected "a feature changes an existing check"

repo="$(setup_repo check-removed)"
printf 'lint: true\n' >"$repo/scripts/verify.conf"
expect_level "$repo" protected "a feature removes a check"

# A budget ('<name> [<group>] budget: <command>') is a line of the same file:
# making a check a budget or a budget a check changes the line, so it is
# protected as any changed line, and adding a budget check is sensitive.
repo="$(setup_repo check-made-budget)"
printf 'lint: true\nunit budget: true\n' >"$repo/scripts/verify.conf"
expect_level "$repo" protected "a feature makes an existing check a budget"
grep -Fq "protected: scripts/verify.conf (an existing check or line is changed or removed)" "$repo.out" ||
  fail "the changed line was not named for a check made a budget"

repo="$(setup_repo budget-made-check)"
printf 'lint: true\nunit [code] budget: true\n' >"$repo/scripts/verify.conf"
git -C "$repo" commit -qam "Declare a budget"
git -C "$repo" branch -f main HEAD
printf 'lint: true\nunit [code]: true\n' >"$repo/scripts/verify.conf"
expect_level "$repo" protected "a feature makes a budget an ordinary check"

repo="$(setup_repo budget-added)"
printf 'perf budget: true\n' >>"$repo/scripts/verify.conf"
expect_level "$repo" sensitive "a feature adds a budget check"

repo="$(setup_repo checks-deleted)"
rm "$repo/scripts/verify.conf"
expect_level "$repo" protected "a feature deletes the verification configuration"

# A feature cannot relax the rules it is checked by: they are read from its
# base, and the files of the gate are protected themselves.
repo="$(setup_repo rules-relaxed)"
printf 'sensitive: docs/architecture.md\n' >"$repo/.agents/policies/guardrails.conf"
printf 'project: other\n' >"$repo/site/_quarto.yml"
expect_level "$repo" protected "a feature removes a path from the protected list and changes it"
grep -Fq "site/_quarto.yml" "$repo.out" || fail "the rules of the feature were used instead of those of its base"
grep -Fq ".agents/policies/guardrails.conf" "$repo.out" || fail "the changed gate configuration was not named"

for file in scripts/check-guardrails.sh scripts/lib/guardrails.sh scripts/finish-feature.sh \
  scripts/lib/review-run.sh scripts/lib/review-data.sh scripts/lib/agent.sh scripts/review-feature.sh \
  scripts/publish-feature.sh scripts/run-feature.sh scripts/lib/fingerprint.sh \
  scripts/check-risk.sh scripts/lib/risk.sh \
  .agents/prompts/reviewer.md .agents/schemas/review.schema.json .agents/schemas/approval-request.schema.json; do
  repo="$(setup_repo "gate-$(basename "$file")")"
  printf '\n# changed\n' >>"$repo/$file"
  expect_level "$repo" protected "a feature changes $file"
done

# Who reviews is part of the gate too.
repo="$(setup_repo reviewer-changed)"
printf 'reviewer: claude weakest\n' >"$repo/.agents/agents.conf"
expect_level "$repo" protected "a feature changes the configured reviewer"

# A protection that the base got after the feature started applies to the
# feature: the rules are those of the base as it is now.
repo="$(setup_repo protected-later)"
printf 'print("y")\n' >>"$repo/src/code.py"
git -C "$repo" stash -q
git -C "$repo" switch -q main
printf 'protected: site/_quarto.yml deploy src\nsensitive: pyproject.toml docs/architecture.md\n' \
  >"$repo/.agents/policies/guardrails.conf"
git -C "$repo" commit -qam "The owner protects src"
git -C "$repo" switch -q feature/5-thing
git -C "$repo" stash pop -q
expect_level "$repo" protected "the base protects a path after the feature started"
grep -Fq "protected: src/code.py" "$repo.out" || fail "the later protection of the base was not applied"
if grep -Fq "protected: .agents/policies/guardrails.conf" "$repo.out"; then
  fail "the change of the rules on the base was counted as a change of the feature"
fi

# The same when only origin knows the new protection and the local base
# branch is behind: the rules of both count, wherever the diff starts.
repo="$(setup_repo protected-on-origin)"
printf 'print("y")\n' >>"$repo/src/code.py"
git -C "$repo" stash -q
git -C "$repo" switch -q -c ahead main
printf 'protected: src\n' >"$repo/.agents/policies/guardrails.conf"
git -C "$repo" commit -qam "The owner protects src on the remote"
git -C "$repo" update-ref refs/remotes/origin/main ahead
git -C "$repo" switch -q feature/5-thing
git -C "$repo" branch -q -D ahead
git -C "$repo" stash pop -q
expect_level "$repo" protected "origin protects a path while the local base is behind"
grep -Fq "protected: src/code.py" "$repo.out" || fail "the protection that only origin knows was not applied"

# An exclusion that only the stale ref still has does not cancel the
# protection of the other: each ref's rules are applied on their own.
repo="$(setup_repo exclusion-removed)"
printf 'print("y")\n' >>"$repo/src/code.py"
git -C "$repo" stash -q
git -C "$repo" switch -q main
printf 'protected: src :(exclude)src/code.py\n' >"$repo/.agents/policies/guardrails.conf"
git -C "$repo" commit -qam "Protect src, except one file"
git -C "$repo" switch -q -c ahead main
printf 'protected: src\n' >"$repo/.agents/policies/guardrails.conf"
git -C "$repo" commit -qam "The owner removes the exception on the remote"
git -C "$repo" update-ref refs/remotes/origin/main ahead
git -C "$repo" switch -q feature/5-thing
git -C "$repo" branch -q -D ahead
git -C "$repo" rebase -q main
git -C "$repo" stash pop -q
expect_level "$repo" protected "origin removes an exclusion while the local base still has it"
grep -Fq "protected: src/code.py" "$repo.out" || fail "a stale exclusion cancelled the current protection"

repo="$(setup_repo workflow-added)"
mkdir -p "$repo/.github/workflows"
printf 'name: x\n' >"$repo/.github/workflows/extra.yml"
expect_level "$repo" protected "a feature adds a CI workflow"

# The heaviest finding decides, and --fail-on-protected turns it into a status.
repo="$(setup_repo mixed)"
printf 'dependencies = ["y"]\n' >>"$repo/pyproject.toml"
printf 'project: other\n' >"$repo/site/_quarto.yml"
expect_level "$repo" protected "a feature changes a sensitive and a protected path"
check "$repo" --fail-on-protected
[[ "$status" -eq 3 ]] || fail "--fail-on-protected exited with $status for a protected change"
repo="$(setup_repo sensitive-status)"
printf 'dependencies = ["y"]\n' >>"$repo/pyproject.toml"
check "$repo" --fail-on-protected
[[ "$status" -eq 0 ]] || fail "--fail-on-protected failed for a sensitive change"

# Two commits, as CI compares the head of a pull request with its base. The
# base may have moved on: only what the feature changed counts.
repo="$(setup_repo commits)"
printf 'project: other\n' >"$repo/site/_quarto.yml"
git -C "$repo" commit -qam "Change the site configuration"
head="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" switch -q main
printf '# ADR 002: By the owner\n' >"$repo/docs/decisions/002-owner.md"
git -C "$repo" add -A
git -C "$repo" commit -qm "The owner adds an ADR on main"
check "$repo" --commits main "$head" --fail-on-protected
[[ "$status" -eq 3 ]] || fail "the gate did not fail for a protected change between two commits ($status)"
grep -Fq "site/_quarto.yml" "$repo.out" || fail "the protected path between two commits was not named"
if grep -Fq "002-owner.md" "$repo.out"; then fail "work on the base was counted as a change of the feature"; fi

repo="$(setup_repo commits-plain)"
printf 'print("y")\n' >>"$repo/src/code.py"
git -C "$repo" commit -qam "Change the code"
check "$repo" --commits main HEAD --fail-on-protected
[[ "$status" -eq 0 && "$(sed -n 1p "$repo.out")" == "level: none" ]] || fail "ordinary work between two commits was not level none"

# Refusals.
repo="$(setup_repo refusals)"
check "$repo" --commits main
[[ "$status" -eq 2 ]] || fail "--commits with one commit was accepted"
check "$repo" --commits main no-such-commit
[[ "$status" -eq 2 ]] || fail "an unknown commit was accepted"
check "$repo" no-such-base
[[ "$status" -eq 2 ]] || fail "an unknown base branch was accepted"

# The approval requests. finish-feature.sh writes .agents/approval-requests/
# <issue>.json when the owner must approve; the gate checks every request the
# diff adds or changes: its name, its schema, and that its content_tree is the
# content tree the gate recomputes itself, with the exclusion list of the
# base. The request changes nothing else: it can only be refused.
source "$source_root/scripts/lib/fingerprint.sh"
source "$source_root/scripts/lib/guardrails.sh"
scratch="$tmp/scratch"
mkdir -p "$scratch"

# write_request <repo> <content-tree> [<jq-filter>]
write_request() {
  local base

  base="$(git -C "$1" rev-parse main)"
  guardrails_request_write "$1" 5 "$2" feature/5-thing "$(git -C "$1" rev-parse HEAD)" "$base" "" \
    "docs/decisions/002-other.md: an ADR is added, changed, or removed" "Please approve the new ADR."
  if [[ -n "${3:-}" ]]; then
    jq "$3" "$1/.agents/approval-requests/5.json" >"$1/.agents/approval-requests/5.json.tmp" &&
      mv "$1/.agents/approval-requests/5.json.tmp" "$1/.agents/approval-requests/5.json"
  fi
}

# content_tree_of <out-file>: the value the gate printed.
content_tree_of() {
  sed -n 's/^content tree: \([0-9a-f]*\) .*/\1/p' "$1"
}

# commit_feature <repo> <message>: commits the working tree of the feature.
commit_feature() {
  git -C "$1" add -A
  git -C "$1" commit -qm "$2"
}

# A request that names the content tree of the working tree is accepted,
# before and after the commit, and the gate prints the value it recomputed.
repo="$(setup_repo request-accepted)"
printf '# ADR 002: Other\n\nStatus: Proposed\n' >"$repo/docs/decisions/002-other.md"
worktree_tree="$(fingerprint_worktree "$repo" "$scratch")"
write_request "$repo" "$worktree_tree"
[[ -z "$(guardrails_request_errors "$repo/.agents/approval-requests/5.json" "$source_root/.agents/schemas/approval-request.schema.json")" ]] ||
  fail "the request of guardrails_request_write does not follow its schema"
check "$repo"
[[ "$status" -eq 0 ]] || { cat "$repo.out" >&2; fail "a valid request in the working tree was refused ($status)"; }
[[ "$(sed -n 1p "$repo.out")" == "level: protected" ]] || fail "the level with a request is not that of the diff"
[[ "$(content_tree_of "$repo.out")" == "$worktree_tree" ]] || fail "the gate did not print the content tree of the working tree"
grep -Fq "request: .agents/approval-requests/5.json names the content tree recomputed here" "$repo.out" ||
  fail "the accepted request was not reported"
commit_feature "$repo" "Finish the feature"
committed_tree="$(fingerprint_commit "$repo" "$scratch" HEAD)"
[[ "$committed_tree" == "$worktree_tree" ]] || fail "the content tree of the commit is not the one of the working tree"
check "$repo" --commits main HEAD
[[ "$status" -eq 0 ]] || { cat "$repo.out" >&2; fail "a valid committed request was refused ($status)"; }
[[ "$(content_tree_of "$repo.out")" == "$committed_tree" ]] || fail "the gate did not print the content tree of the commit"
grep -Fq "of commit $(git -C "$repo" rev-parse HEAD)" "$repo.out" || fail "the printed content tree does not name the commit"
check "$repo" --commits main HEAD --fail-on-protected
[[ "$status" -eq 3 ]] || fail "a valid request changed the status of a protected diff ($status)"
accepted_output="$(sed 's/of commit [0-9a-f]*/of commit X/' "$repo.out")"
check "$repo" --fail-on-protected
[[ "$status" -eq 3 ]] || fail "a valid request changed the status of a protected working tree ($status)"

# No field but content_tree has any effect: every other field changed, the
# gate prints the same and exits the same.
jq '.explanation = "Something else entirely." | .reasons = ["another reason"] | .commit.branch = "feature/5-other"
    | .commit.parent = "0000000000000000000000000000000000000000" | .commit.base = null
    | .review = {round: 9, verdict: "PASS", reviewer: "nobody (none)"}' \
  "$repo/.agents/approval-requests/5.json" >"$repo/.agents/approval-requests/5.json.tmp"
mv "$repo/.agents/approval-requests/5.json.tmp" "$repo/.agents/approval-requests/5.json"
commit_feature "$repo" "Edit the request"
check "$repo" --commits main HEAD --fail-on-protected
[[ "$status" -eq 3 ]] || { cat "$repo.out" >&2; fail "an edited request changed the status ($status)"; }
[[ "$(sed 's/of commit [0-9a-f]*/of commit X/' "$repo.out")" == "$accepted_output" ]] ||
  { diff <(printf '%s\n' "$accepted_output") "$repo.out" >&2; fail "an edited request changed the output of the gate"; }

# A request whose content_tree is not the recomputed value is refused, with
# status 4 whatever the flags, and the level of the diff is unchanged.
jq '.content_tree = "0123456789012345678901234567890123456789"' "$repo/.agents/approval-requests/5.json" >"$repo/.agents/approval-requests/5.json.tmp"
mv "$repo/.agents/approval-requests/5.json.tmp" "$repo/.agents/approval-requests/5.json"
check "$repo"
[[ "$status" -eq 4 ]] || { cat "$repo.out" >&2; fail "a request with another content tree was not refused ($status)"; }
[[ "$(sed -n 1p "$repo.out")" == "level: protected" ]] || fail "the refused request changed the level"
grep -Fq "refused: .agents/approval-requests/5.json (its content_tree 0123456789012345678901234567890123456789 is not the content tree recomputed here)" "$repo.out" ||
  fail "the mismatch was not reported with both values' roles"
commit_feature "$repo" "Name another tree"
check "$repo" --commits main HEAD
[[ "$status" -eq 4 ]] || fail "a committed request with another content tree was not refused ($status)"
# A removed request is nothing to check.
git -C "$repo" rm -q .agents/approval-requests/5.json
check "$repo"
[[ "$status" -eq 0 ]] || fail "a removed request was checked ($status)"
if grep -Fq "content tree:" "$repo.out"; then fail "the content tree was printed without a request"; fi

# A field the schema does not name, a value outside an enum, a wrong type,
# and a file that is not <issue>.json are refused; an old request of the
# same tree stays in the base and is not checked again.
repo="$(setup_repo request-schema)"
printf '# ADR 002: Other\n\nStatus: Proposed\n' >"$repo/docs/decisions/002-other.md"
write_request "$repo" "$(fingerprint_worktree "$repo" "$scratch")" '.granted = true'
check "$repo"
[[ "$status" -eq 4 ]] || fail "a request with an extra field was not refused ($status)"
grep -Fq "request.granted is not a field of the schema" "$repo.out" || fail "the extra field was not named"
write_request "$repo" "$(fingerprint_worktree "$repo" "$scratch")" '.schema = "approval-request/v0"'
check "$repo"
[[ "$status" -eq 4 ]] || fail "a request with a schema outside the enum was not refused ($status)"
grep -Fq "request.schema must be one of approval-request/v1" "$repo.out" || fail "the value outside the enum was not named"
write_request "$repo" "$(fingerprint_worktree "$repo" "$scratch")" '.reasons = "one"'
check "$repo"
[[ "$status" -eq 4 ]] || fail "a request with a wrong type was not refused ($status)"
grep -Fq "request.reasons must be array, not string" "$repo.out" || fail "the wrong type was not named"
write_request "$repo" "$(fingerprint_worktree "$repo" "$scratch")"
printf 'not a request\n' >"$repo/.agents/approval-requests/notes.md"
check "$repo"
[[ "$status" -eq 4 ]] || fail "a file that is not <issue>.json was accepted ($status)"
grep -Fq "refused: .agents/approval-requests/notes.md (only <issue>.json may be under .agents/approval-requests/)" "$repo.out" ||
  fail "the stray file was not refused by name"
grep -Fq "request: .agents/approval-requests/5.json names" "$repo.out" || fail "the valid request next to the stray file was not accepted"
rm "$repo/.agents/approval-requests/notes.md"
printf '{"schema": "approval-request/v1"} {}\n' >"$repo/.agents/approval-requests/5.json"
check "$repo"
[[ "$status" -eq 4 ]] || fail "a file with two JSON values was accepted ($status)"
grep -Fq "not exactly one JSON value" "$repo.out" || fail "the malformed request was not explained"

# The exclusion list is read from the base: a feature that extends the list
# in its own fingerprint.sh and names the tree computed with it is refused,
# and the changed library is reported as protected. The tree computed with
# the base's list is accepted.
repo="$(setup_repo request-exclusion)"
printf '# ADR 002: Other\n\nStatus: Proposed\n' >"$repo/docs/decisions/002-other.md"
mkdir -p "$repo/.agents/extra"
printf 'hidden\n' >"$repo/.agents/extra/payload"
sed -i 's|^FINGERPRINT_EXCLUDES=(\(.*\))$|FINGERPRINT_EXCLUDES=(\1 ".agents/extra")|' "$repo/scripts/lib/fingerprint.sh"
extended_tree="$(
  source "$repo/scripts/lib/fingerprint.sh"
  fingerprint_worktree "$repo" "$scratch"
)"
base_tree="$(fingerprint_worktree "$repo" "$scratch")"
[[ "$extended_tree" != "$base_tree" ]] || fail "the extended exclusion list did not change the fingerprint of the feature"
write_request "$repo" "$extended_tree"
check "$repo"
[[ "$status" -eq 4 ]] || { cat "$repo.out" >&2; fail "a request computed with an exclusion the feature added was accepted ($status)"; }
[[ "$(content_tree_of "$repo.out")" == "$base_tree" ]] || fail "the gate did not compute the content tree with the list of the base"
grep -Fq "protected: scripts/lib/fingerprint.sh" "$repo.out" || fail "the changed exclusion list was not reported as protected"
write_request "$repo" "$base_tree"
check "$repo"
[[ "$status" -eq 0 ]] || { cat "$repo.out" >&2; fail "a request computed with the list of the base was refused ($status)"; }
commit_feature "$repo" "Try an exclusion"
check "$repo" --commits main HEAD
[[ "$status" -eq 0 ]] || { cat "$repo.out" >&2; fail "the committed request with the base's tree was refused ($status)"; }
[[ "$(content_tree_of "$repo.out")" == "$base_tree" ]] || fail "the gate did not compute the content tree of the commit with the list of the base"

# A merge of the base after the finish is passed over: the request names
# the content tree of the finish commit, which the gate recomputes from that
# commit and says so. Any other commit after the finish is the content.
repo="$(setup_repo request-base-merged)"
printf '# ADR 002: Other\n\nStatus: Proposed\n' >"$repo/docs/decisions/002-other.md"
finish_tree="$(fingerprint_worktree "$repo" "$scratch")"
write_request "$repo" "$finish_tree"
commit_feature "$repo" "Finish the feature"
finish="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" switch -q main
printf 'meanwhile\n' >"$repo/src/other.py"
git -C "$repo" add src/other.py
git -C "$repo" commit -qm "Meanwhile on main"
git -C "$repo" switch -q feature/5-thing
git -C "$repo" merge -q --no-ff --no-edit main
check "$repo" --commits main HEAD
[[ "$status" -eq 0 ]] || { cat "$repo.out" >&2; fail "a request was refused after a merge of the base ($status)"; }
grep -Fq "of the finish commit $finish, before the merges of the base" "$repo.out" || fail "the gate did not say that it checked the finish commit"
[[ "$(content_tree_of "$repo.out")" == "$finish_tree" ]] || fail "the content tree after a merge of the base is not that of the finish commit"
printf 'later\n' >>"$repo/src/code.py"
commit_feature "$repo" "A change after the finish"
check "$repo" --commits main HEAD
[[ "$status" -eq 4 ]] || fail "a commit after the finish kept the request valid ($status)"

echo "guardrails tests passed"
