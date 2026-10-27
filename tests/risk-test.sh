#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/risk-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "risk test failed: $*" >&2
  exit 1
}

source "$source_root/tests/lib-fakes.sh"

# A project with documentation, code, an existing test, a manifest, two
# checks, and the workflow, on a feature branch without changes. The second
# argument is the risk policy of the base: 'template' for the file the
# template ships, 'none' for a base without one, or the content of the file.
# setup_repo <label> <policy>
setup_repo() {
  local repo="$tmp/$1"

  mkdir -p "$repo/docs" "$repo/src" "$repo/tests" "$repo/spec" "$repo/.agents/policies"
  copy_workflow "$repo"
  cp "$source_root/.gitignore" "$repo/.gitignore"
  case "$2" in
    template) cp "$source_root/.agents/policies/risk.conf" "$repo/.agents/policies/risk.conf" ;;
    none) ;;
    *) printf '%s\n' "$2" >"$repo/.agents/policies/risk.conf" ;;
  esac
  printf '# Guide\n' >"$repo/docs/guide.md"
  printf 'print("x")\n' >"$repo/src/code.py"
  printf 'exit 0\n' >"$repo/tests/unit-test.sh"
  printf 'exit 0\n' >"$repo/spec/unit_spec.rb"
  printf '{"name": "x"}\n' >"$repo/package.json"
  printf 'lint: true\nunit: true\n' >"$repo/scripts/verify.conf"
  printf 'paths: scripts\nself: true\n' >"$repo/scripts/verify-workflow.conf"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.name "Risk Test"
  git -C "$repo" config user.email "risk-test@example.com"
  git -C "$repo" add .
  git -C "$repo" commit -qm "Seed"
  git -C "$repo" switch -q -c feature/5-thing
  printf '%s\n' "$repo"
}

# check <repo> [argument...]: runs check-risk.sh; sets 'status' and '<repo>.out'.
check() {
  local repo="$1"

  shift
  status=0
  (cd "$repo" && PATH="/usr/bin:/bin" ./scripts/check-risk.sh "$@") >"$repo.out" 2>&1 || status=$?
}

# expect_level <repo> <level> <description> [argument...]
# The first line names the level and the exit status encodes it.
expect_level() {
  local repo="$1"
  local level="$2"
  local description="$3"
  local expected

  shift 3
  case "$level" in
    low) expected=0 ;;
    medium) expected=1 ;;
    high) expected=2 ;;
  esac
  check "$repo" "$@"
  [[ "$(sed -n 1p "$repo.out")" == "risk: $level" ]] || {
    cat "$repo.out" >&2
    fail "expected level $level: $description"
  }
  [[ "$status" -eq "$expected" ]] || {
    cat "$repo.out" >&2
    fail "expected exit status $expected for $level, got $status: $description"
  }
}

expect_reason() {
  grep -Fq -- "$2" "$1.out" || {
    cat "$1.out" >&2
    fail "$3"
  }
}

# set_record <repo> <risk>: the implementer's completion record of the Issue
# with that risk claim.
set_record() {
  mkdir -p "$1/.agents/completion"
  jq -n --arg risk "$2" '{schema: "completion/v1", status: "complete",
    criteria: [{criterion: "It works", status: "met", evidence: "tests"}], remaining: [], risk: $risk}' \
    >"$1/.agents/completion/5.json"
}

# set_review <repo> <impact>: a review of the feature whose classification of
# the impact on the architecture is <impact>.
set_review() {
  mkdir -p "$1/.agents/reviews"
  jq -n --arg level "$2" '{schema: "review/v1", kind: "feature", issue: 5, round: 1,
    branch: "feature/5-thing", base: "main", merge_base: "aaaa", head: "bbbb", reviewed_tree: "cccc",
    reviewed_paths: null, reviewer: {agent: "claude", model: "m"}, created_at: "2026-01-01T00:00:00Z",
    verdict: "PASS", limitations: "", findings: [],
    architecture_impact: {level: $level, rationale: "Because.", checked_against: []}}' \
    >"$1/.agents/reviews/feature-5-thing-review-01.json"
}

