#!/usr/bin/env bash

# Checks the documentation site against the repository it describes:
#
# - every link to a page, a file of the site, or a place on a page resolves;
# - every link to a file of this repository on GitHub names a file that exists;
# - every script a page names exists in scripts/;
# - every page has the same sidebar.
#
# Run from anywhere: ./documentation/check.sh

set -euo pipefail

site="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd "$site/.." && pwd -P)"
repository_url="https://github.com/taspinar/agentic-coding-template/blob/main/"
problems=0

problem() {
  echo "documentation: $*" >&2
  problems=$((problems + 1))
}

# sidebar <page>: the sidebar of a page, without the mark of the current page.
sidebar() {
  sed -n '/<aside class="sidebar"/,/<\/aside>/p' "$1" | sed 's/ aria-current="page"//'
}

pages=("$site"/*.html)
[[ -f "${pages[0]}" ]] || { echo "documentation: no pages in $site" >&2; exit 1; }
reference="$(sidebar "$site/index.html")"

for page in "${pages[@]}"; do
  name="$(basename "$page")"

  while IFS= read -r target; do
    case "$target" in
      "$repository_url"*)
        path="${target#"$repository_url"}"
        path="${path%%#*}"
        [[ -e "$root/$path" ]] || problem "$name links to $path, which is not in the repository"
        ;;
      http://* | https://* | mailto:*) ;;
      "#"*)
        grep -Fq "id=\"${target#\#}\"" "$page" || problem "$name links to $target, which is not on the page"
        ;;
      *)
        file="${target%%#*}"
        [[ -f "$site/$file" ]] || { problem "$name links to $file, which does not exist"; continue; }
        if [[ "$target" == *"#"* ]]; then
          grep -Fq "id=\"${target#*#}\"" "$site/$file" || problem "$name links to $target, which is not on that page"
        fi
        ;;
    esac
  done < <(grep -oE '(href|src)="[^"]*"' "$page" | sed -E 's/^(href|src)="//; s/"$//')

  while IFS= read -r script; do
    [[ -f "$root/scripts/$script" ]] || problem "$name names $script, which is not in scripts/"
  done < <(grep -oE '[a-z][a-z-]*\.sh' "$page" | sort -u)

  [[ "$(sidebar "$page")" == "$reference" ]] || problem "the sidebar of $name differs from that of index.html"
  grep -q 'aria-current="page"' "$page" || problem "$name marks no entry of the sidebar as the current page"
done

if [[ "$problems" -gt 0 ]]; then
  echo "documentation: $problems problem(s)." >&2
  exit 1
fi
echo "documentation: ${#pages[@]} pages checked."
