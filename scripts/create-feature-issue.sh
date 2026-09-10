#!/usr/bin/env bash

set -euo pipefail

TITLE="${1:-}"
BODY_FILE="${2:-}"
LABEL="${3:-}"

usage() {
  echo "Usage:"
  echo "  $0 \"Issue title\" path/to/body.md [label]"
  exit 1
}

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: GitHub CLI 'gh' is not installed."
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "Error: GitHub CLI is not authenticated."
  echo "Run: gh auth login"
  exit 1
fi

if [[ -z "$TITLE" || -z "$BODY_FILE" ]]; then
  usage
fi

if [[ ! -f "$BODY_FILE" ]]; then
  echo "Error: body file not found: $BODY_FILE"
  exit 1
fi

ARGS=(
  issue create
  --title "$TITLE"
  --body-file "$BODY_FILE"
)

if [[ -n "$LABEL" ]]; then
  if gh label list --limit 100 --json name --jq '.[].name' | grep -Fxq "$LABEL"; then
    ARGS+=(--label "$LABEL")
  else
    echo "Warning: label '$LABEL' does not exist."
    echo "Creating issue without label."
  fi
fi

echo "Creating GitHub issue:"
echo "  Title: $TITLE"
echo "  Body:  $BODY_FILE"

ISSUE_URL="$(gh "${ARGS[@]}")"

echo
echo "Issue created:"
echo "$ISSUE_URL"
