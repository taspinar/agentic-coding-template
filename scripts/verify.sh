#!/usr/bin/env bash

set -euo pipefail

# The arguments as given, for the record of a verification (lib/records.sh).
records_arguments=("$@")

# Stable verification entry point for humans, agents, and CI.
# The required checks of the project are declared in scripts/verify.conf.
# The self-tests of the workflow scripts are declared in
# scripts/verify-workflow.conf and run only when a workflow file changed,
# or always with --all.
#
# A run in which every check passed is recorded for the content it verified
# (scripts/lib/verification.sh). With --reuse, a second run on identical
# content is skipped.
#
# A check may name a group: '<name> [<group>]: <command>'. A check without one
# belongs to the group 'default'. --only runs the checks of the named groups,
# for a CI that spreads the same checks over parallel jobs. Such a partial
# run is never a verification: it records nothing.
#
# A check may be a budget: '<name> [<group>] budget: <command>'. It measures
# something (a duration, a size, a count) against a target and exits non-zero
# over it. Such a result is a measurement, not a failure: the summary shows it
# as BUDGET with the output of the check, and the verification passes when
# every other check passed. The budget results are recorded with the pass
# (lib/verification.sh) and in the run record, so that the scripts show them
# where a decision is made; nothing repairs them. A budget check that does not
# finish (a signal, or the status 124 of 'timeout') or could not run (125 to
# 127, the statuses of 'timeout' and the shell for a command that was not
# invoked) is a FAIL like any check.
#
# Every check is timed. The durations are recorded with the pass and in the
# run record (lib/verification.sh). Each of the two files may declare one
# 'budget-seconds: <n>': the target for the duration of all of its checks
# in one run. A run over it shows BUDGET with the total, the target, and the
# slowest checks, recorded as a budget result like that of a budget check;
# it fails nothing. A partial run (--only) and a file whose checks did not
# run compare with nothing.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
config="$root/scripts/verify.conf"
workflow_config="$root/scripts/verify-workflow.conf"

comment_pattern='^[[:space:]]*(#.*)?$'
check_pattern='^([a-z0-9][a-z0-9-]*)([[:space:]]*\[([a-z0-9][a-z0-9-]*)\])?([[:space:]]+budget)?:[[:space:]]*(.*[^[:space:]])[[:space:]]*$'
default_group="default"

usage() {
  echo "Usage: $0 [--all] [--reuse]"
  echo "       $0 [--all] --only <group>[,<group>...]"
  echo "       $0 --groups"
  echo
  echo "Runs the checks in scripts/verify.conf. The workflow self-tests in"
  echo "scripts/verify-workflow.conf run only when a file listed under 'paths:' in"
  echo "that file differs from the base branch. --all runs them regardless."
  echo
  echo "--reuse skips the run when verification already passed for exactly the"
  echo "current content, as recorded by an earlier run."
  echo
  echo "--only runs the checks of the named groups only. A check names its group"
  echo "as '<name> [<group>]: <command>'; one without a group is in 'default'."
  echo "A partial run records nothing and cannot be combined with --reuse: only"
  echo "a run of every check verifies the content."
  echo
  echo "--groups prints the groups that have a check, one per line."
  echo
  echo "A check declared as '<name> [<group>] budget: <command>' is a budget: when it"
  echo "exits non-zero, the summary shows BUDGET with its output, and the verification"
  echo "passes when every other check passed. A budget check that does not finish or"
  echo "cannot run (exit 124 to 127, or a signal) fails: nothing was measured."
  echo
  echo "A line 'budget-seconds: <n>' in either file is the target for the duration of"
  echo "all checks of that file in one run. Over it, the summary shows BUDGET with the"
  echo "total, the target, and the five slowest checks; the verification still passes"
  echo "when every check passed. A partial run compares with nothing."
  exit 1
}

config_fail() {
  echo "Error: $*" >&2
  echo "Declare required checks as '<name>: <command>', '<name> [<group>]: <command>', or '<name> [<group>] budget: <command>', and a target for their duration as 'budget-seconds: <n>'." >&2
  exit 1
}

