#!/usr/bin/env bash

set -euo pipefail

# The agent and model of a role by the risk level of the feature
# ('<role>@<level>: <provider> <model>' in .agents/agents.conf): the
# precedence of the command line, the level line, and the plain line; a
# session that never runs at a weaker level than an earlier one; what
# doctor.sh reports; and what the run records and the report show.

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/agent-levels-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
bash_path="$(command -v bash)"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "agent-levels test failed: $*" >&2
  exit 1
}

source "$source_root/tests/lib-fakes.sh"
make_fake_agents "$tmp/bin"

# --- The library ------------------------------------------------------------

config="$tmp/agents.conf"
export AGENT_CONFIG_FILE="$config"
write_config() {
  printf '%s\n' "$@" >"$config"
}

# resolve <role> [provider] [model] [level]: prints "<provider> <model>
# <level> <selection>", with 'none' for no level, or fails as a script would.
resolve() {
  (
    export PATH="$tmp/bin:$PATH"
    source "$source_root/scripts/lib/agent.sh"
    agent_resolve "$tmp" "$@"
    printf '%s %s %s %s\n' "$AGENT_PROVIDER" "$AGENT_MODEL" "${AGENT_LEVEL:-none}" "$AGENT_SELECTION"
  ) 2>"$tmp/err.log"
}

expect_resolved() {
  local expected="$1"
  local actual
  shift

  actual="$(resolve "$@")" || {
    cat "$tmp/err.log" >&2
    fail "resolution failed for: $*"
  }
  [[ "$actual" == "$expected" ]] || fail "expected '$expected' for '$*', got '$actual'"
}

expect_rejected() {
  local description="$1"
  local reason="$2"
  shift 2

  if resolve "$@" >/dev/null; then
    fail "expected rejection: $description"
  fi
  grep -Fq -- "$reason" "$tmp/err.log" || fail "$description: the rejection does not say '$reason': $(cat "$tmp/err.log")"
}

write_config "implementer: codex sonnet" "implementer@high: claude fable" \
  "reviewer: claude model-r" "reviewer@low: codex model-rl" "triage@high: claude model-th"

# The line of the level comes before the plain line; without one for the
# level, and without a level, the plain line applies.
expect_resolved "claude fable high level-line" implementer "" "" high
expect_resolved "codex sonnet medium plain-line" implementer "" "" medium
expect_resolved "codex sonnet low plain-line" implementer "" "" low
expect_resolved "codex sonnet none plain-line" implementer
expect_resolved "codex model-rl low level-line" reviewer "" "" low
expect_resolved "claude model-r high plain-line" reviewer "" "" high

# The command line comes before both. --agent alone keeps the model of the
# selected line when the provider is the same, and is refused otherwise, as
# for a plain line.
expect_resolved "claude model-x high command-line" implementer "" model-x high
expect_resolved "codex model-y high command-line" implementer codex model-y high
expect_resolved "claude fable high command-line" implementer claude "" high
expect_resolved "codex model-z medium command-line" implementer "" model-z medium
expect_rejected "a provider that differs from the level line, without a model" "pass --model as well" implementer codex "" high

# A role with a level line only has no agent at another level: no fallback.
expect_resolved "claude model-th high level-line" triage "" "" high
expect_rejected "a role whose only line is for another level" "no agent is configured for role 'triage'" triage "" "" medium
expect_rejected "a level that does not exist" "unknown risk level" implementer "" "" critical

# An invalid level line is refused, whatever the role or the level asked for.
write_config "implementer: codex sonnet" "implementer@critical: claude fable"
expect_rejected "an unknown level in a line" "unknown risk level 'critical'" implementer "" "" medium
expect_rejected "an unknown level in a line, for another role" "unknown risk level 'critical'" reviewer claude model-r
write_config "implementer: codex sonnet" "implementer@high: claude fable" "implementer@high: codex sonnet"
expect_rejected "a duplicate level line" "configured more than once" implementer
write_config "implementer: codex sonnet" "implementer@High: claude fable"
expect_rejected "a malformed level line" "malformed entry" implementer
write_config "implementer: codex sonnet" "implementer@high: copilot fable"
expect_rejected "an unsupported provider on a level line" "unsupported agent 'copilot'" implementer "" "" high

# The provider and the model of every line are checked while the file is
# read, also on a level line of a role that is not the one resolved, and the
# message names the line, its role, and its level.
write_config "implementer: codex sonnet" "reviewer@high: copilot nope"
expect_rejected "an unsupported provider on a level line of another role" "unsupported agent 'copilot' for role 'reviewer@high' on line 2 of $config" implementer
expect_rejected "an unsupported provider on a level line of another role, at a level" "for role 'reviewer@high' on line 2" implementer "" "" medium
write_config "implementer: codex sonnet" "reviewer@high: claude --fallback"
expect_rejected "an invalid model on a level line of another role" "model must use only letters" implementer
grep -Fq "for role 'reviewer@high' on line 2 of $config" "$tmp/err.log" || fail "the invalid model is not reported with its line: $(cat "$tmp/err.log")"
write_config "implementer: codex sonnet" "triage@low: codex fable"
expect_rejected "an unsupported combination on a level line of another role" "unsupported agent/model combination: codex + fable for role 'triage@low' on line 2" implementer "" "" high
write_config "implementer: codex sonnet" "reviewer: copilot nope" "reviewer@high: claude model-rh"
expect_rejected "an unsupported provider on the plain line of another role" "unsupported agent 'copilot' for role 'reviewer' on line 2" implementer "" "" high

# --- The highest level of the run records -----------------------------------

# records_highest_level joins the events to the runs whose start names the
# feature: the levels of another feature, of a planning, or of a run without
# a start never count, and the copy of the feature counts like a run file.
records_repo="$tmp/records"
mkdir -p "$records_repo/.agents/run/records" "$records_repo/.agents/records"
git -C "$records_repo" init -q -b main
# event <run> <type> <kind-or-level> [subject]: one line of a run file.
event() {
  if [[ "$2" == "run-start" ]]; then
    printf '{"schema": "run-record/v1", "run": "%s", "type": "run-start", "kind": "%s", "subject": "%s", "command": "start-feature.sh"}\n' "$1" "$3" "$4"
  else
    printf '{"schema": "run-record/v1", "run": "%s", "type": "%s", "level": "%s", "role": "implementer"}\n' "$1" "$2" "$3"
  fi
}
{
  event run-a run-start feature 3
  event run-a agent-call medium
} >"$records_repo/.agents/run/records/run-a.jsonl"
{
  event run-b run-start feature 4
  event run-b agent-start high
  event run-b risk high
} >"$records_repo/.agents/run/records/run-b.jsonl"
{
  event run-c run-start planning 3
  event run-c agent-call high
  event run-d agent-call high
  printf 'not json\n'
} >"$records_repo/.agents/run/records/run-c.jsonl"
{
  event run-e run-start feature 6
  event run-e risk high
} >"$records_repo/.agents/records/feature-6.jsonl"
highest_level() {
  (
    cd "$records_repo"
    unset RECORDS_RUN_ID RECORDS_FILE RECORDS_COMMAND RECORDS_KIND RECORDS_SUBJECT
    source "$source_root/scripts/lib/records.sh"
    records_highest_level "$1"
  )
}
[[ "$(highest_level 3)" == "medium" ]] || fail "the highest level of feature 3 is not its own medium: '$(highest_level 3)' (the high of another feature, a planning, or a run without a start counted)"
[[ "$(highest_level 4)" == "high" ]] || fail "the high of feature 4 was not found: '$(highest_level 4)'"
[[ "$(highest_level 6)" == "high" ]] || fail "the copy of feature 6 was not read: '$(highest_level 6)'"
[[ -z "$(highest_level 5)" ]] || fail "a feature without a record has a level: '$(highest_level 5)'"
{
  event run-f run-start feature 3
  event run-f agent-call high
} >"$records_repo/.agents/run/records/run-f.jsonl"
[[ "$(highest_level 3)" == "high" ]] || fail "the high of a later run of feature 3 was not found: '$(highest_level 3)'"

