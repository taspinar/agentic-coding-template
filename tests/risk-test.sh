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
  cp "$source_root/.agents/policies/autonomy.md" "$repo/.agents/policies/autonomy.md"
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
# A directory in 'check_path_prefix' comes first on PATH, for a fake tool.
check_path_prefix=""
check() {
  local repo="$1"

  shift
  status=0
  (cd "$repo" && PATH="${check_path_prefix:+$check_path_prefix:}/usr/bin:/bin" ./scripts/check-risk.sh "$@") >"$repo.out" 2>&1 || status=$?
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
  printf '\nChanged.\n' >>"$repo/$path"
  expect_level "$repo" high "a change to $path escalates"
  expect_reason "$repo" "$path: a policy, an agent contract, or a schema is changed" "$path was not given as the reason"
done
repo="$(setup_repo contract-removed "$lenient")"
git -C "$repo" rm -q .agents/prompts/implementer.md
expect_level "$repo" high "a removed agent contract escalates"
expect_reason "$repo" ".agents/prompts/implementer.md: a policy, an agent contract, or a schema is removed" \
  "the removed contract was not given as the reason"

# An escalation reads only changed or removed existing lines and files. A
# file the feature adds never escalates by itself, whatever it holds: not a
# schema, a policy, a manifest, or a verification configuration that the
# base does not have. A protected path keeps its high class by the path
# rule, so the same schema is high under the template's policy.
repo="$(setup_repo schema-added "$lenient")"
printf '{}\n' >"$repo/.agents/schemas/extra.schema.json"
expect_level "$repo" low "an added schema does not escalate by itself"
repo="$(setup_repo schema-added-template template)"
printf '{}\n' >"$repo/.agents/schemas/extra.schema.json"
expect_level "$repo" high "an added schema is high by the path rule of the template"
expect_reason "$repo" ".agents/schemas/extra.schema.json: listed as high in .agents/policies/risk.conf" \
  "the path rule was not given as the reason"
if grep -Fq "a policy, an agent contract, or a schema is changed" "$repo.out"; then
  fail "an added schema was counted as a changed one"
fi
repo="$(setup_repo policy-added "$lenient")"
printf 'tolerance: 1e-6\n' >"$repo/.agents/policies/new-policy.md"
expect_level "$repo" low "an added policy file does not escalate by itself"
repo="$(setup_repo policy-added-committed "$lenient")"
printf 'A policy.\n' >"$repo/.agents/policies/new-policy.md"
git -C "$repo" add .agents/policies/new-policy.md
git -C "$repo" commit -qm "Add a policy"
printf 'Changed again.\n' >>"$repo/.agents/policies/new-policy.md"
expect_level "$repo" low "a policy file the feature itself added is new, also when it changes it again"
repo="$(setup_repo check-list-added "$lenient")"
git -C "$repo" switch -q main
git -C "$repo" rm -q scripts/verify-workflow.conf
git -C "$repo" commit -qm "Without a workflow self-test list"
git -C "$repo" branch -q -f feature/5-thing main
git -C "$repo" switch -q feature/5-thing
printf 'paths: scripts\nself: echo skipped\n' >"$repo/scripts/verify-workflow.conf"
expect_level "$repo" low "a verification configuration the feature adds has only added lines and does not escalate"

repo="$(setup_repo manifest "$(printf 'default: low\nmanifests: package.json')")"
printf '{"name": "x", "dependencies": {"left-pad": "1"}}\n' >"$repo/package.json"
expect_level "$repo" high "a change to a named manifest escalates"
expect_reason "$repo" "package.json: a dependency or toolchain manifest is changed" "the manifest was not given as the reason"
repo="$(setup_repo manifest-unnamed "$lenient")"
printf '{"name": "y"}\n' >"$repo/package.json"
expect_level "$repo" low "a manifest the project does not name is an ordinary path"
repo="$(setup_repo manifest-added "$(printf 'default: low\nmanifests: package.json package-lock.json')")"
printf '{"dependencies": {"left-pad": "1"}}\n' >"$repo/package-lock.json"
expect_level "$repo" low "a manifest the feature adds does not escalate by itself"
repo="$(setup_repo manifest-removed "$(printf 'default: low\nmanifests: package.json')")"
git -C "$repo" rm -q package.json
expect_level "$repo" high "a removed manifest escalates"
expect_reason "$repo" "package.json: a dependency or toolchain manifest is removed" "the removed manifest was not given as the reason"

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

# When Git cannot enumerate the changes (a bad object, an unreadable tree),
# the level is high, and never the default for a feature that changed
# nothing: a git on PATH whose every 'diff' fails stands in for it.
mkdir -p "$tmp/broken-git"
cat >"$tmp/broken-git/git" <<GIT
#!/usr/bin/env bash
for arg in "\$@"; do
  [[ "\$arg" != diff ]] || { echo "fatal: bad object (injected)" >&2; exit 128; }
done
exec "$(command -v git)" "\$@"
GIT
chmod +x "$tmp/broken-git/git"
check_path_prefix="$tmp/broken-git"
repo="$(setup_repo enumeration-fails template)"
printf 'More.\n' >>"$repo/docs/guide.md"
expect_level "$repo" high "a feature whose changes cannot be enumerated is high, not the default medium"
expect_reason "$repo" "the changes of the feature could not be enumerated (git diff failed)" \
  "the failed enumeration was not given as the reason"
if grep -Fq "no path is changed" "$repo.out"; then fail "a failed diff passed as a feature that changed nothing"; fi
repo="$(setup_repo enumeration-fails-low "$(printf 'default: low\nlow: docs')")"
printf 'More.\n' >>"$repo/docs/guide.md"
expect_level "$repo" high "a feature whose changes cannot be enumerated is high, not the low of its policy"
expect_reason "$repo" "could not be enumerated" "the failed enumeration was not given as the reason"
check_path_prefix=""

# What a level requires of the workflow, by the same policy. The template
# ships the full verification and delta reviews for every level, and a
# level without a line gets the same.
requirement_of() {
  sed -n "s/^$2: //p" "$1.out" | sed -n 1p
}
repo="$(setup_repo requirements-template template)"
printf 'More.\n' >>"$repo/docs/guide.md"
expect_level "$repo" medium "the template classifies a documentation change as medium"
[[ "$(requirement_of "$repo" verification)" == "full" ]] || fail "the template does not require the full verification: $(cat "$repo.out")"
[[ "$(requirement_of "$repo" review)" == "delta" ]] || fail "the template does not allow delta reviews: $(cat "$repo.out")"
if grep -q "^refused: " "$repo.out"; then fail "the shipped policy has a refused requirement"; fi
repo="$(setup_repo requirements-absent none)"
printf 'More.\n' >>"$repo/docs/guide.md"
expect_level "$repo" medium "a project without a policy classifies a documentation change as medium"
[[ "$(requirement_of "$repo" verification)" == "full" && "$(requirement_of "$repo" review)" == "delta" ]] ||
  fail "a project without a policy does not get the shipped requirements: $(cat "$repo.out")"

# A project names groups for the intermediate rounds of high, requires
# complete reviews for high, and lets low go without a review. A requirement
# line is not a path class: a file named like a group is not high.
requirements_policy='default: medium
low: docs
high: src/auth
high: verification: groups unit  lint
high: review: full
low: review: none
medium: verification: groups unit'
repo="$(setup_repo requirements-high "$requirements_policy")"
mkdir -p "$repo/src/auth"
printf 'login\n' >"$repo/src/auth/login.py"
expect_level "$repo" high "a path of the high class is high"
[[ "$(requirement_of "$repo" verification)" == "groups lint unit" ]] || fail "the groups of high were not read: $(cat "$repo.out")"
[[ "$(requirement_of "$repo" review)" == "full" ]] || fail "the complete review of high was not read: $(cat "$repo.out")"
repo="$(setup_repo requirements-low "$requirements_policy")"
printf 'More.\n' >>"$repo/docs/guide.md"
expect_level "$repo" low "a documentation change is low"
[[ "$(requirement_of "$repo" verification)" == "full" ]] || fail "low without a verification line does not get the full verification: $(cat "$repo.out")"
[[ "$(requirement_of "$repo" review)" == "none" ]] || fail "'low: review: none' was not read: $(cat "$repo.out")"
repo="$(setup_repo requirements-medium "$requirements_policy")"
printf 'checks\n' >"$repo/unit"
printf 'print("y")\n' >>"$repo/src/code.py"
expect_level "$repo" medium "a file named like a group of checks is not a path of the high class"
if grep -Fq "listed as high" "$repo.out"; then fail "a requirement line was read as a path class"; fi
[[ "$(requirement_of "$repo" verification)" == "groups unit" ]] || fail "the groups of medium were not read: $(cat "$repo.out")"
[[ "$(requirement_of "$repo" review)" == "delta" ]] || fail "medium without a review line does not allow delta reviews: $(cat "$repo.out")"

# 'review: none' is refused for medium and high, and a value the policy
# does not know is refused: the strictest requirement applies and the
# refusal is reported.
repo="$(setup_repo requirements-refused "$(printf 'default: medium\nmedium: review: none\nmedium: verification: groups')")"
printf 'More.\n' >>"$repo/docs/guide.md"
expect_level "$repo" medium "a documentation change is medium"
[[ "$(requirement_of "$repo" review)" == "full" ]] || fail "'medium: review: none' was not refused with a complete review: $(cat "$repo.out")"
expect_reason "$repo" "refused: medium: review: none is refused" "the refused 'medium: review: none' was not reported"
[[ "$(requirement_of "$repo" verification)" == "full" ]] || fail "'groups' without a group was not refused with the full verification: $(cat "$repo.out")"
expect_reason "$repo" "refused: medium: verification: groups is not accepted" "the refused verification value was not reported"
repo="$(setup_repo requirements-refused-high "$(printf 'default: high\nhigh: review: later\nhigh: verification: some')")"
printf 'More.\n' >>"$repo/docs/guide.md"
expect_level "$repo" high "the default of the policy is high"
[[ "$(requirement_of "$repo" review)" == "full" && "$(requirement_of "$repo" verification)" == "full" ]] ||
  fail "values the policy does not know were not refused with the strictest requirements: $(cat "$repo.out")"
expect_reason "$repo" "refused: high: review: later is not accepted" "the unknown review value was not reported"
expect_reason "$repo" "refused: high: verification: some is not accepted" "the unknown verification value was not reported"

# The strictest requirement of the base refs counts: a 'low: review: none'
# that only the local base knows, while origin does not, gives delta.
repo="$(setup_repo requirements-refs "$(printf 'default: medium\nlow: docs\nlow: review: none\nlow: verification: groups unit')")"
printf 'More.\n' >>"$repo/docs/guide.md"
git -C "$repo" stash -q
git -C "$repo" switch -q -c ahead main
printf 'default: medium\nlow: docs\n' >"$repo/.agents/policies/risk.conf"
git -C "$repo" commit -qam "Origin requires reviews of everything"
git -C "$repo" update-ref refs/remotes/origin/main ahead
git -C "$repo" switch -q feature/5-thing
git -C "$repo" branch -q -D ahead
git -C "$repo" stash pop -q
expect_level "$repo" low "a documentation change is low"
[[ "$(requirement_of "$repo" review)" == "delta" ]] || fail "the stricter review requirement of origin did not count: $(cat "$repo.out")"
[[ "$(requirement_of "$repo" verification)" == "full" ]] || fail "the stricter verification of origin did not count: $(cat "$repo.out")"

# Refusals.
repo="$(setup_repo refusals template)"
check "$repo" --fail-on-protected
[[ "$status" -eq 3 ]] || fail "an unknown option was accepted ($status)"
check "$repo" main extra
[[ "$status" -eq 3 ]] || fail "two base branches were accepted ($status)"

echo "risk tests passed"