run_all=0
reuse=0
list_groups=0
only=""
partial=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) run_all=1 ;;
    --reuse) reuse=1 ;;
    --groups) list_groups=1 ;;
    --only)
      [[ $# -ge 2 && "$2" =~ ^[a-z0-9][a-z0-9-]*(,[a-z0-9][a-z0-9-]*)*$ ]] || usage
      only="$2"
      partial=1
      shift
      ;;
    *) usage ;;
  esac
  shift
done
if [[ "$partial" -eq 1 && "$reuse" -eq 1 ]]; then
  echo "Error: --only cannot be combined with --reuse: a partial run is not a verification, so there is nothing to reuse." >&2
  exit 1
fi
if [[ "$list_groups" -eq 1 && ( "$partial" -eq 1 || "$reuse" -eq 1 || "$run_all" -eq 1 ) ]]; then
  usage
fi

# The verification is recorded (lib/records.sh): its duration, its status,
# and whether a recorded pass was reused. A partial run (--only) is not a
# verification and is not recorded, also not into a run it was started in. Inside
# a run of the workflow it belongs to that run; run on its own in a feature or
# a planning worktree it is a run of that feature or planning. It runs as a
# child, so that every exit below is seen. Recording is best-effort: when it
# cannot be prepared, the verification runs without it.
if [[ -z "${RECORDS_VERIFICATION:-}" && -z "${RECORDS_DISABLED:-}" && "$list_groups" -eq 0 && "$partial" -eq 0 ]] &&
  [[ -f "$root/scripts/lib/records.sh" ]] && command -v jq >/dev/null 2>&1; then
  source "$root/scripts/lib/records.sh"
  if [[ -z "${RECORDS_RUN_ID:-}" ]]; then
    records_branch="$(git -C "$root" branch --show-current 2>/dev/null || true)"
    case "$records_branch" in
      feature/*) records_wrap feature "$(records_branch_issue)" "$0" ${records_arguments[@]+"${records_arguments[@]}"} ;;
      planning/*) records_wrap planning "${records_branch#planning/}" "$0" ${records_arguments[@]+"${records_arguments[@]}"} ;;
    esac
  fi
  records_mark=""
  if [[ -n "${RECORDS_RUN_ID:-}" ]] && ! records_mark="$(mktemp "${TMPDIR:-/tmp}/verify-reused.XXXXXX" 2>/dev/null)"; then
    records_mark=""
    echo "Warning: the record of this verification could not be prepared (no temporary file); the verification runs without it." >&2
  fi
  if [[ -n "$records_mark" ]]; then
    rm -f "$records_mark" 2>/dev/null || true
    records_started="$(date +%s)"
    records_call="$(records_id)"
    records_verification_start "$records_call" all
    records_status=0
    RECORDS_VERIFICATION="$records_mark" "$0" ${records_arguments[@]+"${records_arguments[@]}"} || records_status=$?
    records_reused=false
    [[ ! -e "$records_mark" ]] || records_reused=true
    # The budget results of the run, which the child writes next to the mark
    # (lib/verification.sh), also for a reused pass, and the durations of the
    # checks that ran, which a reused pass has none of.
    records_budgets='[]'
    records_checks='[]'
    if [[ -f "$root/scripts/lib/verification.sh" ]]; then
      source "$root/scripts/lib/verification.sh"
      records_budgets="$(verification_budgets_json "$records_mark.budgets" 2>/dev/null)" || records_budgets='[]'
      if declare -F verification_durations_json >/dev/null; then
        records_checks="$(verification_durations_json "$records_mark.durations" 2>/dev/null)" || records_checks='[]'
      fi
    fi
    rm -f "$records_mark" "$records_mark.budgets" "$records_mark.durations" 2>/dev/null || true
    records_verification "$records_status" "$(($(date +%s) - records_started))" "$records_reused" all "$records_call" "$records_budgets" "$records_checks"
    exit "$records_status"
  fi
fi

# Working files of this run: the output of each budget check, the budget
# results and the durations of the checks (lib/verification.sh), and the
# index of a fingerprint.
scratch="$(mktemp -d "${TMPDIR:-/tmp}/verify.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
budgets_file="$scratch/budgets"
durations_file="$scratch/durations"

# A passed run is recorded only where the record is a file that Git ignores.
recordable=0
for library in fingerprint verification; do
  [[ -f "$root/scripts/lib/$library.sh" ]] || continue
  source "$root/scripts/lib/$library.sh"
done
if declare -F verification_recordable >/dev/null && declare -F fingerprint_worktree >/dev/null &&
  verification_recordable "$root"; then
  recordable=1
fi

# budget_result <name> <status> <exit> <output-file>
# Keeps the result of a budget check for the record and the run record, with
# lib/verification.sh; without the library the summary alone shows it.
budget_result() {
  ! declare -F verification_budget_add >/dev/null || verification_budget_add "$budgets_file" "$@"
}

# hand_budgets_to_run
# Gives the budget results to the run that records this verification, when
# one does: the wrapper above reads them next to its mark.
hand_budgets_to_run() {
  [[ -n "${RECORDS_VERIFICATION:-}" && -s "$budgets_file" ]] || return 0
  cp "$budgets_file" "$RECORDS_VERIFICATION.budgets" 2>/dev/null || true
}

# hand_durations_to_run
# Gives the durations of the checks that ran to the run that records this
# verification, as hand_budgets_to_run does.
hand_durations_to_run() {
  [[ -n "${RECORDS_VERIFICATION:-}" && -s "$durations_file" ]] || return 0
  cp "$durations_file" "$RECORDS_VERIFICATION.durations" 2>/dev/null || true
}

# now_ms: the time in milliseconds; whole seconds where the shell has no
# EPOCHREALTIME (bash before 5).
now_ms() {
  local now="${EPOCHREALTIME:-}"

  if [[ -n "$now" ]]; then
    now="${now/[.,]/}"
    echo "$((10#${now:0:${#now}-3}))"
  else
    echo "$(($(date +%s) * 1000))"
  fi
}

# seconds_text <ms>: '12.3s'.
seconds_text() {
  printf '%d.%ds' "$(($1 / 1000))" "$(($1 % 1000 / 100))"
}

names=()
commands=()
groups=()
budgets=()
workflow_paths=""
budget_seconds=""
project_budget_seconds=""
workflow_budget_seconds=""

# load_checks <file> <paths-entry>
# Appends the checks of <file> to names, commands, groups, and budgets ('yes'
# for a budget check). With <paths-entry> 'yes', the reserved entry 'paths:'
# sets workflow_paths instead of declaring a check. The reserved entry
# 'budget-seconds:' sets budget_seconds, the target for the duration of the
# checks of <file>.
load_checks() {
  local file="$1"
  local paths_entry="$2"
  local label="${1#"$root"/}"
  local line
  local line_number=0
  local name
  local group
  local budget
  local value
  local existing

  budget_seconds=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    [[ "$line" =~ $comment_pattern ]] && continue
    [[ "$line" =~ $check_pattern ]] ||
      config_fail "malformed check on line $line_number of $label: $line"

    name="${BASH_REMATCH[1]}"
    group="${BASH_REMATCH[3]}"
    budget="${BASH_REMATCH[4]:+yes}"
    value="${BASH_REMATCH[5]}"
    if [[ "$paths_entry" == "yes" && "$name" == "paths" ]]; then
      [[ -z "$group" ]] || config_fail "'paths' takes no group on line $line_number of $label."
      [[ -z "$budget" ]] || config_fail "'paths' is not a check and cannot be a budget, on line $line_number of $label."
      [[ -z "$workflow_paths" ]] ||
        config_fail "'paths' is declared more than once in $label."
      workflow_paths="$value"
      continue
    fi
    if [[ "$name" == "budget-seconds" ]]; then
      [[ -z "$group" && -z "$budget" ]] ||
        config_fail "'budget-seconds' is a target, not a check: it takes no group and is no budget check, on line $line_number of $label."
      [[ "$value" =~ ^[1-9][0-9]*$ ]] ||
        config_fail "'budget-seconds' needs a whole number of seconds greater than 0, on line $line_number of $label: $value"
      [[ -z "$budget_seconds" ]] ||
        config_fail "'budget-seconds' is declared more than once in $label."
      budget_seconds="$value"
      continue
    fi
    for existing in ${names[@]+"${names[@]}"}; do
      [[ "$existing" != "$name" ]] ||
        config_fail "duplicate check name on line $line_number of $label: $name"
    done
    names+=("$name")
    commands+=("$value")
    groups+=("${group:-$default_group}")
    budgets+=("${budget:-no}")
  done <"$file"
}

# in_list <value> <comma-separated-list>
in_list() {
  [[ ",$2," == *",$1,"* ]]
}

# workflow_files_changed
# Exits 0 when a file under workflow_paths differs from the base branch,
# counting uncommitted and untracked files, 1 when none does, and 2 when that
# cannot be determined. Sets workflow_base to the base branch used.
workflow_files_changed() {
  local specs=()
  local ref
  local base=""
  local changed

  read -r -a specs <<<"$workflow_paths"
  command -v git >/dev/null 2>&1 || return 2
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 2
  for ref in origin/main main; do
    if base="$(git -C "$root" merge-base "$ref" HEAD 2>/dev/null)" && [[ -n "$base" ]]; then
      workflow_base="$ref"
      break
    fi
    base=""
  done
  [[ -n "$base" ]] || return 2

  changed="$(
    git -C "$root" diff --name-only "$base" -- "${specs[@]}" &&
      git -C "$root" ls-files --others --exclude-standard -- "${specs[@]}"
  )" || return 2
  [[ -n "$changed" ]]
}

[[ "$list_groups" -eq 1 ]] || echo "== Agentic project verification =="

[[ -f "$config" ]] || config_fail "verification config not found: $config"
load_checks "$config" no
project_budget_seconds="$budget_seconds"
[[ "${#names[@]}" -gt 0 ]] || config_fail "scripts/verify.conf declares no checks."

# Decide whether the workflow self-tests run. Their checks follow the project
# checks; a project without scripts/verify-workflow.conf has none.
project_count="${#names[@]}"
workflow_note=""
workflow_skipped=""
workflow_base=""
if [[ -f "$workflow_config" ]]; then
  load_checks "$workflow_config" yes
  workflow_budget_seconds="$budget_seconds"
  workflow_count=$((${#names[@]} - project_count))
  [[ "$workflow_count" -gt 0 ]] || config_fail "scripts/verify-workflow.conf declares no checks."
  [[ -n "$workflow_paths" ]] ||
    config_fail "scripts/verify-workflow.conf must declare the workflow files as 'paths: <pathspec>...'."

  if [[ "$run_all" -eq 1 ]]; then
    workflow_note="requested with --all"
  else
    changed_status=0
    workflow_files_changed || changed_status=$?
    case "$changed_status" in
      0) workflow_note="a workflow file differs from $workflow_base" ;;
      1) workflow_skipped="SKIP  workflow self-tests ($workflow_count checks): no workflow file differs from $workflow_base; --all runs them" ;;
      *) workflow_note="could not determine whether a workflow file changed" ;;
    esac
  fi
fi

# The groups that have a check, in the order of their first check.
known_groups=""
for group in "${groups[@]}"; do
  in_list "$group" "$known_groups" || known_groups="${known_groups:+$known_groups,}$group"
done
if [[ "$list_groups" -eq 1 ]]; then
  printf '%s\n' "${known_groups//,/$'\n'}"
  exit 0
fi
if [[ "$partial" -eq 1 ]]; then
  IFS=, read -r -a wanted <<<"$only"
  for group in "${wanted[@]}"; do
    in_list "$group" "$known_groups" ||
      config_fail "no check is in the group '$group'. The groups are: ${known_groups//,/, }."
  done
  echo "Only the groups: ${only//,/, }. A partial run is not a verification and records nothing."
fi

# With --reuse, a recorded pass for exactly this content stands in for a run.
# A record made without the workflow self-tests does not cover a run that
# needs them.
tree_before=""
if [[ "$recordable" -eq 1 ]]; then
  tree_before="$(fingerprint_worktree "$root" "$scratch")" || tree_before=""
  if [[ "$reuse" -eq 1 && -n "$tree_before" && "$(verification_field "$root" tree)" == "$tree_before" ]]; then
    recorded_workflow="$(verification_field "$root" workflow-tests)"
    if [[ "$recorded_workflow" != "skipped" || ( -n "$workflow_skipped" && "$run_all" -eq 0 ) ]]; then
      echo
      echo "Verification already passed for this content at $(verification_field "$root" verified-at); not run again."
      echo "Run ./scripts/verify.sh without --reuse to run every check."
      recorded_budgets="$(verification_budgets "$root")"
      if [[ -n "$recorded_budgets" ]]; then
        echo "Its budget results, recorded with the pass:"
        printf '%s\n' "$recorded_budgets" | verification_budget_report | sed 's/^/  /'
        printf '%s\n' "$recorded_budgets" >"$budgets_file"
        hand_budgets_to_run
      fi
      [[ -z "${RECORDS_VERIFICATION:-}" ]] || { : >"$RECORDS_VERIFICATION"; } 2>/dev/null || true
      exit 0
    fi
  fi
fi

# record_duration <index> <ms> <result>
# Keeps the duration of a check that ran: for the duration budgets below, and
# with lib/verification.sh for the record and the run record. <result> is
# 'pass', 'fail', or 'budget'.
record_duration() {
  durations[$1]="$2"
  ! declare -F verification_duration_add >/dev/null ||
    verification_duration_add "$durations_file" "${names[$1]}" "$(config_of "$1")" "$2" "$3"
}

# config_of <index>: the file that declares the check.
config_of() {
  if [[ "$1" -lt "$project_count" ]]; then echo "scripts/verify.conf"; else echo "scripts/verify-workflow.conf"; fi
}

# duration_budget <label> <target-seconds> <first-index> <end-index>
# Compares the duration of the checks <first-index> to <end-index> - 1, the
# checks of the file <label>, with its target. Over it, the summary shows
# BUDGET with the total, the target, and the five slowest checks, and the
# result is kept as a budget result named 'duration of <label>': a
# measurement that fails nothing. Within it, nothing is shown.
duration_budget() {
  local label="$1"
  local target="$2"
  local index
  local total=0
  local output

  [[ -n "$target" ]] || return 0
  for ((index = $3; index < $4; index++)); do
    total=$((total + ${durations[$index]:-0}))
  done
  [[ "$total" -gt $((target * 1000)) ]] || return 0
  output="$scratch/duration-budget.out"
  {
    echo "$(seconds_text "$total") in total, target ${target}s; the slowest checks:"
    for ((index = $3; index < $4; index++)); do
      [[ -z "${durations[$index]:-}" ]] || printf '%s\t%s\n' "${durations[$index]}" "${names[$index]}"
    done | sort -t $'\t' -k1,1nr | head -n 5 | while IFS=$'\t' read -r ms check; do
      echo "$check $(seconds_text "$ms")"
    done
  } >"$output"
  echo "Note: the checks of $label took $(seconds_text "$total"), over the target of ${target}s. A budget is a measurement, not a failure: the verification does not fail for it, and nothing repairs it." >&2
  results+=("BUDGET  duration of $label ($(seconds_text "$total"), target ${target}s)")
  while IFS= read -r line; do
    results+=("        $line")
  done < <(tail -n +2 "$output")
  budget_result "duration of $label" exceeded - "$output"
  duration_exceeded=$((duration_exceeded + 1))
}

results=()
failed=0
exceeded=0
duration_exceeded=0
durations=()
for index in "${!names[@]}"; do
  if [[ "$index" -eq "$project_count" ]]; then
    [[ -z "$workflow_skipped" ]] || break
    echo
    echo "== Workflow self-tests: $workflow_note =="
  fi
  name="${names[$index]}"
  command="${commands[$index]}"
  budget="${budgets[$index]}"
  if [[ "$partial" -eq 1 ]] && ! in_list "${groups[$index]}" "$only"; then
    continue
  fi
  read -r tool _ <<<"$command"

  echo
  if [[ "$budget" == "yes" ]]; then
    echo "-- $name (budget): $command"
  else
    echo "-- $name: $command"
  fi

  if ! (cd "$root" && command -v "$tool" >/dev/null 2>&1); then
    echo "Error: required check '$name' cannot run; '$tool' is missing or not executable." >&2
    results+=("FAIL  $name (missing tool: $tool)")
    failed=1
    record_duration "$index" 0 fail
    continue
  fi

  started="$(now_ms)"
  set +e
  # A check is not part of the run that verifies: a workflow script that it
  # starts, as the self-tests do, must not write into that run's records, and
  # must not use the agent or attribution configuration that was chosen for
  # that run. The output of a budget check is kept: it is the measurement.
  if [[ "$budget" == "yes" ]]; then
    output="$scratch/budget-$name.out"
    (
      unset AGENT_CONFIG_FILE ATTRIBUTION_CONFIG_FILE
      unset RECORDS_RUN_ID RECORDS_FILE RECORDS_COMMAND RECORDS_KIND RECORDS_SUBJECT RECORDS_VERIFICATION RECORDS_DISABLED
      cd "$root" && bash -eo pipefail -c "$command"
    ) 2>&1 | tee "$output"
    status="${PIPESTATUS[0]}"
  else
    (
      unset AGENT_CONFIG_FILE ATTRIBUTION_CONFIG_FILE
      unset RECORDS_RUN_ID RECORDS_FILE RECORDS_COMMAND RECORDS_KIND RECORDS_SUBJECT RECORDS_VERIFICATION RECORDS_DISABLED
      cd "$root" && bash -eo pipefail -c "$command"
    )
    status=$?
  fi
  set -e
  elapsed=$(($(now_ms) - started))
  echo "-- $name took $(seconds_text "$elapsed")"

  if [[ "$status" -eq 0 ]]; then
    if [[ "$budget" == "yes" ]]; then
      results+=("PASS  $name (budget within its target)")
      budget_result "$name" within "$status" "$output"
    else
      results+=("PASS  $name")
    fi
    record_duration "$index" "$elapsed" pass
  elif [[ "$budget" == "yes" && ("$status" -le 123 || "$status" -eq 128) ]]; then
    # Over the target: a measurement, not a failure. The exit statuses 1..123
    # and 128 are the check's own: 124 of 'timeout' and a death by a signal
    # (129 and up) mean that the check did not finish, and 125..127 (an error
    # of 'timeout' itself, a command that is not executable or not found)
    # that it could not run; in both nothing was measured, and it fails like
    # any check. 128 is not reserved: no utility returns it for a command that
    # was not invoked, so a measurement may use it like any other status.
    echo "Note: budget '$name' exceeded its target (exit $status). A budget is a measurement, not a failure: the verification does not fail for it, and nothing repairs it." >&2
    results+=("BUDGET  $name (exit $status)")
    if [[ -s "$output" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
        results+=("        $line")
      done <"$output"
    else
      results+=("        (no output)")
    fi
    budget_result "$name" exceeded "$status" "$output"
    exceeded=$((exceeded + 1))
    record_duration "$index" "$elapsed" budget
  else
    if [[ "$budget" == "yes" && "$status" -ge 125 && "$status" -le 127 ]]; then
      echo "Error: budget check '$name' could not run (status $status: an error of 'timeout', or a command that is not executable or not found): nothing was measured, so it fails like any check." >&2
      results+=("FAIL  $name (exit $status, the budget check could not run)")
    elif [[ "$budget" == "yes" ]]; then
      echo "Error: budget check '$name' did not finish (status $status): nothing was measured, so it fails like any check." >&2
      results+=("FAIL  $name (exit $status, the budget check did not finish)")
    else
      echo "Error: required check '$name' failed with status $status." >&2
      results+=("FAIL  $name (exit $status)")
    fi
    failed=1
    record_duration "$index" "$elapsed" fail
  fi
done

# The targets for the duration of each file's checks, compared only in a
# complete run of that file.
if [[ "$partial" -eq 0 ]]; then
  duration_budget "scripts/verify.conf" "$project_budget_seconds" 0 "$project_count"
  [[ -n "$workflow_skipped" ]] ||
    duration_budget "scripts/verify-workflow.conf" "$workflow_budget_seconds" "$project_count" "${#names[@]}"
fi

echo
echo "== Verification summary =="
[[ "${#results[@]}" -eq 0 ]] || printf '%s\n' "${results[@]}"
[[ -z "$workflow_skipped" ]] || echo "$workflow_skipped"
if [[ "$duration_exceeded" -gt 0 ]]; then
  echo "The checks took longer than the target of 'budget-seconds' (BUDGET): a measurement, not a failure. The owner decides whether to change the target or the checks; nothing repairs it automatically."
fi
if [[ "$exceeded" -gt 0 ]]; then
  echo "$exceeded budget check(s) exceeded their target (BUDGET): a measurement, not a failure. The owner decides whether to change the budget or the code; nothing repairs it automatically."
fi
if [[ "$partial" -eq 0 ]]; then
  hand_budgets_to_run
  hand_durations_to_run
fi

if [[ "$failed" -ne 0 ]]; then
  [[ "$recordable" -eq 0 ]] || verification_forget "$root"
  echo "Verification failed." >&2
  exit 1
fi

# A partial run passed its own checks and says nothing about the others: an
# existing record is left as it is, and none is written.
if [[ "$partial" -eq 1 ]]; then
  echo "The checks of the groups ${only//,/, } passed. Not a verification: run ./scripts/verify.sh without --only for that."
  exit 0
fi

# Record the pass for the content that was verified. When a check changed a
# file, no single content was verified, so nothing is recorded.
if [[ "$recordable" -eq 1 ]]; then
  if [[ -n "$tree_before" && "$(fingerprint_worktree "$root" "$scratch")" == "$tree_before" ]]; then
    if [[ ! -f "$workflow_config" ]]; then
      workflow_state="none"
    elif [[ -n "$workflow_skipped" ]]; then
      workflow_state="skipped"
    else
      workflow_state="ran"
    fi
    verification_write "$root" "$tree_before" "$workflow_state" "$budgets_file" "$durations_file" ||
      echo "Warning: could not record the passed verification." >&2
  else
    verification_forget "$root"
  fi
fi

echo "Verification passed."
