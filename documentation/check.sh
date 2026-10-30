#!/usr/bin/env bash

# Checks the built documentation site against itself and the repository it
# describes:
#
# - every link or asset of a page, and every url() of a style sheet, resolves
#   to a file of the output, under the base path the site was built for;
# - every link to a place on a page finds that place;
# - every link to a file of this repository on GitHub names a file that exists;
# - every script a page names exists in scripts/;
# - every page has a title, a description and a canonical address, and every
#   address of sitemap.xml is a page of the output;
# - every colour, font and spacing value of the style sheets in src/styles/ is
#   a design token (--tokens).
#
# The design reference (design/) is not part of the build and not checked.
#
# Usage:
#   ./documentation/check.sh --build
#       Checks the tokens of src/styles/, builds the site under the project
#       path (/agentic-coding-template/) and under the root (/), and checks
#       both outputs. Needs the dependencies: npm ci in documentation/ first.
#   ./documentation/check.sh <output> <base-path> [<site-url>]
#       Checks an output that is already built for that base path.
#   ./documentation/check.sh --tokens <style sheet>...
#       Checks that outside :root and @font-face a font or spacing property
#       names only tokens (var()), 0 and keywords, and that no rule names a
#       colour literal.

set -euo pipefail

site="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd "$site/.." && pwd -P)"
repository="$(sed -n 's/^ *repository: "\(.*\)",$/\1/p' "$site/site.config.ts")"
[[ -n "$repository" ]] || { echo "documentation: no repository in site.config.ts" >&2; exit 1; }
default_site_url="https://taspinar.github.io"
problems=0

problem() {
  echo "documentation: $*" >&2
  problems=$((problems + 1))
}

# resolve <output> <base> <page directory> <target>: the file of the output
# that a link without its fragment names, or nothing when it leaves the base.
resolve() {
  local output="$1" base="$2" directory="$3" target="$4" path
  case "$target" in
    /*)
      [[ "$target" == "$base"* ]] || return 0
      path="$output/${target#"$base"}"
      ;;
    *) path="$directory/$target" ;;
  esac
  [[ "$path" == */ ]] && path="${path}index.html"
  echo "$path"
}

