#!/usr/bin/env bash

# Checks that the Markdown files of the repository name files that exist.
#
# For every tracked Markdown file:
#
# - a relative link must lead to a file or directory that exists, seen from
#   the file that holds the link: [text](path), [text](path "title"),
#   [text](<path with spaces>), and the definition of a reference link,
#   [name]: path, also when the path stands on the next line. A link that
#   leaves the repository is checked too;
# - a path in backticks that starts with a tracked top-level directory and
#   names a .md, .sh, .conf, .json, .yml, or .yaml file must exist, seen from
#   the root of the repository.
#
# Not checked, for links and for paths alike: anchors, external links, a path
# with a placeholder ('<', '>', '*', '$', '{', '}', '...'), and a path that
# Git ignores, which is a working file. A project also describes files that come later, such as the approval
# of its planning: name those, or a directory that holds them, after --later.

set -euo pipefail

usage() {
  echo "Usage: $0 [--later <path>...]"
  echo
  echo "Checks that the tracked Markdown files name files that exist: relative"
  echo "links, and paths in backticks into a tracked top-level directory."
  echo
  echo "--later names paths that need not exist yet; a directory covers what is"
  echo "under it. Example:"
  echo "  $0 --later docs/PLANNING_APPROVAL.md docs/changes"
  exit 2
}

later=()
if [[ $# -gt 0 ]]; then
  [[ "$1" == "--later" ]] || usage
  shift
  [[ $# -gt 0 ]] || usage
  later=("$@")
fi

root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "Error: not inside a Git repository." >&2
  exit 2
}
cd "$root"

# comes_later <path>: whether the caller named the path or a directory above it.
comes_later() {
  local path="$1"
  local entry

  for entry in ${later[@]+"${later[@]}"}; do
    entry="${entry%/}"
    [[ "$path" == "$entry" || "$path" == "$entry"/* ]] && return 0
  done
  return 1
}

# normalize <path>: prints the path from the root of the repository without
# '.' and '..' parts, whether or not it exists. Fails when it leaves the
# repository.
normalize() {
  local IFS=/
  local parts
  local part
  local kept=()

  read -r -a parts <<<"$1"
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in
      "" | .) ;;
      ..)
        [[ ${#kept[@]} -gt 0 ]] || return 1
        unset "kept[$((${#kept[@]} - 1))]"
        ;;
      *) kept+=("$part") ;;
    esac
  done
  printf '%s\n' "${kept[*]-}"
}

# has_placeholder <path>: whether the path is a pattern, not one file.
has_placeholder() {
  case "$1" in
    *"<"* | *">"* | *"*"* | *'$'* | *"{"* | *"}"* | *"..."*) return 0 ;;
  esac
  return 1
}

# missing <path>: whether a path from the root of the repository is one this
# check should report: it does not exist, does not come later, and is not a
# working file that Git ignores.
missing() {
  [[ ! -e "$1" ]] && ! comes_later "$1" && ! git check-ignore -q "$1"
}

top_levels="$(git ls-files | sed -n 's|/.*||p' | sort -u)"
problems=0

problem() {
  echo "check-docs: $*" >&2
  problems=$((problems + 1))
}

while IFS= read -r file; do
  [[ -f "$file" ]] || continue
  directory="$(dirname "$file")"

  while IFS= read -r target; do
    # A destination in angle brackets may hold spaces; otherwise it is the
    # first word, and a title may follow it.
    if [[ "$target" == "<"*">"* ]]; then
      target="${target#<}"
      target="${target%%>*}"
    else
      target="${target%%[[:space:]]*}"
    fi
    case "$target" in
      http://* | https://* | mailto:* | "#"* | "") continue ;;
    esac
    target="${target%%#*}"
    target="${target%%\?*}"
    [[ -n "$target" ]] || continue
    has_placeholder "$target" && continue
    if [[ "$target" == /* ]]; then
      resolved="$(normalize "$target")" || resolved=""
    else
      resolved="$(normalize "$directory/$target")" || resolved=""
    fi
    if [[ -z "$resolved" ]]; then
      # The link leaves the repository, or is its root: nothing to exempt,
      # the destination has to be there.
      [[ -e "$directory/$target" ]] || problem "$file links to $target, which does not exist"
      continue
    fi
    ! missing "$resolved" || problem "$file links to $target, which does not exist"
  done < <(
    {
      # Inline links: what stands between "](" and ")".
      grep -oE '\]\([^)]+\)' "$file" | sed -E 's/^\]\([[:space:]]*//; s/\)$//'
      # Definitions of reference links: "[name]: destination", where the
      # destination may stand on the next line.
      awk '
        waiting {
          waiting = 0
          if ($0 !~ /^[ \t]*$/) { sub(/^[ \t]+/, ""); print; next }
        }
        /^ ? ? ?\[[^]]+\]:/ {
          sub(/^ ? ? ?\[[^]]+\]:[ \t]*/, "")
          if ($0 == "") waiting = 1; else print
        }
      ' "$file"
    } || true
  )

  while IFS= read -r path; do
    has_placeholder "$path" && continue
    case "$path" in
      /* | "~"* | ../* | ./*) continue ;;
    esac
    [[ "$path" == */* ]] || continue
    grep -Fxq "${path%%/*}" <<<"$top_levels" || continue
    ! missing "$path" || problem "$file names $path, which does not exist"
  done < <(
    grep -oE '`[^` ]+`' "$file" | tr -d '`' | sed -E 's/[.,:;]+$//' |
      grep -E '\.(md|sh|conf|json|ya?ml)$' | sort -u || true
  )
done < <(git ls-files '*.md')

if [[ "$problems" -gt 0 ]]; then
  echo "check-docs: $problems problem(s). Correct the reference, or name the path after --later when the file comes later." >&2
  exit 1
fi
echo "check-docs: the Markdown files name only files that exist."
