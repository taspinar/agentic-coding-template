#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/fingerprint.sh"
source "$script_dir/lib/guardrails.sh"
source "$script_dir/lib/risk.sh"
source "$script_dir/lib/completion.sh"

usage() {
  echo "Usage: $0 [<base-branch>]"
  echo
  echo "Prints the risk level of the feature in the current worktree, low, medium, or"
  echo "high, and every reason for it: the classes of .agents/policies/risk.conf on"
  echo "the paths the feature changed, the fixed escalations, and what the agents"
  echo "recorded (risk in the completion record, the reviewer's classification of"
  echo "the impact on the architecture), and the owner's hints: the label 'risk: high'"
  echo "or 'risk: medium' of the Issue, which start-feature.sh kept for the branch,"
  echo "and --risk of the run (WORKFLOW_RISK_HINT). The rules are read from the base"
  echo "branch as it is now (default: main), the diff from where the feature left it,"
  echo "with uncommitted and untracked files. An agent or a hint can raise the level,"
  echo "never lower it; a base that cannot be determined gives high."
  echo
  echo "After the reasons, one line 'hint: <level> <source>' names each hint, with the"
  echo "source issue-label or command-line."
  echo
  echo "Then it prints the workflow profile of the policy of the base,"
  echo "'profile: light', 'profile: standard', or 'profile: none' without the key"
  echo "(a profile supplies the lines the policy does not write, and never applies"
  echo "to a high-risk feature), then what the level requires of the workflow by the"
  echo "same policy: 'verification: full' or 'verification: groups <group>...' for"
  echo "the intermediate review rounds, 'review: full', 'review: delta', or"
  echo "'review: none' for the later rounds, and 'triage: full' or 'triage: light'"
  echo "for the triage of their findings; a value of the policy that is not"
  echo "accepted is printed as 'refused: ...' and the strictest requirement applies."
  echo
  echo "Exits 0 for low, 1 for medium, 2 for high, and 3 on a usage error."
  exit 3
}

[[ $# -le 1 ]] || usage
[[ "${1:-}" != --* ]] || usage
base="${1:-main}"

root="$(git rev-parse --show-toplevel)" || usage
command -v jq >/dev/null 2>&1 || { echo "Error: jq is required." >&2; exit 3; }
branch="$(git -C "$root" branch --show-current)"

# The record and the latest review of the feature, when the branch is one.
record=""
review=""
if [[ "$branch" =~ ^feature/([0-9]+)- ]]; then
  record="$(completion_record "$root" "${BASH_REMATCH[1]}")"
  slug="${branch//\//-}"
  shopt -s nullglob
  reviews=("$root/.agents/reviews/${slug}-review-"[0-9][0-9].json)
  shopt -u nullglob
  [[ "${#reviews[@]}" -eq 0 ]] || review="${reviews[${#reviews[@]}-1]}"
fi

rules="$(guardrails_rules_refs "$root" "$base")"
if lines="$(feature_base "$root" "$base")"; then
  from="$(printf '%s\n' "$lines" | sed -n 2p)"
  computed="$(risk_computed "$root" "$rules" "$from" "")"
else
  computed="$(risk_undetermined "the base of this worktree could not be determined ($base)")"
fi
hints="$(risk_hints "$root" "$branch")"
decision="$(risk_decision "$computed" "$record" "$review" "$hints")"
level="$(printf '%s\n' "$decision" | sed -n 1p)"

profile_lines="$(risk_profile_note "$root" "$rules" "$level")"

echo "risk: $level"
printf '%s\n' "$decision" | sed '1d; s/^/- /'
printf '%s\n' "$hints" | grep . | sed 's/^/hint: /' || true
echo "profile: $(printf '%s\n' "$profile_lines" | sed -n 1p)"
risk_requirements "$root" "$rules" "$level"
printf '%s\n' "$profile_lines" | sed 1d | grep . | sed 's/^/refused: /' || true
case "$level" in
  low) exit 0 ;;
  medium) exit 1 ;;
  *) exit 2 ;;
esac
