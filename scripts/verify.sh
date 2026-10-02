#!/usr/bin/env bash

set -euo pipefail

# Stable verification entry point for humans, agents, and CI.
# The required checks are declared in scripts/verify.conf.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
config="$root/scripts/verify.conf"

comment_pattern='^[[:space:]]*(#.*)?$'
check_pattern='^([a-z0-9][a-z0-9-]*):[[:space:]]*(.*[^[:space:]])[[:space:]]*$'

config_fail() {
  echo "Error: $*" >&2
  echo "Declare required checks in scripts/verify.conf as '<name>: <command>'." >&2
  exit 1
}

echo "== Agentic project verification =="

[[ -f "$config" ]] || config_fail "verification config not found: $config"

names=()
commands=()
line_number=0
while IFS= read -r line || [[ -n "$line" ]]; do
  line_number=$((line_number + 1))
  [[ "$line" =~ $comment_pattern ]] && continue
  [[ "$line" =~ $check_pattern ]] ||
    config_fail "malformed check on line $line_number of scripts/verify.conf: $line"

  name="${BASH_REMATCH[1]}"
  for existing in ${names[@]+"${names[@]}"}; do
    [[ "$existing" != "$name" ]] ||
      config_fail "duplicate check name on line $line_number of scripts/verify.conf: $name"
  done
  names+=("$name")
  commands+=("${BASH_REMATCH[2]}")
done <"$config"

[[ "${#names[@]}" -gt 0 ]] || config_fail "scripts/verify.conf declares no checks."

results=()
failed=0
for index in "${!names[@]}"; do
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

if [[ "$failed" -ne 0 ]]; then
  echo "Verification failed." >&2
  exit 1
fi

echo "Verification passed."
