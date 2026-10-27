#!/usr/bin/env bash

# Content fingerprints of a working tree, of a commit, or of a set of files.
# Source this file; do not execute it.
#
# A fingerprint is the Git tree hash of the current file contents, including
# uncommitted and untracked changes. It depends on content only, so committing
# unchanged content keeps it valid, and any change to a covered file changes
# it. The real Git index is not touched; objects may be written to the object
# database.
#
# The content fingerprint, also called the content tree, says what was
# verified and reviewed. It has three neighbours that it is kept apart from:
#
# - An approval request (.agents/approval-requests/<issue>.json, written by
#   finish-feature.sh) says what the owner is asked to approve, and why. It
#   names the content tree; it is not part of it, so an edited explanation
#   changes nothing of the evidence.
# - The approval of a commit is the owner's review of the pull request on
#   GitHub, bound to the commit by GitHub. No file grants it (Issue #99).
#
# The exclusion policy is fixed, and this is the only place that holds it:
# left out of every content fingerprint are the metadata the workflow writes
# about the content (the review and triage artifacts, the record of the last
# passed verification, the run records, the state, logs and risk notes of a
# run) and the approval requests. Nothing else is left out: a plan under
# .agents/plans/ stays in, because a plan can change the acceptance criteria,
# the review scope, or the risk; so does every policy, prompt, schema, check
# list, and manifest. A feature cannot add an exclusion: this file is
# protected by the merge approval gate, and check-guardrails.sh reads the list
# from the base branch (fingerprint_excludes_at).
#
# What is left out is of two kinds, and the rule differs. Display-only
# files: an approval request changes the behavior of no script; a script
# reads it only to display it, and check-guardrails.sh can only refuse it.
# The rule that a field which affects behavior must enter the content
# fingerprint applies to display-only files and to nothing else: a file that
# a script would read for more than display is not left out as display-only,
# and the list is not extended for it. Decision artifacts: the review and
# triage artifacts are read by the gates (finish-feature.sh reads the
# verdict, the findings and the triage decisions), and that is their purpose;
# they change behavior only for the content tree they name. A review names
# the content it judged (reviewed_tree); an artifact whose reviewed_tree is
# not the tree of the current content is not current (check-review.sh), and
# a gate acts only on a current artifact that passes its schema; a triage
# must name the reviewed tree and the verdict of its review. The artifacts
# are left out so that the evidence cannot invalidate what it describes, and
# the scripts that run an agent hash them (fingerprint_artifacts) and refuse
# the result of an agent that changed or removed one. The verification record
# and the run records are left out and bound the same way: the record names
# the tree it passed for.
#
# The fingerprint of a feature review also covers the implementer's claims
# about the feature, which Git ignores: the completion record and the handoff
# note of the Issue (fingerprint_feature_claims). The reviewer of the
# complete feature judged them, so a change to either makes the review stale.
# The fingerprint of a verification does not cover them: a note about the
# verification does not change what was verified.

# The review and triage artifacts, which the content fingerprints leave out and
# fingerprint_artifacts covers.
FINGERPRINT_ARTIFACTS=(".agents/reviews" ".agents/triage")
# The approval requests of finish-feature.sh: committed with the feature,
# never part of its content.
FINGERPRINT_APPROVAL_REQUESTS=".agents/approval-requests"
# Left out of the content fingerprints: the artifacts, the approval requests,
# and what a run writes while it works and is never content, also in a
# project whose .gitignore does not name it: the record of the last passed
# verification (lib/verification.sh), the records of the runs
# (lib/records.sh), and the state, logs, and risk notes of run-feature.sh
# under .agents/run.
FINGERPRINT_EXCLUDES=("${FINGERPRINT_ARTIFACTS[@]}" "$FINGERPRINT_APPROVAL_REQUESTS" ".agents/verification" ".agents/run" ".agents/records")

# fingerprint_feature_claims <issue>
# Prints the files of the implementer's claims about a feature, one per line:
# the completion record and the handoff note of the Issue.
fingerprint_feature_claims() {
  printf '.agents/completion/%s.json\n.agents/handoffs/%s.md\n' "$1" "$1"
}

