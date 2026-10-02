#!/usr/bin/env bash

# The planning documents and the planning approval.
# Source this file after fingerprint.sh; do not execute it.

# The planning scope: every document of the project planning. It names the
# optional description and the decisions directory even when they are absent,
# so adding, changing, or deleting any planning document changes its
# fingerprint.
PLANNING_SCOPE=(docs/PROJECT_DESCRIPTION.md docs/PROJECT_REQUIREMENTS.md docs/architecture.md docs/roadmap.md docs/decisions)
PLANNING_APPROVAL_FILE="docs/PLANNING_APPROVAL.md"

# planning_approval_status <root> <scratch-dir>
# Exits 0 when the recorded planning approval matches the current planning
# documents, 1 when it is missing or stale, and 2 when it is malformed. Prints
# the reason for a non-zero status.
planning_approval_status() {
  local root="$1"
  local scratch="$2"
  local approval="$root/$PLANNING_APPROVAL_FILE"
  local recorded
  local current

  if [[ ! -f "$approval" ]]; then
    echo "the planning has not been approved: $PLANNING_APPROVAL_FILE is missing."
    return 1
  fi
  grep -Fqx "Status: Approved" "$approval" || {
    echo "$PLANNING_APPROVAL_FILE does not record an approval."
    return 2
  }
  recorded="$(sed -n 's/^Planning fingerprint: \([0-9a-f]\{40,64\}\)$/\1/p' "$approval")"
  [[ "$(printf '%s' "$recorded" | grep -c .)" -eq 1 ]] || {
    echo "$PLANNING_APPROVAL_FILE must contain exactly one valid planning fingerprint."
    return 2
  }
  current="$(fingerprint_files "$root" "$scratch" "${PLANNING_SCOPE[@]}")" || {
    echo "could not compute the fingerprint of the planning documents."
    return 2
  }
  if [[ "$current" != "$recorded" ]]; then
    echo "a planning document changed after the planning was approved."
    return 1
  fi
}
