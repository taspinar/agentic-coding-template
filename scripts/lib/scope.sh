#!/usr/bin/env bash

# Filesystem scope enforcement for write-capable agent sessions.
# Source this file; do not execute it.
#
# A snapshot records the paths of a worktree with their type, mode, and
# content hash. Paths that the session may change are left out by a
# caller-supplied function. Comparing a snapshot taken before and after the
# session shows every out-of-scope change.
#
# What a snapshot covers:
# - every file that Git does not ignore, tracked or not, and a tracked file
#   that is missing;
# - every ignored file that is not inside a directory Git ignores as a whole,
#   such as a .env with a secret;
# - everything under .agents/, ignored or not: the review artifacts, the
#   triage, the approvals, and the working files of the workflow.
# It leaves out the directories that Git ignores as a whole, such as a Python
# environment, node_modules, a build output, or a test cache: a session that
# runs a command may create or change them, they are never part of what is
# reviewed or committed, and they can hold tens of thousands of files.

scope_file_mode() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

# Allowed paths of the project planner: the architecture, the roadmap, and
# direct Markdown ADRs.
scope_planner_allowed() {
  case "$1" in
    docs/architecture.md | docs/roadmap.md)
      return 0
      ;;
    docs/decisions/*.md)
      [[ "${1#docs/decisions/}" != */* ]]
      return
      ;;
    *)
      return 1
      ;;
  esac
}

# scope_paths
# Prints, NUL-delimited and sorted, the paths of the working tree in the
# current directory that a snapshot covers.
scope_paths() {
  local path

  {
    git ls-files -z --cached --others --exclude-standard
    # Ignored files one by one, and an ignored directory as one entry with a
    # trailing slash; only the files are kept.
    git ls-files -z --others --ignored --exclude-standard --directory |
      while IFS= read -r -d '' path; do
        [[ "$path" == */ ]] || printf '%s\0' "$path"
      done
    if [[ -d .agents ]]; then
      find .agents -mindepth 1 \( -type f -o -type l \) -print0 |
        while IFS= read -r -d '' path; do
          printf '%s\0' "${path#./}"
        done
    fi
  } | LC_ALL=C sort -zu
}

# scope_snapshot <worktree> <allowed-function> <target-file>
# Paths are read NUL-delimited and written escaped, so names with tabs or
# newlines cannot spoof an allowed path. The content of regular files is
# hashed in one batch, not with a process per file.
scope_snapshot() {
  local worktree="$1"
  local allowed="$2"
  local target="$3"
  local work

  work="$(mktemp -d "${TMPDIR:-/tmp}/scope.XXXXXX")"
  (
    cd "$worktree"
    : >"$work/regular"
    : >"$work/entries"
    scope_paths | while IFS= read -r -d '' path; do
      if "$allowed" "$path"; then
        continue
      fi
      # Every file operand starts with ./, so that no name is taken for an
      # option (a leading -) or for Git quoting (a leading "). The snapshot
      # keeps the name as it is.
      if [[ -L "$path" ]]; then
        printf '%q\tsymlink:%s:%s\n' "$path" "$(scope_file_mode "./$path")" "$(readlink "./$path")"
      elif [[ -f "$path" && "$path" == *$'\n'* ]]; then
        # A name with a newline cannot be handed over one per line.
        printf '%q\tregular:%s:%s\n' "$path" "$(scope_file_mode "./$path")" "$(git hash-object -- "./$path")"
      elif [[ -f "$path" ]]; then
        printf '%s\0' "$path" >>"$work/regular"
      elif [[ -e "$path" ]]; then
        printf '%q\tother:%s\n' "$path" "$(scope_file_mode "./$path")"
      else
        printf '%q\tmissing\n' "$path"
      fi
    done >"$work/entries"

    if [[ -s "$work/regular" ]]; then
      while IFS= read -r -d '' path; do
        printf './%s\0' "$path"
      done <"$work/regular" >"$work/operands"
      tr '\0' '\n' <"$work/operands" | git hash-object --stdin-paths >"$work/hashes"
      if [[ "$(uname -s)" == "Darwin" ]]; then
        xargs -0 stat -f '%Lp' <"$work/operands" >"$work/modes"
      else
        xargs -0 stat -c '%a' <"$work/operands" >"$work/modes"
      fi
      while IFS= read -r -d '' path && IFS= read -r hash <&3 && IFS= read -r mode <&4; do
        printf '%q\tregular:%s:%s\n' "$path" "$mode" "$hash"
      done <"$work/regular" 3<"$work/hashes" 4<"$work/modes" >>"$work/entries"
    fi
  )
  local status=$?
  if [[ "$status" -eq 0 ]]; then
    LC_ALL=C sort "$work/entries" >"$target"
  fi
  rm -rf "$work"
  return "$status"
}

# scope_unchanged <baseline-file> <current-file>
# Succeeds when both snapshots are equal; otherwise prints the escaped
# differences to standard error.
scope_unchanged() {
  if cmp -s "$1" "$2"; then
    return 0
  fi
  echo "Detected out-of-scope filesystem changes (escaped paths shown):" >&2
  diff -u "$1" "$2" >&2 || true
  return 1
}
