#!/usr/bin/env bash

set -euo pipefail

NAME="${1:-project-bootstrap}"
BRANCH="planning/$NAME"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is not clean. Commit or stash changes first."
  exit 1
fi

git switch main
git pull --ff-only
git switch -c "$BRANCH"

echo "Planning branch ready: $BRANCH"