# A run that its file and the copy of the feature both hold (the copy made
# by a consolidation while the run file stays) counts once: one session of
# the implementer, each event once, the highest level unchanged. A run that
# only the copy holds counts from the copy; a run that both hold is read
# from its file, which is the complete one.
call() {
  printf '{"schema": "run-record/v1", "run": "%s", "type": "%s", "id": "%s-call", "role": "implementer", "agent": "claude", "model": "model-x", "level": "%s", "selection": "level-line"}\n' "$1" "$2" "$1" "$3"
}
feature_records() {
  (
    cd "$records_repo"
    unset RECORDS_RUN_ID RECORDS_FILE RECORDS_COMMAND RECORDS_KIND RECORDS_SUBJECT
    source "$source_root/scripts/lib/records.sh"
    "$@"
  )
}
{
  event run-g run-start feature 9
  call run-g agent-start high
  call run-g agent-call high
} >"$records_repo/.agents/run/records/run-g.jsonl"
cp "$records_repo/.agents/run/records/run-g.jsonl" "$records_repo/.agents/records/feature-9.jsonl"
[[ "$(feature_records records_role_providers 9 implementer)" == $'claude\t1' ]] ||
  fail "a run that its file and the copy both hold is not counted once: '$(feature_records records_role_providers 9 implementer)'"
[[ "$(feature_records records_feature_events 9 length)" == "3" ]] || fail "the events of a run that its file and the copy both hold are not read once: $(feature_records records_feature_events 9 length)"
[[ "$(highest_level 9)" == "high" ]] || fail "the highest level changed with the copy: '$(highest_level 9)'"
{
  event run-g run-start feature 9
  call run-g agent-start high
  event run-h run-start feature 9
  call run-h agent-start medium
  call run-h agent-call medium
} >"$records_repo/.agents/records/feature-9.jsonl"
[[ "$(feature_records records_role_providers 9 implementer)" == $'claude\t2' ]] ||
  fail "a run that only the copy holds did not count once: '$(feature_records records_role_providers 9 implementer)'"
[[ "$(feature_records records_feature_events 9 length)" == "6" ]] ||
  fail "a run that both hold was not read from its file alone: $(feature_records records_feature_events 9 length) events"
[[ "$(highest_level 9)" == "high" ]] || fail "the highest level is not the one of the run file: '$(highest_level 9)'"

# --- doctor.sh --------------------------------------------------------------

# A bin directory with fake tools, as tests/doctor-test.sh builds it: git and
# gh answer the calls doctor.sh makes, jq is the real one, the agents are
# empty programs; codex is not logged in, so doctor.sh skips the check of its
# sandbox, which tests/doctor-test.sh covers.
make_bin() {
  local bin="$tmp/$1"
  shift

  mkdir -p "$bin"
  for tool in "$@"; do
    case "$tool" in
      git)
        cat >"$bin/git" <<FAKE
#!$bash_path
case "\$*" in
  "rev-parse --show-toplevel") exit 0 ;;
  "remote get-url origin") exit 0 ;;
  "ls-remote --exit-code --heads origin main") exit 0 ;;
  "push --dry-run --quiet origin HEAD:refs/heads/doctor-push-check") exit 0 ;;
  "config user.name") echo "Test User"; exit 0 ;;
  "config user.email") echo "test@example.com"; exit 0 ;;
esac
echo "unexpected git call: \$*" >&2
exit 97
FAKE
        ;;
      gh)
        cat >"$bin/gh" <<FAKE
#!$bash_path
[[ "\$*" == "auth status" ]] && exit 0
if [[ "\$1" == "api" ]]; then
  case "\$2" in
    "repos/{owner}/{repo}/rules/branches/main") echo 1 ;;
    "repos/{owner}/{repo}/branches/main") echo 0 ;;
    *) echo "unexpected gh api call: \$*" >&2; exit 97 ;;
  esac
  exit 0
fi
echo "unexpected gh call: \$*" >&2
exit 97
FAKE
        ;;
      jq) printf '#!%s\nexec %q "$@"\n' "$bash_path" "$(command -v jq)" >"$bin/jq" ;;
      codex) printf '#!%s\n[[ "$1" != login ]] || exit 1\nexit 0\n' "$bash_path" >"$bin/codex" ;;
      *) printf '#!%s\nexit 0\n' "$bash_path" >"$bin/$tool" ;;
    esac
    chmod +x "$bin/$tool"
  done
  printf '%s\n' "$bin"
}

printf 'agent-attribution: allowed\n' >"$tmp/attribution.conf"
run_doctor() {
  PATH="$1" AGENT_CONFIG_FILE="$config" ATTRIBUTION_CONFIG_FILE="$tmp/attribution.conf" \
    ATTRIBUTION_CLAUDE_SETTINGS_FILE="$tmp/claude-settings.json" "$bash_path" "$source_root/scripts/doctor.sh" >"$tmp/doctor.log" 2>&1
}

bin="$(make_bin both git gh jq codex claude)"

# A valid configuration with level lines passes; the reviewing pair is
# checked as it resolves for the level: at high both roles are claude.
write_config "implementer: codex sonnet" "implementer@high: claude fable" "reviewer: claude model-r"
run_doctor "$bin" || { cat "$tmp/doctor.log" >&2; fail "a valid configuration with a level line failed doctor"; }
grep -Eq '^OK +agent configuration is valid' "$tmp/doctor.log" || fail "the level line was not accepted as valid"
grep -Fq "roles 'reviewer' and 'implementer' use the same agent (claude) for a high-risk feature" "$tmp/doctor.log" ||
  fail "the reviewing pair resolved for the level was not checked: $(cat "$tmp/doctor.log")"
if grep -Fq "use the same agent (codex)" "$tmp/doctor.log"; then fail "the plain pair, which differs, was reported"; fi
if grep -Fq "for a medium-risk feature" "$tmp/doctor.log"; then fail "a level without a line was reported on its own"; fi

