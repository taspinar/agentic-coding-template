#!/usr/bin/env bash

# Checks that the Markdown files of the repository name files that exist.
#
# For every tracked Markdown file:
#
# - a relative link must lead to a file or directory that exists, seen from
#   the file that holds the link: [text](path), [text](path "title"),
#   [text](<path with spaces>), and the definition of a reference link,
#   [name]: path, also when the path stands on the next line. A destination
#   may hold balanced parentheses. A link that leaves the repository is
#   checked too;
# - a path in backticks that starts with a tracked top-level directory and
#   names a .md, .sh, .conf, .json, .yml, or .yaml file must exist, seen from
#   the root of the repository.
#
# Not read: fenced code blocks, and links inside inline code; they show
# Markdown, they do not use it. Paths in inline code are read: that is how a
# document names a file.
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

# link_destinations <file>: prints the destination of every link of a
# Markdown file, one per line; a destination in angle brackets keeps them.
# Read: inline links, where a destination may hold balanced parentheses and
# may be followed by a title, and the definitions of reference links, also
# when the destination stands on the next line. Not read: fenced code blocks
# and inline code, which show Markdown instead of using it.
link_destinations() {
  awk '
    function run_length(text, at, mark,    count) {
      count = 0
      while (substr(text, at + count, 1) == mark) count++
      return count
    }
    # Inline code is delimited by runs of backticks of the same length.
    function without_code(line,    out, i, n, len, j, other, closed) {
      out = ""
      i = 1
      n = length(line)
      while (i <= n) {
        if (substr(line, i, 1) != "`") { out = out substr(line, i, 1); i++; continue }
        len = run_length(line, i, "`")
        j = i + len
        closed = 0
        while (j <= n) {
          if (substr(line, j, 1) != "`") { j++; continue }
          other = run_length(line, j, "`")
          if (other == len) { closed = 1; break }
          j += other
        }
        if (closed) { out = out " "; i = j + len } else { out = out substr(line, i, len); i += len }
      }
      return out
    }
    function inline_links(line,    i, n, c, depth, dest, close_at) {
      line = without_code(line)
      n = length(line)
      i = 1
      while (i < n) {
        if (substr(line, i, 2) != "](") { i++; continue }
        i += 2
        while (i <= n && substr(line, i, 1) ~ /[ \t]/) i++
        if (substr(line, i, 1) == "<") {
          close_at = index(substr(line, i), ">")
          if (close_at > 0) { print substr(line, i, close_at); i += close_at }
          continue
        }
        dest = ""
        depth = 0
        while (i <= n) {
          c = substr(line, i, 1)
          if (c == "(") depth++
          else if (c == ")") { if (depth == 0) break; depth-- }
          else if (c ~ /[ \t]/ && depth == 0) break
          dest = dest c
          i++
        }
        if (dest != "") print dest
      }
    }
    # A fenced code block opens with at least three backticks or tildes and
    # closes with a line of the same character, at least as many of them, and
    # nothing else. Another fence inside it is text.
    /^ ? ? ?(```|~~~)/ {
      fence = $0
      sub(/^ +/, "", fence)
      mark = substr(fence, 1, 1)
      count = run_length(fence, 1, mark)
      if (!fenced) {
        fenced = 1; fence_mark = mark; fence_count = count; waiting = 0
        next
      }
      if (mark == fence_mark && count >= fence_count && substr(fence, count + 1) ~ /^[ \t]*$/) fenced = 0
      next
    }
    fenced { next }
    waiting {
      waiting = 0
      if ($0 !~ /^[ \t]*$/) { sub(/^[ \t]+/, ""); print; next }
    }
    /^ ? ? ?\[[^]]+\]:/ {
      sub(/^ ? ? ?\[[^]]+\]:[ \t]*/, "")
      if ($0 == "") waiting = 1; else print
      next
    }
    { inline_links($0) }
  ' "$1"
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
  done < <(link_destinations "$file" || true)

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