# The file the template ships: no low class, so every feature is medium or
# high; the files of the workflow and its gate are high, named as the reason.
repo="$(setup_repo template-docs template)"
printf 'More.\n' >>"$repo/docs/guide.md"
expect_level "$repo" medium "the template classifies a documentation change as medium"
expect_reason "$repo" "docs/guide.md: no class of .agents/policies/risk.conf names it; the default is medium" \
  "the default was not given as the reason"

repo="$(setup_repo template-gate template)"
printf '\n# changed\n' >>"$repo/scripts/finish-feature.sh"
expect_level "$repo" high "the template classifies a change to finish-feature.sh as high"
expect_reason "$repo" "scripts/finish-feature.sh: listed as high in .agents/policies/risk.conf" "the path was not given as the reason"

# A base without the file behaves like the template: nothing changes for a
# project until it configures the policy.
repo="$(setup_repo none-docs none)"
printf 'More.\n' >>"$repo/docs/guide.md"
expect_level "$repo" medium "a project without a policy classifies a documentation change as medium"

repo="$(setup_repo none-gate none)"
printf '\n# changed\n' >>"$repo/scripts/finish-feature.sh"
expect_level "$repo" high "a project without a policy classifies a change to finish-feature.sh as high"
expect_reason "$repo" "scripts/finish-feature.sh" "the path was not given as the reason"

# The classes of a project, and the maximum rule: a low path with a medium
# path is medium.
project_policy='default: medium
low: docs
high: src/auth'
repo="$(setup_repo project-low "$project_policy")"
printf 'More.\n' >>"$repo/docs/guide.md"
expect_level "$repo" low "a project class makes a documentation-only feature low"
expect_reason "$repo" "docs/guide.md: listed as low in .agents/policies/risk.conf" "the class was not given as the reason"

repo="$(setup_repo project-mixed "$project_policy")"
printf 'More.\n' >>"$repo/docs/guide.md"
printf 'print("y")\n' >>"$repo/src/code.py"
expect_level "$repo" medium "a documentation change with a medium path is medium"
expect_reason "$repo" "src/code.py" "the medium path was not given as the reason"
if grep -Fq "docs/guide.md" "$repo.out"; then fail "a low path was given as a reason for medium"; fi

repo="$(setup_repo project-high "$project_policy")"
mkdir -p "$repo/src/auth"
printf 'login\n' >"$repo/src/auth/login.py"
printf 'More.\n' >>"$repo/docs/guide.md"
expect_level "$repo" high "an untracked file under a high class is high"
expect_reason "$repo" "src/auth/login.py: listed as high" "the high path was not given as the reason"

# A path in two classes gets the higher one.
repo="$(setup_repo project-overlap "$(printf 'default: low\nlow: docs\nhigh: docs/guide.md')")"
printf 'More.\n' >>"$repo/docs/guide.md"
expect_level "$repo" high "a path in the low and the high class is high"

# The fixed escalations, each on a policy that would otherwise make
# everything low.
lenient='default: low'
repo="$(setup_repo check-changed "$lenient")"
printf 'lint: true\nunit: echo skipped\n' >"$repo/scripts/verify.conf"
expect_level "$repo" high "a changed check escalates"
expect_reason "$repo" "scripts/verify.conf: a check or a line of the verification configuration is changed or removed" \
  "the changed check was not given as the reason"

repo="$(setup_repo check-removed "$lenient")"
printf 'lint: true\n' >"$repo/scripts/verify.conf"
expect_level "$repo" high "a removed check escalates"

repo="$(setup_repo workflow-check-changed "$lenient")"
printf 'paths: scripts\nself: echo skipped\n' >"$repo/scripts/verify-workflow.conf"
expect_level "$repo" high "a changed workflow self-test escalates"
expect_reason "$repo" "scripts/verify-workflow.conf" "the changed self-test list was not given as the reason"

