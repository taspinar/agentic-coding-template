#!/usr/bin/env bash
set -euo pipefail
./scripts/verify.sh
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree has changes. Review them before committing."
  git status --short
  exit 2
fi
./scripts/review-feature.sh "${1:-main}"
echo "Stable commit verified. Complete independent review before push/PR."