# check_tokens <style sheet>: reports each declaration of a rule that sets a
# font or spacing value other than a token, 0 or a keyword, and each colour
# literal. The tokens themselves are the :root blocks; @font-face describes
# the font files.
check_tokens() {
  local css="$1" declaration
  while IFS= read -r declaration; do
    problem "${css#"$site"/} sets '$declaration', which is not a token"
  done < <(tr '\n' ' ' <"$css" |
    sed -E 's#/\*([^*]|\*+[^*/])*\*+/##g; s/@font-face *\{[^}]*\}//g; s/:root[^{]*\{[^}]*\}//g' |
    tr ';{}' '\n\n\n' | sed -E 's/^ +//; s/ +$//' |
    awk '
      /^[a-z-]+ *:/ {
        property = $0; sub(/ *:.*/, "", property)
        value = $0; sub(/^[^:]*: */, "", value)
        if (value ~ /#[0-9a-fA-F]{3,8}([^0-9a-zA-Z_-]|$)|(rgb|hsl)a?\(/) { print; next }
        if (property !~ /^(font|font-size|font-weight|font-family|line-height|letter-spacing|margin(-[a-z-]+)?|padding(-[a-z-]+)?|gap|row-gap|column-gap|scroll-padding(-[a-z-]+)?)$/) next
        gsub(/var\([^)]*\)/, " ", value); gsub(/\//, " ", value)
        n = split(value, words, " ")
        for (i = 1; i <= n; i++)
          if (words[i] !~ /^(0|auto|inherit|initial|unset|none|normal)$/) { print; next }
      }')
}

# check_output <output> <base> <site-url>
check_output() {
  local output="$1" base="$2" site_url="$3"
  local page name target file path fragment script css location count=0

  [[ -f "$output/index.html" ]] || { problem "no index.html in $output"; return; }

  while IFS= read -r -d '' page; do
    count=$((count + 1))
    name="${page#"$output"/} (base $base)"

    while IFS= read -r target; do
      case "$target" in
        "$repository/blob/"* | "$repository/tree/"*)
          path="${target#"$repository/"*/*/}"
          path="${path%%#*}"
          [[ -e "$root/$path" ]] || problem "$name links to $path, which is not in the repository"
          ;;
        http://* | https://* | mailto:*) ;;
        "#"*)
          grep -Fq "id=\"${target#\#}\"" "$page" || problem "$name links to $target, which is not on the page"
          ;;
        *)
          file="$(resolve "$output" "$base" "$(dirname "$page")" "${target%%#*}")"
          if [[ -z "$file" ]]; then
            problem "$name links to $target, which is outside the base path $base"
          elif [[ ! -f "$file" ]]; then
            problem "$name links to $target, which is not in the output"
          elif [[ "$target" == *"#"* ]]; then
            fragment="${target#*#}"
            grep -Fq "id=\"$fragment\"" "$file" || problem "$name links to $target, which is not on that page"
          fi
          ;;
      esac
    done < <(grep -oE '(href|src)="[^"]*"' "$page" | sed -E 's/^(href|src)="//; s/"$//' | sed 's/&amp;/\&/g' | sort -u)

    while IFS= read -r script; do
      [[ -f "$root/scripts/$script" ]] || problem "$name names $script, which is not in scripts/"
    done < <(sed 's/<[^>]*>/ /g' "$page" | grep -oE '[a-z][a-z-]*\.sh' | sort -u)

    grep -q '<title>[^<]' "$page" || problem "$name has no title"
    grep -q '<meta name="description" content="[^"]' "$page" || problem "$name has no description"
    grep -Fq "<link rel=\"canonical\" href=\"$site_url$base" "$page" || problem "$name has no canonical address under $site_url$base"
  done < <(find "$output" -name '*.html' -print0)

  while IFS= read -r -d '' css; do
    while IFS= read -r target; do
      file="$(resolve "$output" "$base" "$(dirname "$css")" "$target")"
      [[ -n "$file" && -f "$file" ]] || problem "${css#"$output"/} (base $base) uses $target, which is not in the output"
    done < <(grep -oE 'url\([^)]*\)' "$css" | sed -E 's/^url\(["'\'']?//; s/["'\'']?\)$//' | grep -v '^data:' | sort -u)
  done < <(find "$output" -name '*.css' -print0)

  if [[ -f "$output/sitemap.xml" ]]; then
    while IFS= read -r location; do
      file="$(resolve "$output" "$base" "$output" "${location#"$site_url"}")"
      [[ "$location" == "$site_url$base"* && -n "$file" && -f "$file" ]] || problem "sitemap.xml (base $base) lists $location, which is not a page of the output"
    done < <(grep -oE '<loc>[^<]*</loc>' "$output/sitemap.xml" | sed -E 's/<\/?loc>//g')
  else
    problem "no sitemap.xml in $output"
  fi
  [[ -f "$output/robots.txt" ]] || problem "no robots.txt in $output"

  echo "documentation: $count pages checked under $base."
}

if [[ "${1:-}" == "--build" ]]; then
  [[ -d "$site/node_modules" ]] || { echo "documentation: run npm ci in $site first" >&2; exit 1; }
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  for css in "$site"/src/styles/*.css; do check_tokens "$css"; done
  for base in /agentic-coding-template/ /; do
    output="$work/output-$(echo "$base" | tr -d /)"
    (cd "$site" && SITE_URL="$default_site_url" BASE_PATH="$base" ASTRO_TELEMETRY_DISABLED=1 \
      npx --no-install astro build --silent --outDir "$output") ||
      { echo "documentation: the build under $base failed" >&2; exit 1; }
    check_output "$output" "$base" "$default_site_url"
  done
elif [[ "${1:-}" == "--tokens" && $# -ge 2 ]]; then
  shift
  for css in "$@"; do check_tokens "$css"; done
elif [[ $# -ge 2 ]]; then
  check_output "$(cd "$1" && pwd -P)" "$2" "${3:-$default_site_url}"
else
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
fi

if [[ "$problems" -gt 0 ]]; then
  echo "documentation: $problems problem(s)." >&2
  exit 1
fi