# The plain pair with the same provider is reported too, and a pair that a
# level line makes different is not reported for that level.
write_config "implementer: codex sonnet" "implementer@high: claude fable" "reviewer: codex model-r" "reviewer@high: codex model-rh"
run_doctor "$bin" || fail "a configuration with the same plain providers failed doctor"
grep -Fq "roles 'reviewer' and 'implementer' use the same agent (codex)" "$tmp/doctor.log" || fail "the same plain providers were not reported"
if grep -Fq "for a high-risk feature" "$tmp/doctor.log"; then fail "a pair that differs at high was reported for high"; fi

# An unknown level fails, like a malformed plain line.
write_config "implementer: codex sonnet" "implementer@critical: claude fable"
if run_doctor "$bin"; then fail "an unknown level passed doctor"; fi
grep -Eq '^FAILED +agent configuration is invalid' "$tmp/doctor.log" || fail "the unknown level was not reported as invalid"
grep -Fq "unknown risk level 'critical'" "$tmp/doctor.log" || fail "the unknown level was not named"

# An unsupported provider on a level line fails as an invalid configuration
# and names the line, also on a line of a role that no script started.
write_config "implementer: codex sonnet" "implementer@high: copilot fable" "reviewer: claude model-r"
if run_doctor "$bin"; then fail "an unsupported provider on a level line passed doctor"; fi
grep -Eq '^FAILED +agent configuration is invalid' "$tmp/doctor.log" || fail "the unsupported provider was not reported as invalid: $(cat "$tmp/doctor.log")"
grep -Fq "unsupported agent 'copilot' for role 'implementer@high' on line 2" "$tmp/doctor.log" || fail "the unsupported provider was not reported with its line: $(cat "$tmp/doctor.log")"
write_config "implementer: codex sonnet" "reviewer: claude model-r" "reviewer@high: copilot nope"
if run_doctor "$bin"; then fail "an unsupported provider on a level line of the reviewer passed doctor"; fi
grep -Fq "unsupported agent 'copilot' for role 'reviewer@high' on line 3" "$tmp/doctor.log" || fail "the unsupported provider of the reviewer was not reported with its line: $(cat "$tmp/doctor.log")"

# An invalid model on a level line fails and names the line.
write_config "implementer: codex sonnet" "reviewer: claude model-r" "reviewer@high: claude --fallback"
if run_doctor "$bin"; then fail "an invalid model on a level line passed doctor"; fi
grep -Eq '^FAILED +agent configuration is invalid' "$tmp/doctor.log" || fail "the invalid model was not reported as invalid: $(cat "$tmp/doctor.log")"
grep -Fq "for role 'reviewer@high' on line 3" "$tmp/doctor.log" || fail "the invalid model was not reported with its line: $(cat "$tmp/doctor.log")"

# A CLI that only a level line needs is required, and the line is named.
bin_codex="$(make_bin codex-only git gh jq codex)"
write_config "implementer: codex sonnet" "implementer@high: claude fable" "reviewer: codex model-r"
if run_doctor "$bin_codex"; then fail "a missing CLI that a level line needs passed doctor"; fi
grep -Eq '^FAILED +claude CLI is not installed' "$tmp/doctor.log" || fail "the missing CLI of a level line was not reported"
grep -Fq "implementer@high" "$tmp/doctor.log" || fail "the level line that needs the CLI was not named"

# A level line of a role that never runs with a level is a warning.
write_config "implementer: codex sonnet" "reviewer: claude model-r" "analyst: claude model-a" "analyst@high: codex model-b"
run_doctor "$bin" || fail "a level line of the analyst failed doctor"
grep -Fq "role 'analyst' has a line per risk level (high) that never applies" "$tmp/doctor.log" ||
  fail "a level line that never applies was not reported: $(cat "$tmp/doctor.log")"

# --- The shipped configuration ----------------------------------------------

# The template's own .agents/agents.conf, against a copy: the writing roles
# of a feature are Claude at every level (opus at low and medium, fable at
# high), the reviewer is Codex at every level, so the pair differs at every
# level without a line of its own, and doctor.sh accepts the file without a
# same-provider warning.
cp "$source_root/.agents/agents.conf" "$config"
for level in low medium high; do
  if [[ "$level" == high ]]; then
    expected="claude fable high level-line"
  else
    expected="claude opus $level plain-line"
  fi
  expect_resolved "$expected" implementer "" "" "$level"
  expect_resolved "$expected" triage-implementer "" "" "$level"
  expect_resolved "codex gpt-6-luna $level plain-line" reviewer "" "" "$level"
  expect_resolved "claude sonnet $level plain-line" triage "" "" "$level"
done
expect_resolved "claude opus none plain-line" implementer
expect_resolved "codex gpt-6-luna none plain-line" reviewer
run_doctor "$bin" || { cat "$tmp/doctor.log" >&2; fail "the shipped configuration failed doctor"; }
grep -Eq '^OK +agent configuration is valid' "$tmp/doctor.log" || fail "the shipped configuration was not accepted as valid"
if grep -Fq "use the same agent" "$tmp/doctor.log"; then fail "the shipped configuration pairs the same provider: $(grep -F 'use the same agent' "$tmp/doctor.log")"; fi
if grep -Fq "that never applies" "$tmp/doctor.log"; then fail "the shipped configuration has a level line that never applies: $(grep -F 'that never applies' "$tmp/doctor.log")"; fi
unset AGENT_CONFIG_FILE

# --- The scripts, with the fakes --------------------------------------------

cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "api" && "${2:-}" == repos/*/comments ]]; then
  exec "$(dirname "$0")/gh-comments" "$@"
fi
case "${1:-} ${2:-}" in
  "auth status") exit 0 ;;
  "issue view")
    # MOCK_GH_ISSUE_FLAKY=<n>: the first n reads of the Issue fail on the
    # connection; MOCK_GH_ISSUE_REFUSED: every read is refused.
    if [[ -n "${MOCK_GH_ISSUE_FLAKY:-}" ]]; then
      calls="$(cat "$MOCK_AGENT_LOG.gh-calls" 2>/dev/null || echo 0)"
      echo $((calls + 1)) >"$MOCK_AGENT_LOG.gh-calls"
      if [[ "$calls" -lt "$MOCK_GH_ISSUE_FLAKY" ]]; then
        echo "Post \"https://api.github.com/graphql\": net/http: TLS handshake timeout" >&2
        exit 1
      fi
    fi
    if [[ -n "${MOCK_GH_ISSUE_REFUSED:-}" ]]; then
      echo "GraphQL: Resource not accessible by integration (repository.issue)" >&2
      exit 1
    fi
    case "$*" in
      # MOCK_ISSUE_LABELS: the labels of the Issue, one per line.
      *"--json title,labels"*) echo "Feature with levels"; [[ -z "${MOCK_ISSUE_LABELS:-}" ]] || printf '%s\n' "$MOCK_ISSUE_LABELS" ;;
      *"--json title"*) echo "Feature with levels" ;;
      *) printf 'Title: Feature with levels\n\nThe feature.\n' ;;
    esac
    exit 0
    ;;
esac
echo "Unexpected gh invocation: $*" >&2
exit 1
GH
chmod +x "$tmp/bin/gh"

# A project whose base classifies src/auth as high and everything else as
# medium, with a stronger implementer and another reviewer for high.
setup_repo() {
  local label="$1"
  local seed="$tmp/$label-seed"
  local remote="$tmp/$label-remote.git"
  local repo="$tmp/$label"

  mkdir -p "$seed/.agents/policies"
  copy_workflow "$seed"
  # The report reads its jq program, which copy_workflow leaves out.
  cp "$source_root/scripts/lib/report.jq" "$seed/scripts/lib/"
  cp "$source_root/.gitignore" "$seed/.gitignore"
  printf 'implementer: codex sonnet\nimplementer@high: claude fable\nreviewer: claude model-r\nreviewer@high: codex model-rh\n' \
    >"$seed/.agents/agents.conf"
  printf 'default: medium\nhigh: src/auth\n' >"$seed/.agents/policies/risk.conf"
  printf '# Project\n' >"$seed/README.md"
  printf 'count: echo run >>verify-count.log\n' >"$seed/scripts/verify.conf"
  git -C "$seed" init -q -b main
  git -C "$seed" config user.name "Agent Levels Test"
  git -C "$seed" config user.email "agent-levels-test@example.com"
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
    PATH="$tmp/bin:/usr/bin:/bin" MOCK_AGENT_LOG="$repo.log" START_FEATURE_GH_WAIT=0 ./scripts/start-feature.sh "$@" </dev/null
  ) >"$repo.out" 2>&1
}

# started <repo> <provider> <model> <what>: the last session of a repository
# ran the provider with the model.
started() {
  grep -Fq "AGENT=$2" "$1.log" && grep -Fq -- "--model $3" "$1.log" || {
    cat "$1.out" >&2
    fail "$4: expected $2 with $3, the log holds: $(cat "$1.log")"
  }
}

# recorded <repo> <role> <level> <selection> <what>: the run records hold a
# call of the role with the level and the selection.
recorded() {
  cat "$1"/.agents/run/records/*.jsonl | jq -e -s --arg role "$2" --arg level "$3" --arg selection "$4" \
    'any(.type == "agent-call" and .role == $role and .level == $level and .selection == $selection)' >/dev/null ||
    fail "$5: the run record has no call of the $2 at $3 selected by $4"
}

# A new feature has no changes: it is medium by the default of the policy
# and starts the plain line's agent.
repo="$(setup_repo levels)"
run_start "$repo" 3 || { cat "$repo.out" >&2; fail "starting a feature with level lines failed"; }
worktree="$tmp/levels-3-feature-with-levels"
[[ -d "$worktree" ]] || fail "the worktree was not created"
started "$repo" codex sonnet "a new feature"
grep -Fq "Level:    medium (the default of the risk policy of main; the feature has no changes yet)" "$repo.out" ||
  fail "the level of a new feature was not explained: $(cat "$repo.out")"
grep -Fq "Selected: by the plain line of 'implementer' (no 'implementer@medium' line)" "$repo.out" ||
  fail "the selection by the plain line was not shown"
recorded "$repo" implementer medium plain-line "a new feature"

# A high feature, by a path of the high class, starts the level line's agent.
mkdir -p "$worktree/src/auth"
printf 'login\n' >"$worktree/src/auth/login.txt"
: >"$repo.log"
run_start "$repo" 3 --resume || { cat "$repo.out" >&2; fail "resuming a high feature failed"; }
started "$repo" claude fable "a high feature"
grep -Fq "Level:    high (computed by check-risk.sh against main)" "$repo.out" || fail "the computed level was not shown: $(cat "$repo.out")"
grep -Fq "Selected: by the line 'implementer@high' of .agents/agents.conf" "$repo.out" || fail "the selection by the level line was not shown"
recorded "$repo" implementer high level-line "a high feature"

# The level never falls between sessions: the high path is gone and the
# feature computes as medium now, but the run record keeps high.
rm -r "$worktree/src"
(cd "$worktree" && PATH="$tmp/bin:/usr/bin:/bin" ./scripts/check-risk.sh main >"$tmp/risk.out" 2>&1) || true
[[ "$(sed -n 1p "$tmp/risk.out")" == "risk: medium" ]] || fail "the feature without the high path is not medium: $(cat "$tmp/risk.out")"
: >"$repo.log"
run_start "$repo" 3 --resume || { cat "$repo.out" >&2; fail "resuming after the level fell failed"; }
started "$repo" claude fable "a session after an earlier one at high"
grep -Fq "Level:    high (an earlier session of the feature ran at high (the run records); medium now, computed by check-risk.sh against main)" "$repo.out" ||
  fail "the level kept from the earlier session was not explained: $(cat "$repo.out")"
recorded "$repo" implementer high level-line "a session after an earlier one at high"

# A feature whose first session finds a high run record of an earlier one
# (the records of a previous checkout, consolidated) starts at high although
# it computes as medium, and says so.
repo_prior="$(setup_repo prior)"
mkdir -p "$repo_prior/.agents/run/records"
{
  event run-prior run-start feature 6
  event run-prior agent-call high
} >"$repo_prior/.agents/run/records/run-prior.jsonl"
run_start "$repo_prior" 6 thing || { cat "$repo_prior.out" >&2; fail "starting a feature with a prior high record failed"; }
started "$repo_prior" claude fable "a feature with a prior high record"
grep -Fq "Level:    high (an earlier session of the feature ran at high (the run records); medium now, the default of the risk policy of main; the feature has no changes yet)" "$repo_prior.out" ||
  fail "the prior high record was not explained: $(cat "$repo_prior.out")"
recorded "$repo_prior" implementer high level-line "a feature with a prior high record"

# --model overrides the level line and keeps its provider; --agent with
# --model overrides both. The record says the command line selected.
: >"$repo.log"
run_start "$repo" 3 --resume --model other || { cat "$repo.out" >&2; fail "resuming with --model failed"; }
started "$repo" claude other "--model on a high feature"
grep -Fq "Selected: by --agent or --model on the command line" "$repo.out" || fail "the selection by the command line was not shown"
recorded "$repo" implementer high command-line "--model on a high feature"
: >"$repo.log"
run_start "$repo" 3 --resume --agent codex --model m2 || { cat "$repo.out" >&2; fail "resuming with --agent and --model failed"; }
started "$repo" codex m2 "--agent and --model on a high feature"

# A medium feature starts the plain line's agent, also when resumed.
repo_medium="$(setup_repo medium)"
run_start "$repo_medium" 4 thing || { cat "$repo_medium.out" >&2; fail "starting a medium feature failed"; }
printf 'other\n' >"$tmp/medium-4-thing/other.txt"
: >"$repo_medium.log"
run_start "$repo_medium" 4 --resume || { cat "$repo_medium.out" >&2; fail "resuming a medium feature failed"; }
started "$repo_medium" codex sonnet "a medium feature"
grep -Fq "Level:    medium (computed by check-risk.sh against main)" "$repo_medium.out" || fail "the level of a medium feature was not shown"
recorded "$repo_medium" implementer medium plain-line "a medium feature"

# The report shows the calls per level, model, and selection.
report="$(cd "$repo" && PATH="$tmp/bin:/usr/bin:/bin" ./scripts/report-runs.sh 3)"
grep -Fq "### Per risk level" <<<"$report" || fail "the report has no section per level: $report"
grep -Fq "| medium | implementer | codex | sonnet | plain-line | 1 |" <<<"$report" || fail "the report lacks the medium call: $report"
grep -Fq "| high | implementer | claude | fable | level-line | 2 |" <<<"$report" || fail "the report lacks the calls by the level line: $report"
grep -Fq "| high | implementer | claude | other | command-line | 1 |" <<<"$report" || fail "the report lacks the call by the command line: $report"
json="$(cd "$repo" && PATH="$tmp/bin:/usr/bin:/bin" ./scripts/report-runs.sh 3 --json)"
[[ "$(jq '.subjects[0].levels | length' <<<"$json")" -eq 4 ]] || fail "the report groups the levels wrongly: $(jq -c '.subjects[0].levels' <<<"$json")"
[[ "$(jq -r '.subjects[0].levels[0].level' <<<"$json")" == "medium" ]] || fail "the levels are not ordered from low to high"
# A report without such a call has no section: records from before the
# levels existed read as before.
report_old="$(cd "$repo_medium" && PATH="$tmp/bin:/usr/bin:/bin" ./scripts/report-runs.sh 4)"
grep -Fq "### Per risk level" <<<"$report_old" || fail "a feature with level calls has no section"

# The owner's hints. A label 'risk: high' on the Issue raises a new feature,
# which has no changes, to high from its first session, for the whole
# feature: check-risk.sh names the label, and the run record notes the hint
# with its source. Other labels say nothing.
risk_events() {
  cat "$1"/.agents/run/records/*.jsonl | jq -c -s '[.[] | select(.type == "risk")]'
}
check_risk() {
  (cd "$1" && PATH="$tmp/bin:/usr/bin:/bin" ./scripts/check-risk.sh main >"$tmp/risk.out" 2>&1) || true
}
repo_label="$(setup_repo label)"
MOCK_ISSUE_LABELS=$'bug\nrisk: high' run_start "$repo_label" 7 || { cat "$repo_label.out" >&2; fail "starting a labelled feature failed"; }
worktree_label="$tmp/label-7-feature-with-levels"
started "$repo_label" claude fable "a new feature labelled risk: high"
grep -Fq "Level:    high (the default of the risk policy of main; the feature has no changes yet; the Issue is labelled risk: high, which raises the level to high)" "$repo_label.out" ||
  fail "the label was not given as the reason of the level: $(cat "$repo_label.out")"
recorded "$repo_label" implementer high level-line "a new feature labelled risk: high"
[[ "$(jq -c '[.[] | .hints] | .[0]' <<<"$(risk_events "$repo_label")")" == '[{"level":"high","source":"issue-label"}]' ]] ||
  fail "the run record does not note the label and its source: $(risk_events "$repo_label")"
check_risk "$worktree_label"
[[ "$(sed -n 1p "$tmp/risk.out")" == "risk: high" ]] || fail "check-risk.sh does not count the label: $(cat "$tmp/risk.out")"
grep -Fxq -- "- the Issue is labelled risk: high, which raises the level to high" "$tmp/risk.out" || fail "check-risk.sh does not name the label: $(cat "$tmp/risk.out")"
grep -Fxq "hint: high issue-label" "$tmp/risk.out" || fail "check-risk.sh does not name the hint and its source: $(cat "$tmp/risk.out")"
report="$(cd "$repo_label" && PATH="$tmp/bin:/usr/bin:/bin" ./scripts/report-runs.sh 7)"
grep -Fq "| high | implementer | claude | fable | level-line | 1 |" <<<"$report" || fail "the report lacks the call at the raised level: $report"
repo_other="$(setup_repo other-label)"
MOCK_ISSUE_LABELS=$'bug\nrisk: low\nhigh' run_start "$repo_other" 7 || { cat "$repo_other.out" >&2; fail "starting a feature with other labels failed"; }
started "$repo_other" codex sonnet "a feature with labels that name no raising level"
[[ "$(git -C "$repo_other" config --get branch.feature/7-feature-with-levels.workflow-risk-label || true)" == "" ]] ||
  fail "a label other than risk: high or risk: medium was kept"
[[ "$(risk_events "$repo_other")" == "[]" ]] || fail "a feature without a hint has a risk event of start-feature.sh: $(risk_events "$repo_other")"

# A label below the level of the diff is ignored and reported: the feature
# is high by its path, and the label risk: medium does not lower it.
repo_lower="$(setup_repo lower-label)"
MOCK_ISSUE_LABELS="risk: medium" run_start "$repo_lower" 8 thing || { cat "$repo_lower.out" >&2; fail "starting a feature labelled risk: medium failed"; }
mkdir -p "$tmp/lower-label-8-thing/src/auth"
printf 'login\n' >"$tmp/lower-label-8-thing/src/auth/login.txt"
check_risk "$tmp/lower-label-8-thing"
[[ "$(sed -n 1p "$tmp/risk.out")" == "risk: high" ]] || fail "a label lowered the level of the diff: $(cat "$tmp/risk.out")"
grep -Fxq -- "- the Issue is labelled risk: medium, below the computed high; a hint cannot lower the computed level and is ignored" "$tmp/risk.out" ||
  fail "a label below the computed level was not reported: $(cat "$tmp/risk.out")"

# --risk high does the same for one run, recorded with its source; the
# scripts of a later run do not see it.
repo_hint="$(setup_repo hint)"
run_start "$repo_hint" 9 thing --risk high || { cat "$repo_hint.out" >&2; fail "starting a feature with --risk high failed"; }
started "$repo_hint" claude fable "a new feature with --risk high"
grep -Fq "the owner gave --risk high for this run, which raises the level to high" "$repo_hint.out" ||
  fail "--risk high was not given as the reason of the level: $(cat "$repo_hint.out")"
recorded "$repo_hint" implementer high level-line "a new feature with --risk high"
[[ "$(git -C "$tmp/hint-9-thing" config --get branch.feature/9-thing.workflow-risk-label || true)" == "" ]] ||
  fail "--risk was kept in the configuration of the branch"
run_start "$repo_hint" 9 --resume --risk high || { cat "$repo_hint.out" >&2; fail "resuming a feature with --risk high failed"; }
[[ "$(git -C "$tmp/hint-9-thing" config --get branch.feature/9-thing.workflow-risk-label || true)" == "" ]] ||
  fail "--risk of a resumed session was kept in the configuration of the branch"
[[ "$(jq -c '[.[] | .hints] | .[0]' <<<"$(risk_events "$repo_hint")")" == '[{"level":"high","source":"command-line"}]' ]] ||
  fail "the run record does not note --risk and its source: $(risk_events "$repo_hint")"
check_risk "$tmp/hint-9-thing"
[[ "$(sed -n 1p "$tmp/risk.out")" == "risk: medium" ]] || fail "--risk outlived its run: $(cat "$tmp/risk.out")"
(cd "$tmp/hint-9-thing" && PATH="$tmp/bin:/usr/bin:/bin" WORKFLOW_RISK_HINT=high ./scripts/check-risk.sh main >"$tmp/risk.out" 2>&1) || true
[[ "$(sed -n 1p "$tmp/risk.out")" == "risk: high" ]] || fail "check-risk.sh does not count --risk of the run: $(cat "$tmp/risk.out")"
grep -Fxq "hint: high command-line" "$tmp/risk.out" || fail "check-risk.sh does not name --risk and its source: $(cat "$tmp/risk.out")"

# --risk low on a feature that the diff makes medium is ignored and reported.
repo_low="$(setup_repo low-hint)"
run_start "$repo_low" 10 thing --risk low || { cat "$repo_low.out" >&2; fail "starting a feature with --risk low failed"; }
started "$repo_low" codex sonnet "a medium feature with --risk low"
grep -Fq "the owner gave --risk low for this run, below the computed medium; a hint cannot lower the computed level and is ignored" "$repo_low.out" ||
  fail "--risk low was not reported as ignored: $(cat "$repo_low.out")"
recorded "$repo_low" implementer medium plain-line "a medium feature with --risk low"
printf 'other\n' >"$tmp/low-hint-10-thing/other.txt"
(cd "$tmp/low-hint-10-thing" && PATH="$tmp/bin:/usr/bin:/bin" WORKFLOW_RISK_HINT=low ./scripts/check-risk.sh main >"$tmp/risk.out" 2>&1) || true
[[ "$(sed -n 1p "$tmp/risk.out")" == "risk: medium" ]] || fail "--risk low lowered the level of the diff: $(cat "$tmp/risk.out")"
grep -Fxq -- "- the owner gave --risk low for this run, below the computed medium; a hint cannot lower the computed level and is ignored" "$tmp/risk.out" ||
  fail "check-risk.sh does not report --risk low as ignored: $(cat "$tmp/risk.out")"

# The labels are read again at every session, never to lower the level. A
# label risk: high added after the first session raises the next one to the
# High model, names the label, and is kept for the scripts of the feature.
label_of() {
  git -C "$1" config --get "branch.feature/$2.workflow-risk-label" || true
}
repo_later="$(setup_repo later-label)"
worktree_later="$tmp/later-label-12-thing"
run_start "$repo_later" 12 thing || { cat "$repo_later.out" >&2; fail "starting a feature that is not labelled yet failed"; }
started "$repo_later" codex sonnet "a feature that is not labelled yet"
[[ "$(label_of "$worktree_later" 12-thing)" == "" ]] || fail "a feature without a label kept one"
: >"$repo_later.log"
MOCK_ISSUE_LABELS="risk: high" run_start "$repo_later" 12 --resume || { cat "$repo_later.out" >&2; fail "resuming a feature labelled after its first session failed"; }
started "$repo_later" claude fable "a session after the Issue was labelled risk: high"
grep -Fq "Level:    high (computed by check-risk.sh against main; the Issue is labelled risk: high)" "$repo_later.out" ||
  fail "the label added later was not given as the reason of the level: $(cat "$repo_later.out")"
recorded "$repo_later" implementer high level-line "a session after the Issue was labelled risk: high"
[[ "$(label_of "$worktree_later" 12-thing)" == "high" ]] || fail "the label added later was not kept for the feature"
check_risk "$worktree_later"
[[ "$(sed -n 1p "$tmp/risk.out")" == "risk: high" ]] || fail "check-risk.sh does not count the label added later: $(cat "$tmp/risk.out")"
grep -Fxq -- "- the Issue is labelled risk: high, which raises the level to high" "$tmp/risk.out" ||
  fail "check-risk.sh does not name the label added later: $(cat "$tmp/risk.out")"

# A removed label does not lower the kept level, nor does a lower one: the
# level of a feature never goes down. The reason names the earlier session.
: >"$repo_later.log"
MOCK_ISSUE_LABELS="" run_start "$repo_later" 12 --resume || { cat "$repo_later.out" >&2; fail "resuming after the label was removed failed"; }
started "$repo_later" claude fable "a session after the label was removed"
grep -Fq "Level:    high (computed by check-risk.sh against main; the Issue was labelled risk: high at an earlier session)" "$repo_later.out" ||
  fail "the kept label was not given as the reason of the level: $(cat "$repo_later.out")"
[[ "$(label_of "$worktree_later" 12-thing)" == "high" ]] || fail "a removed label lowered the kept level"
MOCK_ISSUE_LABELS="risk: medium" run_start "$repo_later" 12 --resume || { cat "$repo_later.out" >&2; fail "resuming with a lower label failed"; }
grep -Fq "Level:    high (computed by check-risk.sh against main; the Issue was labelled risk: high at an earlier session)" "$repo_later.out" ||
  fail "the kept label was not given as the reason over a lower one: $(cat "$repo_later.out")"
[[ "$(label_of "$worktree_later" 12-thing)" == "high" ]] || fail "a lower label lowered the kept level"
check_risk "$worktree_later"
[[ "$(sed -n 1p "$tmp/risk.out")" == "risk: high" ]] || fail "the scripts of the feature lost the kept label: $(cat "$tmp/risk.out")"

# A connection that fails for a moment while the feature is resumed does not
# erase the kept label: the Issue is read three times, then the session runs
# at the kept level and says so. A refusal stops the session, as at the
# first start.
: >"$repo_later.log"
rm -f "$repo_later.log.gh-calls"
MOCK_GH_ISSUE_FLAKY=9 run_start "$repo_later" 12 --resume || { cat "$repo_later.out" >&2; fail "resuming while the Issue cannot be read failed"; }
[[ "$(cat "$repo_later.log.gh-calls")" -eq 3 ]] || fail "the Issue was not read three times before the kept label was used"
rm -f "$repo_later.log.gh-calls"
grep -Fq "could not read Issue #12 after 3 attempts" "$repo_later.out" || fail "the failed read of the Issue was not said: $(cat "$repo_later.out")"
grep -Fq "the label risk: high of an earlier session is kept." "$repo_later.out" || fail "the kept label was not said: $(cat "$repo_later.out")"
started "$repo_later" claude fable "a session while the Issue cannot be read"
grep -Fq "Level:    high (computed by check-risk.sh against main; the labels of the Issue could not be read; the label risk: high of an earlier session is kept)" "$repo_later.out" ||
  fail "the failed read was not given in the reason of the level: $(cat "$repo_later.out")"
[[ "$(label_of "$worktree_later" 12-thing)" == "high" ]] || fail "a failed read of the Issue erased the kept label"
: >"$repo_later.log"
if MOCK_GH_ISSUE_REFUSED=1 run_start "$repo_later" 12 --resume; then fail "a resumed session started although the Issue cannot be read"; fi
grep -Fq "could not read Issue #12: GraphQL: Resource not accessible by integration" "$repo_later.out" ||
  fail "the refused read of the Issue was not named: $(cat "$repo_later.out")"
[[ ! -s "$repo_later.log" ]] || fail "an agent was started although the read of the Issue was refused"

# A resume in a fresh clone, whose configuration holds no label and whose run
# records are empty, reads the label and uses it.
git -C "$worktree_later" push -q origin feature/12-thing
clone_later="$tmp/later-label-clone"
git clone -q "$tmp/later-label-remote.git" "$clone_later"
git -C "$clone_later" checkout -q feature/12-thing
MOCK_ISSUE_LABELS="risk: high" run_start "$clone_later" 12 --resume || { cat "$clone_later.out" >&2; fail "resuming in a fresh clone failed"; }
started "$clone_later" claude fable "a session in a fresh clone of a labelled feature"
grep -Fq "Level:    high (computed by check-risk.sh against main; the Issue is labelled risk: high)" "$clone_later.out" ||
  fail "the label was not read in a fresh clone: $(cat "$clone_later.out")"
[[ "$(label_of "$clone_later" 12-thing)" == "high" ]] || fail "the label was not kept in the fresh clone"

# A --risk without a level stops before anything is created.
repo_bad_hint="$(setup_repo bad-hint)"
if run_start "$repo_bad_hint" 11 thing --risk critical; then fail "a feature started with --risk critical"; fi
grep -Fq -- "--risk requires a level: low, medium, or high." "$repo_bad_hint.out" || fail "an invalid --risk was not named: $(cat "$repo_bad_hint.out")"
[[ ! -e "$tmp/bad-hint-11-thing" ]] || fail "a worktree was created although --risk is invalid"

# An invalid level line stops the script before anything is created.
repo_invalid="$(setup_repo invalid)"
printf 'implementer: codex sonnet\nimplementer@critical: claude fable\n' >"$repo_invalid/.agents/agents.conf"
git -C "$repo_invalid" -c user.name="Agent Levels Test" -c user.email="agent-levels-test@example.com" commit -qam "Break the configuration"
if run_start "$repo_invalid" 5 thing; then fail "a feature started with an invalid level line"; fi
grep -Fq "unknown risk level 'critical'" "$repo_invalid.out" || fail "the invalid level line was not named: $(cat "$repo_invalid.out")"
[[ ! -e "$tmp/invalid-5-thing" ]] || fail "a worktree was created although the configuration is invalid"
[[ ! -s "$repo_invalid.log" ]] || fail "an agent was started although the configuration is invalid"

# So does an unsupported provider or an invalid model on a level line of
# the reviewer, which start-feature.sh does not start: the whole file is
# validated before the implementer is resolved.
break_config() {
  printf '%s\n' "$@" >"$repo_invalid/.agents/agents.conf"
  git -C "$repo_invalid" -c user.name="Agent Levels Test" -c user.email="agent-levels-test@example.com" commit -qam "Break the configuration again"
}
break_config "implementer: codex sonnet" "reviewer: claude model-r" "reviewer@high: copilot nope"
if run_start "$repo_invalid" 5 thing; then fail "a feature started with an unsupported provider on the reviewer's level line"; fi
grep -Fq "unsupported agent 'copilot' for role 'reviewer@high' on line 3" "$repo_invalid.out" || fail "the reviewer's invalid line was not named: $(cat "$repo_invalid.out")"
[[ ! -e "$tmp/invalid-5-thing" ]] || fail "a worktree was created although the reviewer's level line is invalid"
[[ ! -s "$repo_invalid.log" ]] || fail "an agent was started although the reviewer's level line is invalid"
break_config "implementer: codex sonnet" "reviewer: claude model-r" "reviewer@high: claude --fallback"
if run_start "$repo_invalid" 5 thing; then fail "a feature started with an invalid model on the reviewer's level line"; fi
grep -Fq "for role 'reviewer@high' on line 3" "$repo_invalid.out" || fail "the reviewer's invalid model was not named: $(cat "$repo_invalid.out")"
[[ ! -e "$tmp/invalid-5-thing" ]] || fail "a worktree was created although the reviewer's model is invalid"
[[ ! -s "$repo_invalid.log" ]] || fail "an agent was started although the reviewer's model is invalid"

# The reviewer of a high feature is the one of its level line, and the
# review is recorded at that level.
finding() {
  printf '{"severity": "%s", "title": "%s", "evidence": "src/auth/login.txt:1", "impact": "The login is unchecked.", "recommendation": "Check it."}' "$1" "$2"
}
review_result="{\"architecture_impact\": {\"level\": \"minor\", \"rationale\": \"Stays within the accepted architecture.\", \"checked_against\": []}, \"verdict\": \"CHANGES_REQUIRED\", \"limitations\": \"\", \"findings\": [$(finding major "Login is unchecked")]}"
repo_review="$tmp/review"
mkdir -p "$repo_review/.agents/policies"
copy_workflow "$repo_review"
cp "$source_root/.gitignore" "$repo_review/.gitignore"
printf 'implementer: codex sonnet\nimplementer@high: claude fable\nreviewer: claude model-r\nreviewer@high: codex model-rh\n' >"$repo_review/.agents/agents.conf"
printf 'default: medium\nhigh: src/auth\n' >"$repo_review/.agents/policies/risk.conf"
printf 'count: echo run >>verify-count.log\n' >"$repo_review/scripts/verify.conf"
printf 'base\n' >"$repo_review/feature.txt"
git -C "$repo_review" init -q -b main
git -C "$repo_review" config user.name "Agent Levels Test"
git -C "$repo_review" config user.email "agent-levels-test@example.com"
git -C "$repo_review" add .
git -C "$repo_review" commit -qm "Seed"
git -C "$repo_review" switch -q -c feature/7-login
mkdir -p "$repo_review/src/auth"
printf 'login\n' >"$repo_review/src/auth/login.txt"
(
  cd "$repo_review"
  PATH="$tmp/bin:/usr/bin:/bin" MOCK_AGENT_LOG="$repo_review.log" MOCK_OUTPUT="$review_result" ./scripts/review-feature.sh 7 </dev/null
) >"$repo_review.out" 2>&1 || { cat "$repo_review.out" >&2; fail "reviewing a high feature failed"; }
started "$repo_review" codex model-rh "the review of a high feature"
grep -Fq "Level:    high (computed by check-risk.sh against main)" "$repo_review.out" || fail "the review did not show the level: $(cat "$repo_review.out")"
grep -Fq "Selected: by the line 'reviewer@high' of .agents/agents.conf" "$repo_review.out" || fail "the review did not show the selection"
recorded "$repo_review" reviewer high level-line "the review of a high feature"
[[ "$(jq -r '.risk.level' "$repo_review"/.agents/reviews/feature-7-login-review-01.json)" == "high" ]] || fail "the review artifact does not hold the level"


# The reviewer and the implementer resolve to the same provider for the
# level: the review refuses before the reviewer is called, for the pair of
# the level lines and for the plain pair alike. The command line can make
# the pair differ.
run_review() {
  (
    cd "$repo_review"
    PATH="$tmp/bin:/usr/bin:/bin" MOCK_AGENT_LOG="$repo_review.log" MOCK_OUTPUT="$review_result" ./scripts/review-feature.sh 7 "$@" </dev/null
  ) >"$repo_review.out" 2>&1
}
printf 'implementer: claude sonnet\nimplementer@high: codex model-ih\nreviewer: claude model-r\nreviewer@high: codex model-rh\n' >"$repo_review/.agents/agents.conf"
: >"$repo_review.log"
if run_review; then fail "a review whose reviewer and implementer resolve to codex at high started"; fi
grep -Fq "the reviewer and the implementer would both use codex for this high-risk feature" "$repo_review.out" ||
  fail "the refusal does not name the pair: $(cat "$repo_review.out")"
grep -Fq "the implementer by the line 'implementer@high'" "$repo_review.out" || fail "the refusal does not name the implementer's line: $(cat "$repo_review.out")"
[[ ! -s "$repo_review.log" ]] || fail "the reviewer was called although it uses the implementer's provider: $(cat "$repo_review.log")"
[[ ! -e "$repo_review/.agents/reviews/feature-7-login-review-02.json" ]] || fail "a refused review wrote an artifact"
printf 'implementer: codex sonnet\nreviewer: codex model-r\n' >"$repo_review/.agents/agents.conf"
if run_review; then fail "a review whose plain lines both name codex started"; fi
grep -Fq "the implementer by the line 'implementer' of .agents/agents.conf" "$repo_review.out" || fail "the plain pair was not refused: $(cat "$repo_review.out")"
[[ ! -s "$repo_review.log" ]] || fail "the reviewer was called although the plain lines use one provider"
run_review --agent claude --model model-cli || { cat "$repo_review.out" >&2; fail "a reviewer that --agent makes different was refused"; }
started "$repo_review" claude model-cli "the review with another provider from the command line"
[[ -f "$repo_review/.agents/reviews/feature-7-login-review-02.json" ]] || fail "the review with another provider wrote no artifact"

# The implementer ran with another provider than the configuration names
# (--agent on its command line): the run records of the feature hold the
# provider it ran with, and the review refuses a reviewer that resolves to
# it, by the configuration or by --agent; a reviewer with the provider the
# configuration names for the implementer is fine, since the implementer
# did not run with it. The sessions of another feature never count.
printf 'implementer: codex sonnet\nreviewer: claude model-r\n' >"$repo_review/.agents/agents.conf"
mkdir -p "$repo_review/.agents/run/records"
# session <run> <feature> <provider> <event...>: one line of a run file.
session() {
  local run="$1"
  local feature="$2"
  local provider="$3"
  shift 3
  for event in "$@"; do
    case "$event" in
      run-start) printf '{"schema": "run-record/v1", "run": "%s", "type": "run-start", "kind": "feature", "subject": "%s", "command": "start-feature.sh"}\n' "$run" "$feature" ;;
      agent-start) printf '{"schema": "run-record/v1", "run": "%s", "type": "agent-start", "id": "%s-call", "role": "implementer", "agent": "%s", "model": "model-x", "level": "high", "selection": "command-line"}\n' "$run" "$run" "$provider" ;;
      agent-call) printf '{"schema": "run-record/v1", "run": "%s", "type": "agent-call", "id": "%s-call", "role": "implementer", "agent": "%s", "model": "model-x", "status": 0, "seconds": 1, "level": "high", "selection": "command-line"}\n' "$run" "$run" "$provider" ;;
    esac
  done
}
session run-i1 7 claude run-start agent-start agent-call >"$repo_review/.agents/run/records/run-i1.jsonl"
# A session that was interrupted (a start without its call) counts too.
session run-i2 7 claude run-start agent-start >"$repo_review/.agents/run/records/run-i2.jsonl"
session run-o1 8 codex run-start agent-start agent-call >"$repo_review/.agents/run/records/run-o1.jsonl"
: >"$repo_review.log"
if run_review; then fail "a review started although the implementer ran with the reviewer's provider"; fi
grep -Fq "the reviewer would use claude, the provider the implementer ran with for this feature" "$repo_review.out" ||
  fail "the refusal does not name the recorded provider: $(cat "$repo_review.out")"
grep -Fq "hold 2 sessions of the implementer with claude" "$repo_review.out" || fail "the refusal does not count the sessions: $(cat "$repo_review.out")"
[[ ! -s "$repo_review.log" ]] || fail "the reviewer was called although the implementer ran with its provider: $(cat "$repo_review.log")"
[[ ! -e "$repo_review/.agents/reviews/feature-7-login-review-03.json" ]] || fail "a review refused for the recorded provider wrote an artifact"
if run_review --agent claude --model model-cli; then fail "--agent concealed that the implementer ran with the reviewer's provider"; fi
grep -Fq "the reviewer is selected by --agent or --model on the command line" "$repo_review.out" ||
  fail "the refusal of the reviewer from the command line does not say so: $(cat "$repo_review.out")"
[[ ! -s "$repo_review.log" ]] || fail "the reviewer from the command line was called although the implementer ran with its provider"
run_review --agent codex --model model-cli || { cat "$repo_review.out" >&2; fail "a reviewer with the provider the implementer is configured with, but did not run with, was refused"; }
started "$repo_review" codex model-cli "the review with the provider the implementer did not run with"
[[ -f "$repo_review/.agents/reviews/feature-7-login-review-03.json" ]] || fail "the review with the provider the implementer did not run with wrote no artifact"

# After a consolidation the copy of the feature holds the sessions that the
# run files still hold: the refusal counts each session once.
mkdir -p "$repo_review/.agents/records"
cat "$repo_review/.agents/run/records/run-i1.jsonl" "$repo_review/.agents/run/records/run-i2.jsonl" >"$repo_review/.agents/records/feature-7.jsonl"
: >"$repo_review.log"
if run_review; then fail "a review started although the implementer ran with the reviewer's provider (consolidated records)"; fi
grep -Fq "hold 2 sessions of the implementer with claude" "$repo_review.out" ||
  fail "the sessions were not counted once after the consolidation: $(grep -Fo 'hold [0-9]* sessions' "$repo_review.out")"
[[ ! -s "$repo_review.log" ]] || fail "the reviewer was called although the implementer ran with its provider (consolidated records)"

# An invalid line of a role that the review does not start (an unsupported
# provider, an invalid model, or a refused combination on a level line of the
# triage) is refused with its line before the reviewer is resolved: no agent
# is called and no artifact is written.
refused_review() {
  local line="$1"
  local message="$2"
  local description="$3"
  printf 'implementer: codex sonnet\nreviewer: claude model-r\n%s\n' "$line" >"$repo_review/.agents/agents.conf"
  : >"$repo_review.log"
  if run_review; then fail "a review started although $description"; fi
  grep -Fq "$message" "$repo_review.out" || fail "the invalid line of the triage was not named ($description): $(cat "$repo_review.out")"
  [[ ! -s "$repo_review.log" ]] || fail "the reviewer was called although $description"
  [[ ! -e "$repo_review/.agents/reviews/feature-7-login-review-04.json" ]] || fail "a review wrote an artifact although $description"
}
refused_review "triage@low: copilot nope" "unsupported agent 'copilot' for role 'triage@low' on line 3 of" "a level line of the triage names an unsupported provider"
refused_review "triage@low: claude --fallback" "for role 'triage@low' on line 3 of" "a level line of the triage names an invalid model"
refused_review "triage@low: codex fable" "unsupported agent/model combination: codex + fable for role 'triage@low' on line 3 of" "a level line of the triage names a refused combination"

echo "agent-levels tests passed"