repo="$(setup_repo check-added "$lenient")"
printf 'new-check: true\n' >>"$repo/scripts/verify.conf"
expect_level "$repo" low "an added check does not escalate"

repo="$(setup_repo test-changed "$lenient")"
printf 'exit 1\n' >>"$repo/tests/unit-test.sh"
expect_level "$repo" high "a change to an existing test file escalates"
expect_reason "$repo" "tests/unit-test.sh: an existing test file is changed" "the test file was not given as the reason"

repo="$(setup_repo test-removed "$lenient")"
git -C "$repo" rm -q tests/unit-test.sh
expect_level "$repo" high "a removed test file escalates"

repo="$(setup_repo test-added "$lenient")"
printf 'exit 0\n' >"$repo/tests/new-test.sh"
expect_level "$repo" low "a new, standalone test file does not escalate"
repo="$(setup_repo test-added-committed "$lenient")"
printf 'exit 0\n' >"$repo/tests/new-test.sh"
git -C "$repo" add tests/new-test.sh
git -C "$repo" commit -qm "Add a test"
printf 'exit 0\n' >>"$repo/tests/new-test.sh"
expect_level "$repo" low "a test file the feature itself added is new, also when it changes it again"

# The project names its test files; then the built-in names do not apply.
repo="$(setup_repo tests-named "$(printf 'default: low\ntests: spec')")"
printf 'exit 1\n' >>"$repo/spec/unit_spec.rb"
expect_level "$repo" high "a change to a test file the project names escalates"
expect_reason "$repo" "spec/unit_spec.rb" "the named test file was not given as the reason"
repo="$(setup_repo tests-named-other "$(printf 'default: low\ntests: spec')")"
printf 'exit 1\n' >>"$repo/tests/unit-test.sh"
expect_level "$repo" low "a file outside the named test files is not a test file"

for path in .agents/prompts/implementer.md .agents/policies/autonomy.md; do
  repo="$(setup_repo "contract-$(basename "$path")" "$lenient")"
  mkdir -p "$repo/$(dirname "$path")"
  printf '\nChanged.\n' >>"$repo/$path"
  expect_level "$repo" high "a change to $path escalates"
  expect_reason "$repo" "$path: a policy, an agent contract, or a schema is changed" "$path was not given as the reason"
done
repo="$(setup_repo schema-added "$lenient")"
printf '{}\n' >"$repo/.agents/schemas/extra.schema.json"
expect_level "$repo" high "an added schema escalates"

repo="$(setup_repo manifest "$(printf 'default: low\nmanifests: package.json')")"
printf '{"name": "x", "dependencies": {"left-pad": "1"}}\n' >"$repo/package.json"
expect_level "$repo" high "a change to a named manifest escalates"
expect_reason "$repo" "package.json: a dependency or toolchain manifest is changed" "the manifest was not given as the reason"
repo="$(setup_repo manifest-unnamed "$lenient")"
printf '{"name": "y"}\n' >"$repo/package.json"
expect_level "$repo" low "a manifest the project does not name is an ordinary path"

# The rules are read from the base. A feature that adds its own paths to the
# low class is classified by the base's file, and is high because it changed
# the policy.
repo="$(setup_repo rules-relaxed "$(printf 'default: medium\nhigh: src')")"
printf 'default: low\nlow: src .agents\n' >"$repo/.agents/policies/risk.conf"
printf 'print("y")\n' >>"$repo/src/code.py"
expect_level "$repo" high "a feature that relaxes the policy is classified by the base's policy"
expect_reason "$repo" "src/code.py: listed as high in .agents/policies/risk.conf" "the base's class was not applied"
expect_reason "$repo" ".agents/policies/risk.conf: the risk policy itself is changed" "the changed policy was not given as the reason"

