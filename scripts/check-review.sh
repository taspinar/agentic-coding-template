#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/review-data.sh"
source "$script_dir/lib/fingerprint.sh"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <review-json>"
  echo
  echo "Reports whether the content a review covers is unchanged since the review."
  echo "Exits 0 when the review is current, 1 when it is stale, and 2 on an error."
  exit 2
fi

fail() {
  echo "Error: $*" >&2
  exit 2
}

root="$(git rev-parse --show-toplevel)"
[[ -f "$1" ]] || fail "review artifact not found: $1"
review_path="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
[[ "$review_path" == "$root/.agents/reviews/"*.json ]] ||
  fail "review artifact must match .agents/reviews/*.json. Received: $review_path"
review_relative="${review_path#"$root"/}"

review_data_require_jq
review_errors="$(review_artifact_errors "$review_path")"
if [[ -n "$review_errors" ]]; then
  echo "Error: invalid review artifact:" >&2
  printf '%s\n' "$review_errors" | sed 's/^/  - /' >&2
  exit 2
fi

tmp_work="$(mktemp -d "${TMPDIR:-/tmp}/check-review.XXXXXX")"
trap 'rm -rf "$tmp_work"' EXIT

status=0
review_is_current "$root" "$tmp_work" "$review_path" || status=$?
case "$status" in
  0)
    echo "Current: $review_relative still matches the reviewed content."
    ;;
  1)
    echo "Stale: the reviewed content changed after $review_relative was written."
    echo "Run a new review before triage, fixes, or approval."
    exit 1
    ;;
  *)
    fail "could not compute the current fingerprint."
    ;;
esac
