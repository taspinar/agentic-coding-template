#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 [<issue> | planning:<name>]... [--all] [--since <date>] [--until <date>]"
  echo "          [--split <date>] [--json]"
  echo "       $0 --github-summary <issue>"
  echo
  echo "Reports on the run records of features and planning cycles: the elapsed"
  echo "time, the time per step and per agent, the tokens per role, model, and run,"
  echo "the review and repair rounds, the outcome of the runs, and the recorded"
  echo "interventions. Without a subject, in a feature worktree, it reports on that"
  echo "feature. Reads the records of the primary checkout (docs/development.md,"
  echo "'Run records'); needs no network."
  echo
  echo "  --all             every subject that has a record"
  echo "  --since, --until  only runs that started on or after, or before, a date"
  echo "                    (YYYY-MM-DD, UTC)"
  echo "  --split <date>    compares the features that started before the date with"
  echo "                    those that started on or after it"
  echo "  --json            the report as JSON instead of Markdown"
  echo "  --github-summary  the totals of one feature for its GitHub Issue, as"
  echo "                    publish-feature.sh --summary posts them"
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/records.sh"
command -v jq >/dev/null 2>&1 || fail "jq is required."

# date_epoch <option> <date>: midnight UTC of the date, as epoch seconds.
date_epoch() {
  [[ "$2" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || fail "$1 needs a date as YYYY-MM-DD: $2"
  # Not jq's fromdateiso8601, which some versions shift by the local time
  # zone.
  if [[ "$(uname -s)" == "Darwin" ]]; then
    TZ=UTC date -j -f '%Y-%m-%d %H:%M:%S' "$2 00:00:00" +%s 2>/dev/null || fail "$1 needs a valid date: $2"
  else
    TZ=UTC date -d "$2 00:00:00" +%s 2>/dev/null || fail "$1 needs a valid date: $2"
  fi
}

subjects=()
all=0
since="null"
until="null"
split="null"
mode="markdown"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) all=1 ;;
    --json) mode="json" ;;
    --since) [[ $# -ge 2 ]] || usage; since="$(date_epoch --since "$2")"; shift ;;
    --until) [[ $# -ge 2 ]] || usage; until="$(date_epoch --until "$2")"; shift ;;
    --split) [[ $# -ge 2 ]] || usage; split="$(date_epoch --split "$2")"; shift ;;
    --github-summary)
      [[ $# -eq 2 && "$2" =~ ^[0-9]+$ ]] || usage
      mode="summary"
      subjects=("feature:$2")
      shift
      ;;
    -h | --help) usage ;;
    planning:?*) subjects+=("$1") ;;
    [0-9]*)
      [[ "$1" =~ ^[0-9]+$ ]] || fail "an Issue number is numeric: $1"
      subjects+=("feature:$1")
      ;;
    *) usage ;;
  esac
  shift
done

primary="$(records_primary)" || fail "not inside a Git repository."
run_dir="$primary/.agents/run/records"
copy_dir="$primary/.agents/records"

# The events of every record, one array per source. A line that is not JSON
# is left out: one damaged line does not hide a report.
work="$(mktemp -d "${TMPDIR:-/tmp}/report-runs.XXXXXX")"
trap 'rm -rf "$work"' EXIT
events() {
  if compgen -G "$1/*.jsonl" >/dev/null; then
    cat "$1"/*.jsonl | jq -cR 'fromjson? | objects' | jq -cs '.'
  else
    echo '[]'
  fi
}
events "$run_dir" >"$work/active.json"
events "$copy_dir" >"$work/copies.json"

if [[ "$all" -eq 1 ]]; then
  while IFS= read -r subject; do
    [[ -n "$subject" ]] && subjects+=("$subject")
  done < <(jq -rs '[.[][] | select(.type == "run-start") | "\(.kind):\(.subject)"] | unique | .[]' \
    "$work/active.json" "$work/copies.json")
fi
if [[ ${#subjects[@]} -eq 0 ]]; then
  issue="$(records_branch_issue)"
  [[ -n "$issue" ]] || usage
  subjects=("feature:$issue")
fi

# The agent and model pairs that .agents/agents.conf of the primary checkout
# declares or declared, on the plain and the level lines of every role: every
# version of the file in the Git history, and the current file (the working
# tree may differ from HEAD). Collected once per report. 'history' is false
# when no version could be read from Git (no commit of the file yet), so that
# the warning says that only the current file was compared; null without any
# version, so that every call counts.
agents_conf_pairs() {
  sed -nE 's/^[a-z][a-z-]*(@[a-z]+)?:[[:space:]]*([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]*$/\2 \3/p'
}
versions="$(git -C "$primary" log --format=%H -- .agents/agents.conf 2>/dev/null || true)"
pairs=""
while IFS= read -r commit; do
  [[ -n "$commit" ]] || continue
  pairs+="$({ git -C "$primary" show "$commit:.agents/agents.conf" 2>/dev/null || true; } | agents_conf_pairs)"$'\n'
done <<<"$versions"
declared="null"
if [[ -n "$versions" || -f "$primary/.agents/agents.conf" ]]; then
  declared="$({ printf '%s' "$pairs"; if [[ -f "$primary/.agents/agents.conf" ]]; then agents_conf_pairs <"$primary/.agents/agents.conf"; fi; } |
    jq -R . | jq -cs --argjson history "$([[ -n "$versions" ]] && echo true || echo false)" \
      '{pairs: (map(select(. != "") | {key: ., value: true}) | from_entries), history: $history}')"
fi

selection="$(printf '%s\n' "${subjects[@]}" | jq -R '{kind: (split(":")[0]), subject: (split(":")[1:] | join(":"))}' | jq -cs 'unique')"

result="$(jq -n -r \
  --slurpfile active "$work/active.json" --slurpfile copies "$work/copies.json" \
  --argjson selection "$selection" --argjson since "$since" --argjson until "$until" \
  --argjson split "$split" --argjson declared "$declared" --arg mode "$mode" --argjson period "$([[ "$since$until" == nullnull ]] && echo false || echo true)" \
  '$active[0] as $active | $copies[0] as $copies | '"$(cat "$script_dir/lib/report.jq")")"

if [[ "$mode" == "summary" && "$result" == "null" ]]; then
  echo "Error: Issue #${subjects[0]#feature:} has no run record." >&2
  exit 1
fi
printf '%s\n' "$result"