# feature_base <root> <base>
# Prints two lines: the ref of the base branch a feature is compared with,
# and the merge base of HEAD and that ref. A feature is created from
# origin/<base>, and the local <base> can be behind it or ahead of it, so of
# the two the one is used whose merge base with HEAD is the more recent:
# that is the point where the feature left its base. With a stale ref the
# merge base would lie further back, and everything merged since would count
# as the feature's own change. Fails when neither ref exists or shares
# history with HEAD.
feature_base() {
  local root="$1"
  local base="$2"
  local ref
  local found
  local best_ref=""
  local best=""

  for ref in "$base" "origin/$base"; do
    git -C "$root" rev-parse --verify --quiet "$ref^{commit}" >/dev/null || continue
    found="$(git -C "$root" merge-base HEAD "$ref" 2>/dev/null)" || continue
    if [[ -z "$best" ]] || { [[ "$found" != "$best" ]] && git -C "$root" merge-base --is-ancestor "$best" "$found"; }; then
      best="$found"
      best_ref="$ref"
    fi
  done
  [[ -n "$best" ]] || return 1
  printf '%s\n%s\n' "$best_ref" "$best"
}

# fingerprint_worktree <root> <scratch-dir> [<path>...]
# Prints the fingerprint of the whole working tree. Ignored files are left
# out unless Git already tracks them, or they are named as <path>: such a
# file is covered although Git ignores it, when it exists.
fingerprint_worktree() {
  local root="$1"
  local index="$2/fingerprint.index"
  local real_index
  local exclude_specs=()
  local forced=()
  local path

  shift 2
  for path in "$@"; do
    if [[ -e "$root/$path" || -L "$root/$path" ]]; then
      forced+=("$path")
    fi
  done
  # An excluded path that Git ignores is left out anyway; naming it would
  # make 'git add' refuse the ignored directory it is in.
  for path in "${FINGERPRINT_EXCLUDES[@]}"; do
    git -C "$root" check-ignore -q "$path" 2>/dev/null || exclude_specs+=(":(exclude)$path")
  done

  # Start from the real index so tracked files that match an ignore rule stay
  # covered. The path may be relative to the repository root.
  rm -f "$index"
  real_index="$(cd "$root" && git rev-parse --git-path index)"
  if (cd "$root" && [[ -f "$real_index" ]]); then
    (cd "$root" && cp "$real_index" "$index") || return 1
  fi

  GIT_INDEX_FILE="$index" git -C "$root" rm -r -q --cached --ignore-unmatch -- "${FINGERPRINT_EXCLUDES[@]}" >/dev/null &&
    GIT_INDEX_FILE="$index" git -C "$root" add -A -- . ${exclude_specs[@]+"${exclude_specs[@]}"} >/dev/null &&
    { [[ "${#forced[@]}" -eq 0 ]] || GIT_INDEX_FILE="$index" git -C "$root" add -f -- "${forced[@]}" >/dev/null; } &&
    GIT_INDEX_FILE="$index" git -C "$root" write-tree
}

