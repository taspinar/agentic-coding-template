#!/usr/bin/env bash

# Tests check.sh on small outputs written here, without a build: a correct
# output under each base path passes, and every kind of fault is reported.
#
# Run from anywhere: ./documentation/check-test.sh

set -euo pipefail

site="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
url="https://taspinar.github.io"
repository="https://github.com/taspinar/agentic-coding-template/blob/main"
failures=0

fail() {
  echo "check-test: $*" >&2
  failures=$((failures + 1))
}

# page <file> <base> <canonical path> <body>: writes a page of the output.
page() {
  mkdir -p "$(dirname "$1")"
  printf '<!doctype html><html><head><title>T</title><meta name="description" content="D"><link rel="canonical" href="%s%s"><link rel="stylesheet" href="%s_astro/s.css"></head><body id="top">%s</body></html>\n' \
    "$url" "$3" "$2" "$4" >"$1"
}

# output <dir> <base>: a correct output of two pages for that base path.
output() {
  local dir="$1" base="$2"
  mkdir -p "$dir/_astro" "$dir/fonts"
  : >"$dir/fonts/f.woff2"
  printf '@font-face{src:url(%sfonts/f.woff2)}\n' "$base" >"$dir/_astro/s.css"
  page "$dir/index.html" "$base" "$base" "<a href=\"${base}docs/#intro\">docs</a> <a href=\"#top\">top</a> <a href=\"$repository/docs/workflow.md\">w</a> run doctor.sh"
  page "$dir/docs/index.html" "$base" "${base}docs/" "<h2 id=\"intro\">i</h2><a href=\"$base\">home</a>"
  printf '<urlset><url><loc>%s%s</loc></url><url><loc>%s%sdocs/</loc></url></urlset>\n' "$url" "$base" "$url" "$base" >"$dir/sitemap.xml"
  : >"$dir/robots.txt"
}

# expect_fault <name> <base> <command that breaks the output> <message>
expect_fault() {
  local name="$1" base="$2" breaks="$3" message="$4" dir="$work/$1" result
  output "$dir" "$base"
  (cd "$dir" && eval "$breaks")
  if result="$("$site/check.sh" "$dir" "$base" 2>&1)"; then
    fail "$name: check.sh passed"
  elif ! grep -Fq "$message" <<<"$result"; then
    fail "$name: no '$message' in: $result"
  fi
}

for base in /agentic-coding-template/ /; do
  output "$work/good" "$base"
  "$site/check.sh" "$work/good" "$base" >/dev/null 2>&1 || fail "a correct output under $base does not pass"
  rm -rf "$work/good"
done

expect_fault missing-page /agentic-coding-template/ \
  'rm -r docs' "links to /agentic-coding-template/docs/#intro, which is not in the output"
expect_fault outside-base /agentic-coding-template/ \
  'sed -i "s|/agentic-coding-template/docs/|/docs/|" index.html' "which is outside the base path"
expect_fault missing-place / \
  'sed -i "s|id=\"intro\"||" docs/index.html' "which is not on that page"
expect_fault missing-anchor / \
  'sed -i "s|id=\"top\"||" index.html' "links to #top, which is not on the page"
expect_fault missing-repository-file / \
  'sed -i "s|docs/workflow.md|docs/missing.md|" index.html' "docs/missing.md, which is not in the repository"
expect_fault missing-script / \
  'sed -i "s|doctor.sh|no-such-script.sh|" index.html' "names no-such-script.sh, which is not in scripts/"
expect_fault missing-font /agentic-coding-template/ \
  'rm fonts/f.woff2' "uses /agentic-coding-template/fonts/f.woff2, which is not in the output"
expect_fault missing-canonical / \
  'sed -i "s|rel=\"canonical\"|rel=\"x\"|" docs/index.html' "has no canonical address"
expect_fault sitemap-page / \
  'rm -r docs && sed -i "s|href=\"/docs/#intro\"|href=\"#top\"|" index.html' "sitemap.xml (base /) lists"

# The tokens: a style sheet that names only tokens passes; a literal font,
# spacing or colour value outside :root and @font-face is reported.
tokens="$work/tokens.css"
printf '%s\n' '@font-face { font-family: "F"; font-weight: 400; src: url(f.woff2); }' \
  ':root { --ink: #141617; --t-sm: 0.9rem; --s-2: 0.5rem; --w-bold: 700; }' \
  '@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --ink: #e9ebec; } }' \
  '/* padding: 1rem; color: #fff */' \
  'a:hover { color: var(--ink); border: 1px solid var(--ink); }' \
  'p { font: var(--w-bold) var(--t-sm)/var(--t-sm) var(--sans); margin: 0 auto; padding: var(--s-2) 0; }' >"$tokens"
"$site/check.sh" --tokens "$tokens" >/dev/null 2>&1 || fail "a style sheet of tokens does not pass"
for literal in 'line-height: 1.6' 'padding: 0.3rem var(--s-2)' 'font: 700 var(--t-sm) var(--sans)' 'font-weight: 600' \
  'letter-spacing: -0.02em' 'gap: 4px' 'color: #00804a' 'background: rgb(0, 0, 0)'; do
  printf 'b { %s; }\n' "$literal" >"$work/literal.css"
  if result="$("$site/check.sh" --tokens "$work/literal.css" 2>&1)"; then
    fail "tokens: '$literal' passed"
  elif ! grep -Fq "sets '$literal', which is not a token" <<<"$result"; then
    fail "tokens: no report of '$literal' in: $result"
  fi
done

if [[ "$failures" -gt 0 ]]; then
  echo "check-test: $failures failure(s)." >&2
  exit 1
fi
echo "check-test: passed."
