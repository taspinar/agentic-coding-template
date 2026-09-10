#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 1 ]]; then echo "Usage: $0 <worktree-path>"; exit 1; fi
git worktree remove "$1"
git worktree prune
echo "Removed worktree $1"
