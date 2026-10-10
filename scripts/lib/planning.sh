#!/usr/bin/env bash

# The planning documents and the planning approval.
# Source this file after fingerprint.sh; do not execute it.

# The planning scope: every document of the project planning. It names the
# optional description, the change requests of later change cycles, and the
# decisions directory even when they are absent, so adding, changing, or
# deleting any planning document changes its fingerprint.
PLANNING_SCOPE=(docs/PROJECT_DESCRIPTION.md docs/changes docs/PROJECT_REQUIREMENTS.md docs/architecture.md docs/roadmap.md docs/decisions)
PLANNING_APPROVAL_FILE="docs/PLANNING_APPROVAL.md"

# The part of the planning that only a planning cycle may change: what the
# product is and which features it gets. The rest of the scope, the
# architecture and the ADRs, is also kept up to date by features, which the
# Definition of Done asks for and a feature review covers.
PLANNING_PRODUCT_SCOPE=(docs/PROJECT_DESCRIPTION.md docs/changes docs/PROJECT_REQUIREMENTS.md docs/roadmap.md)

# planning_tree_at <root> <scratch> <commit> <path...>
# Prints the fingerprint of the given paths as they are in a commit; it is
# comparable with fingerprint_files of the same content in a working tree.
planning_tree_at() {
  local root="$1"
  local index="$2/planning-tree-at.index"
  local commit="$3"

  shift 3
  rm -f "$index"
  GIT_INDEX_FILE="$index" git -C "$root" read-tree --empty &&
    git -C "$root" ls-tree -r "$commit" -- "$@" |
    GIT_INDEX_FILE="$index" git -C "$root" update-index --index-info &&
    GIT_INDEX_FILE="$index" git -C "$root" write-tree
}

# planning_approval_commit <root> <scratch> <recorded-fingerprint> [<from>]
# Prints the commit that recorded the approval: the last commit before
# <from> (default HEAD) that changed the approval file, when the planning
# documents in that commit have the recorded fingerprint. Prints nothing
# when there is none, for example after the file was edited by hand.
planning_approval_commit() {
  local root="$1"
  local scratch="$2"
  local recorded="$3"
  local from="${4:-HEAD}"
  local commit

  commit="$(git -C "$root" log -1 --format=%H "$from" -- "$PLANNING_APPROVAL_FILE" 2>/dev/null)" || return 0
  [[ -n "$commit" ]] || return 0
  [[ "$(planning_tree_at "$root" "$scratch" "$commit" "${PLANNING_SCOPE[@]}" 2>/dev/null)" == "$recorded" ]] || return 0
  printf '%s\n' "$commit"
}

# planning_feature_updates <root> <from> <to>
# Lists the commits between two commits that changed the architecture or the
# ADRs, oldest first, one per line: "<hash> <subject>", followed by the Issue
# and the review that finish-feature.sh recorded in the commit message, when
# the commit has them.
planning_feature_updates() {
  local root="$1"
  local commit
  local body
  local issue
  local review

  git -C "$root" log --no-merges --reverse --format='%H' "$2..$3" -- docs/architecture.md docs/decisions |
    while IFS= read -r commit; do
      body="$(git -C "$root" log -1 --format=%b "$commit")"
      issue="$(printf '%s\n' "$body" | sed -n 's/^Issue: //p' | head -n 1)"
      review="$(printf '%s\n' "$body" | sed -n 's/^Review: //p' | head -n 1)"
      printf '%s' "$(git -C "$root" log -1 --format='%h %s' "$commit")"
      [[ -z "$issue" && -z "$review" ]] ||
        printf ' (%s%s%s)' "${issue:+Issue $issue}" "${issue:+${review:+; }}" "${review:+review: $review}"
      printf '\n'
    done
}

# planning_recorded_updates <approval-file>
# Prints the updates by merged work that an approval file already records, as
# list items, so that a later approval keeps them.
planning_recorded_updates() {
  [[ -f "$1" ]] || return 0
  awk '
    /^## / { section = $0; next }
    section == "## Updates by merged work" && /^- / { print; next }
    section == "## Amendments after the approval" && /^  - / { sub(/^  /, ""); print }
  ' "$1"
}

# planning_approval_status <root> <scratch-dir>
# Exits 0 when the recorded planning approval is current, 1 when it is missing
# or stale, and 2 when it is malformed. Prints the reason for a non-zero
# status.
#
# The approval is current when the planning documents are as approved. It is
# also current when only the architecture or the ADRs changed since the commit
# that recorded it: features keep those up to date, under their own review.
# PLANNING_APPROVAL_UPDATED_SINCE then holds that commit, and is empty
# otherwise. A change to the description, the requirements, a change request,
# or the roadmap always makes the approval stale.
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
  PLANNING_APPROVAL_UPDATED_SINCE=""
  [[ "$current" != "$recorded" ]] || return 0

  local approved
  local product_now
  local product_then

  approved="$(planning_approval_commit "$root" "$scratch" "$recorded")"
  if [[ -n "$approved" ]] && git -C "$root" diff --quiet "$approved" -- "$PLANNING_APPROVAL_FILE" 2>/dev/null; then
    product_now="$(fingerprint_files "$root" "$scratch" "${PLANNING_PRODUCT_SCOPE[@]}")" || product_now=""
    product_then="$(planning_tree_at "$root" "$scratch" "$approved" "${PLANNING_PRODUCT_SCOPE[@]}")" || product_then=""
    if [[ -n "$product_now" && "$product_now" == "$product_then" ]]; then
      PLANNING_APPROVAL_UPDATED_SINCE="$approved"
      return 0
    fi
    echo "the description, the requirements, a change request, or the roadmap changed after the planning was approved; only a planning cycle may change those."
    return 1
  fi
  echo "a planning document changed after the planning was approved."
  return 1
}