# fingerprint_commit <root> <scratch-dir> <commit> [<exclude>...]
# Prints the content fingerprint of a commit: the tree of the commit without
# the excluded paths. It equals fingerprint_worktree of the working tree the
# commit was made from with 'git add -A', so the value finish-feature.sh
# prints before the commit is the value check-guardrails.sh recomputes from
# the commit. The excluded paths are FINGERPRINT_EXCLUDES, or the <exclude>
# arguments when given: the gate passes the list of the base branch.
fingerprint_commit() {
  local root="$1"
  local index="$2/fingerprint-commit.index"
  local commit="$3"
  local excludes=("${FINGERPRINT_EXCLUDES[@]}")

  shift 3
  [[ $# -eq 0 ]] || excludes=("$@")
  rm -f "$index"
  GIT_INDEX_FILE="$index" git -C "$root" read-tree "$commit^{tree}" &&
    GIT_INDEX_FILE="$index" git -C "$root" rm -r -q -f --cached --ignore-unmatch -- "${excludes[@]}" >/dev/null &&
    GIT_INDEX_FILE="$index" git -C "$root" write-tree
}

# fingerprint_excludes_at <root> <ref>
# Prints the exclusion list of this library as the commit <ref> has it, one
# path per line: the list the merge approval gate uses when it recomputes a
# content tree, read from the base branch so that a feature cannot add an
# exclusion for itself. Fails when <ref> has no copy of this library.
fingerprint_excludes_at() {
  local library

  library="$(git -C "$1" show "$2:scripts/lib/fingerprint.sh" 2>/dev/null)" || return 1
  bash -c 'eval "$1"; printf "%s\n" "${FINGERPRINT_EXCLUDES[@]}"' _ "$library"
}

# fingerprint_files <root> <scratch-dir> <path>...
# Prints the fingerprint of exactly the given repository-relative paths, which
# may be files, symlinks, or directories. A missing path is part of the
# fingerprint as absent. The excluded paths are left out here too.
fingerprint_files() {
  local root="$1"
  local index="$2/fingerprint-files.index"
  local specs=()
  local path

  shift 2
  for path in "$@"; do
    if [[ -e "$root/$path" || -L "$root/$path" ]]; then
      specs+=("$path")
    fi
  done

  rm -f "$index"
  if [[ "${#specs[@]}" -gt 0 ]]; then
    for path in "${FINGERPRINT_EXCLUDES[@]}"; do
      git -C "$root" check-ignore -q "$path" 2>/dev/null || specs+=(":(exclude)$path")
    done
    GIT_INDEX_FILE="$index" git -C "$root" add -f -- "${specs[@]}" >/dev/null || return 1
  fi
  GIT_INDEX_FILE="$index" git -C "$root" write-tree
}

# fingerprint_artifacts <root>
# Prints a hash of the review and triage artifacts, which every other
# fingerprint leaves out, so a run can detect that an agent changed them.
fingerprint_artifacts() {
  (
    cd "$1" || exit 1
    # A missing artifact directory is an empty set, not an error.
    { find "${FINGERPRINT_ARTIFACTS[@]}" \( -type f -o -type l \) 2>/dev/null || true; } | LC_ALL=C sort |
      while IFS= read -r path; do
        if [[ -L "$path" ]]; then
          printf '%s symlink %s\n' "$path" "$(readlink "$path")"
        else
          printf '%s %s\n' "$path" "$(git hash-object -- "$path")"
        fi
      done
  ) | git hash-object --stdin
}

# fingerprint_review <root> <scratch-dir> <review-json>
# Prints the current fingerprint of what the review covers: the paths in
# reviewed_paths when the review lists them, otherwise the whole working
# tree, and for a feature review the claims of the implementer about its
# Issue too (fingerprint_feature_claims).
fingerprint_review() {
  local root="$1"
  local scratch="$2"
  local review="$3"
  local paths=()
  local path
  local issue

  if jq -e '(.reviewed_paths | type) == "array"' "$review" >/dev/null; then
    while IFS= read -r path; do
      paths+=("$path")
    done < <(jq -r '.reviewed_paths[]' "$review")
    fingerprint_files "$root" "$scratch" ${paths[@]+"${paths[@]}"}
  else
    issue="$(jq -r 'if (.kind // "feature") == "feature" and (.issue | type) == "number" then (.issue | tostring) else "" end' "$review")"
    if [[ "$issue" =~ ^[0-9]+$ ]]; then
      while IFS= read -r path; do
        paths+=("$path")
      done < <(fingerprint_feature_claims "$issue")
    fi
    fingerprint_worktree "$root" "$scratch" ${paths[@]+"${paths[@]}"}
  fi
}

# review_is_current <root> <scratch-dir> <review-json>
# Succeeds when the reviewed content is unchanged since the review.
review_is_current() {
  local current

  current="$(fingerprint_review "$1" "$2" "$3")" || return 2
  [[ "$current" == "$(jq -r '.reviewed_tree' "$3")" ]]
}

# review_stale_notice <root> <scratch-dir> <review-json>
# Prints to standard error which paths differ between the reviewed content and
# the current content, so a stale review can be traced to its cause. Prints
# nothing when that cannot be determined, for example because the reviewed
# tree is no longer in the object database.
review_stale_notice() {
  local reviewed
  local current
  local changed
  local total

  reviewed="$(jq -r '.reviewed_tree' "$3" 2>/dev/null)" || return 0
  git -C "$1" cat-file -e "$reviewed^{tree}" 2>/dev/null || return 0
  current="$(fingerprint_review "$1" "$2" "$3" 2>/dev/null)" || return 0
  changed="$(git -C "$1" diff-tree -r --name-status "$reviewed" "$current" 2>/dev/null)" || return 0
  [[ -n "$changed" ]] || return 0

  total="$(printf '%s\n' "$changed" | grep -c .)"
  {
    echo "Changed since the review (A added, M modified, D deleted):"
    # sed reads all of its input, so a long list cannot end the pipe early.
    printf '%s\n' "$changed" | sed -n '1,20s/^/  /p'
    [[ "$total" -le 20 ]] || echo "  ... and $((total - 20)) more"
  } >&2
}
