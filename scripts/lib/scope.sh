#!/usr/bin/env bash

# Filesystem scope enforcement for write-capable agent sessions.
# Source this file; do not execute it.
#
# A snapshot records every path in a worktree, including untracked and ignored
# files but not .git, with its type, mode, and content hash. Paths that the
# session may change are left out by a caller-supplied function. Comparing a
# snapshot taken before and after the session shows every out-of-scope change.

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

# scope_snapshot <worktree> <allowed-function> <target-file>
# Paths are read NUL-delimited and written escaped, so names with tabs or
# newlines cannot spoof an allowed path.
scope_snapshot() {
  local worktree="$1"
  local allowed="$2"
  local target="$3"

  (
    cd "$worktree"
    find . -mindepth 1 ! -path './.git' -print0 |
      while IFS= read -r -d '' relative; do
        path="${relative#./}"
        if "$allowed" "$path"; then
          continue
        fi

        if [[ -L "$path" ]]; then
          signature="symlink:$(scope_file_mode "$path"):$(readlink "$path")"
        elif [[ -f "$path" ]]; then
          signature="regular:$(scope_file_mode "$path"):$(git hash-object -- "$path")"
        elif [[ -d "$path" ]]; then
          signature="directory:$(scope_file_mode "$path")"
        else
          signature="other:$(scope_file_mode "$path")"
        fi

        path_key="$(printf '%s' "$path" | git hash-object --stdin)"
        printf '%s\t%q\t%s\n' "$path_key" "$path" "$signature"
      done
  ) | LC_ALL=C sort >"$target"
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