# A policy that only origin knows applies too, while the local base is behind.
repo="$(setup_repo rules-on-origin "$lenient")"
printf 'print("y")\n' >>"$repo/src/code.py"
git -C "$repo" stash -q
git -C "$repo" switch -q -c ahead main
printf 'default: low\nhigh: src\n' >"$repo/.agents/policies/risk.conf"
git -C "$repo" commit -qam "The owner classifies src as high on the remote"
git -C "$repo" update-ref refs/remotes/origin/main ahead
git -C "$repo" switch -q feature/5-thing
git -C "$repo" branch -q -D ahead
git -C "$repo" stash pop -q
expect_level "$repo" high "a class that only origin knows applies"
if grep -Fq "risk.conf: the risk policy itself is changed" "$repo.out"; then
  fail "the change of the policy on the base was counted as a change of the feature"
fi

# What the agents record. The implementer can raise the level, never lower
# it: a claim below the computed level is ignored and reported.
repo="$(setup_repo record-raises "$project_policy")"
printf 'More.\n' >>"$repo/docs/guide.md"
set_record "$repo" high
expect_level "$repo" high "the implementer's record raises the level"
expect_reason "$repo" "the implementer recorded risk: high in the completion record" "the record was not given as the reason"

repo="$(setup_repo record-raises-medium "$project_policy")"
printf 'More.\n' >>"$repo/docs/guide.md"
set_record "$repo" medium
expect_level "$repo" medium "the implementer's record raises a low feature to medium"

repo="$(setup_repo record-lowers "$project_policy")"
printf 'print("y")\n' >>"$repo/src/code.py"
set_record "$repo" low
expect_level "$repo" medium "the implementer's record cannot lower the level"
expect_reason "$repo" "the completion record claims risk: low, below the computed medium" "the ignored claim was not reported"

repo="$(setup_repo record-invalid "$project_policy")"
printf 'print("y")\n' >>"$repo/src/code.py"
set_record "$repo" huge
expect_level "$repo" medium "an invalid claim changes nothing"
expect_reason "$repo" "does not exist (huge)" "the invalid claim was not reported"

# The reviewer's classification of the impact: major and breaking are high.
for impact in major breaking; do
  repo="$(setup_repo "review-$impact" "$project_policy")"
  printf 'More.\n' >>"$repo/docs/guide.md"
  set_review "$repo" "$impact"
  expect_level "$repo" high "a $impact impact on the architecture makes the feature high"
  expect_reason "$repo" "the independent review classified the impact on the architecture as $impact" "the review was not given as the reason"
done
repo="$(setup_repo review-minor "$project_policy")"
printf 'More.\n' >>"$repo/docs/guide.md"
set_review "$repo" minor
expect_level "$repo" low "a minor impact does not raise the level"

# No input an agent controls lowers a high-risk change: not its record, not
# its own policy, not the reviewer's classification.
repo="$(setup_repo agent-inputs template)"
printf '\n# changed\n' >>"$repo/scripts/finish-feature.sh"
printf 'default: low\nlow: scripts .agents\n' >"$repo/.agents/policies/risk.conf"
set_record "$repo" low
set_review "$repo" none
expect_level "$repo" high "a high-risk change stays high whatever the agents record"
expect_reason "$repo" "scripts/finish-feature.sh: listed as high" "the base's class was not applied"
expect_reason "$repo" "below the computed high" "the ignored claim was not reported"

# Without a base the diff cannot be classified: the level is high.
repo="$(setup_repo no-base template)"
printf 'More.\n' >>"$repo/docs/guide.md"
git -C "$repo" branch -q -m main trunk
expect_level "$repo" high "a feature without a known base is high"
expect_reason "$repo" "could not be determined" "the unknown base was not given as the reason"
expect_level "$repo" high "an unknown base branch is high" no-such-base

# Refusals.
repo="$(setup_repo refusals template)"
check "$repo" --fail-on-protected
[[ "$status" -eq 3 ]] || fail "an unknown option was accepted ($status)"
check "$repo" main extra
[[ "$status" -eq 3 ]] || fail "two base branches were accepted ($status)"

echo "risk tests passed"
