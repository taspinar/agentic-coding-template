#!/usr/bin/env bash

set -euo pipefail

ISSUE="${1:-}"
PLAN="${2:-}"

if [[ -z "$ISSUE" || -z "$PLAN" ]]; then
  echo "Usage: $0 <issue-number> <plan-path>"
  exit 1
fi

if [[ ! -f "$PLAN" ]]; then
  echo "Plan not found: $PLAN"
  exit 1
fi

BODY="$(gh issue view "$ISSUE" --json body --jq '.body')"

# Remove or replace an existing implementation-plan block here.

UPDATED_BODY="$BODY

## Implementation plan

Detailed technical plan:

\`$PLAN\`

Status: Ready for implementation"

TMP_FILE="$(mktemp)"
printf '%s\n' "$UPDATED_BODY" > "$TMP_FILE"

gh issue edit "$ISSUE" --body-file "$TMP_FILE"

rm "$TMP_FILE"
