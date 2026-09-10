#!/usr/bin/env bash
set -euo pipefail
base="${1:-main}"
root="$(git rev-parse --show-toplevel)"
branch="$(git branch --show-current)"
slug="${branch//\//-}"
out="$root/.agents/reviews/${slug}.md"
cat > "$out" <<EOT
# Independent Review — $branch

Base: $base
Reviewed commit: $(git rev-parse HEAD)

> Run an independent reviewer (Claude/Codex/etc.) using `.agents/prompts/reviewer.md` and write its findings below. This script intentionally does not hard-code a model/provider.

## Critical

## Major

## Minor

## Suggestions

## Verdict
PENDING
EOT
echo "Review artifact prepared: $out"
echo "Review diff with: git diff $base...HEAD"
