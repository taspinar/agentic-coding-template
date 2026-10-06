#!/usr/bin/env bash

set -euo pipefail

# Stable verification entry point for humans, agents, and CI.
# The required checks of the project are declared in scripts/verify.conf.
# The self-tests of the workflow scripts are declared in
# scripts/verify-workflow.conf and run only when a workflow file changed,
# or always with --all.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
config="$root/scripts/verify.conf"
workflow_config="$root/scripts/verify-workflow.conf"

comment_pattern='^[[:space:]]*(#.*)?$'
check_pattern='^([a-z0-9][a-z0-9-]*):[[:space:]]*(.*[^[:space:]])[[:space:]]*$'

usage() {
  echo "Usage: $0 [--all]"
  echo
  echo "Runs the checks in scripts/verify.conf. The workflow self-tests in"
  echo "scripts/verify-workflow.conf run only when a file listed under 'paths:' in"
  echo "that file differs from the base branch. --all runs them regardless."
  exit 1
}

config_fail() {
  echo "Error: $*" >&2
  echo "Declare required checks as '<name>: <command>'." >&2
  exit 1
}

run_all=0
case "$#:${1:-}" in
  0:) ;;
  1:--all) run_all=1 ;;
  *) usage ;;
esac

names=()
commands=()
workflow_paths=""

# load_checks <file> <paths-entry>
# Appends the checks of <file> to names and commands. With <paths-entry> 'yes',
# the reserved entry 'paths:' sets workflow_paths instead of declaring a check.
load_checks() {
  local file="$1"
  local paths_entry="$2"
  local label="${1#"$root"/}"
  local line
  local line_number=0
  local name
  local value
  local existing

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    [[ "$line" =~ $comment_pattern ]] && continue
    [[ "$line" =~ $check_pattern ]] ||
      config_fail "malformed check on line $line_number of $label: $line"

    name="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    if [[ "$paths_entry" == "yes" && "$name" == "paths" ]]; then
      [[ -z "$workflow_paths" ]] ||
        config_fail "'paths' is declared more than once in $label."
      workflow_paths="$value"
      continue
    fi
    for existing in ${names[@]+"${names[@]}"}; do
      [[ "$existing" != "$name" ]] ||
        config_fail "duplicate check name on line $line_number of $label: $name"
    done
    names+=("$name")
    commands+=("$value")
  done <"$file"
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

echo "== Agentic project verification =="

[[ -f "$config" ]] || config_fail "verification config not found: $config"
load_checks "$config" no
[[ "${#names[@]}" -gt 0 ]] || config_fail "scripts/verify.conf declares no checks."

# Decide whether the workflow self-tests run. Their checks follow the project
# checks; a project without scripts/verify-workflow.conf has none.
project_count="${#names[@]}"
workflow_note=""
workflow_skipped=""
workflow_base=""
if [[ -f "$workflow_config" ]]; then
  load_checks "$workflow_config" yes
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

results=()
failed=0
for index in "${!names[@]}"; do
  if [[ "$index" -eq "$project_count" ]]; then
    [[ -z "$workflow_skipped" ]] || break
    echo
    echo "== Workflow self-tests: $workflow_note =="
  fi
  name="${names[$index]}"
  command="${commands[$index]}"
  read -r tool _ <<<"$command"

  echo
  echo "-- $name: $command"

  if ! (cd "$root" && command -v "$tool" >/dev/null 2>&1); then
    echo "Error: required check '$name' cannot run; '$tool' is missing or not executable." >&2
    results+=("FAIL  $name (missing tool: $tool)")
    failed=1
    continue
  fi

  set +e
  (cd "$root" && bash -eo pipefail -c "$command")
  status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    results+=("PASS  $name")
  else
    echo "Error: required check '$name' failed with status $status." >&2
    results+=("FAIL  $name (exit $status)")
    failed=1
  fi
done

echo
echo "== Verification summary =="
printf '%s\n' "${results[@]}"
[[ -z "$workflow_skipped" ]] || echo "$workflow_skipped"

if [[ "$failed" -ne 0 ]]; then
  echo "Verification failed." >&2
  exit 1
fi

echo "Verification passed."
