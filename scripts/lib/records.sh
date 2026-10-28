#!/usr/bin/env bash

# Run records: how long every step of a feature or a planning cycle took, and
# how many tokens its agents used. Source this file; it needs jq.
#
# The workflow scripts and the agent adapter record; agents estimate nothing.
# A run is one execution of a workflow command that the human started:
# `run-feature.sh 12`, `review-feature.sh 12`, `revise-planning.sh ...`. The
# commands that such a run starts itself belong to it, so nothing is counted
# twice. A resumed feature is a new run that names the run before it.
#
# Where the records are:
# - while the work runs: one file per run, appended to and never rewritten,
#   in .agents/run/records/ of the primary checkout. All worktrees of the
#   repository write there, so a record survives the removal of a worktree,
#   and two runs never write to the same file;
# - when a feature is published or cleaned up, and when a planning is
#   finished or cleaned up: the runs of the feature or the planning together,
#   in .agents/records/feature-<issue>.jsonl or planning-<name>.jsonl of the
#   primary checkout.
# Both directories are ignored by Git and nothing is sent to GitHub. They live
# on one machine: a new clone or `git clean -fdx` does not keep them.
#
# Every line is one JSON object with the fields "schema", "run", "time"
# (UTC), "epoch" (seconds), and "type":
#   run-start    kind ("feature" or "planning"), subject (the Issue number
#                or the name of the planning), command, previous (the run
#                before it of the same subject, or null), repository,
#                versions (template commit, prompts, agents.conf)
#   run-end      status (exit status; 130 for an interruption)
#   step         name, status, seconds: a step of run-feature.sh
#   wait         name, seconds: a pause before a step is tried again
#   verification status, seconds, reused, groups (always "all": a --only run
#                is not recorded), budgets: the budget checks of the run
#                (name, status "exceeded" or "within", exit, output), empty
#                without one
#   agent-call   role, profile, agent, model, status, seconds, usage, and
#                level and selection: the risk level of the feature that
#                selected the agent (null for a planning or an analysis)
#                and where the selection came from ("command-line",
#                "level-line", "plain-line"; lib/agent.sh)
#   intervention what: something the human did that a script observed
#   note         step, outcome, reason, action: a line of the log of
#                run-feature.sh, which is written from the same call
#   issue-comments issue, role, passed, authors, left_out, others,
#                workflow: the Issue comments a step passed on to its agent
#                and what it left out (lib/issue-comments.sh)
#   risk         when, level, reasons: the risk level of the feature
#                (lib/risk.sh) as run-feature.sh printed it
# A run without a run-end was interrupted and is incomplete.
#
# usage holds what the provider reported, with its own field names, and
# "source" says where it came from: "claude-result", "codex-events",
# "interactive" (a session in the human's terminal reports nothing), or
# "unavailable". A figure the provider did not report is null, never zero.
# "total_input" adds up what the provider counts as input: for Claude the
# input, cache creation, and cache read tokens, which it reports apart; for
# Codex the input tokens, which already include the cached ones.
#
# Nothing here may change the outcome of a step: a record that cannot be
# written is reported on standard error and the work goes on. No prompt, no
# secret, and no transcript is written.

RECORDS_SCHEMA="run-record/v1"

# records_primary: prints the path of the primary checkout of the repository
# that the current directory belongs to.
records_primary() {
  git worktree list --porcelain 2>/dev/null | awk '/^worktree / { print substr($0, 10); exit }'
}

# records_run_dir: prints the directory of the files of the runs.
records_run_dir() {
  local primary

  primary="$(records_primary)"
  [[ -n "$primary" ]] || return 1
  printf '%s/.agents/run/records' "$primary"
}

records_warn() {
  echo "Warning: the run record could not be written ($*); the work goes on." >&2
}

# records_append <json-object>: appends one line to the file of the current
# run. Does nothing outside a run.
records_append() {
  [[ -n "${RECORDS_FILE:-}" ]] || return 0
  if ! printf '%s\n' "$1" >>"$RECORDS_FILE" 2>/dev/null; then
    records_warn "$RECORDS_FILE is not writable"
  fi
  return 0
}

# records_emit <type> [jq-options...] <jq-object-expression>
# Writes one event of the current run: the common fields, followed by the
# fields that the expression builds from the --arg and --argjson options
# given before it.
# The jq definition that replaces what looks like a secret in text: a private
# key with its whole body, an API key, or a token. Every event passes it, so no
# reason, note, or record copies one.
RECORDS_REDACT_JQ='def redact:
  gsub("-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)"; "[redacted]")
  | gsub("(sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,})"; "[redacted]");
def redact_all: walk(if type == "string" then redact else . end);
'

records_emit() {
  local type="$1"
  local expression
  local line

  shift
  [[ -n "${RECORDS_RUN_ID:-}" && $# -ge 1 ]] || return 0
  expression="${*: -1}"
  set -- "${@:1:$#-1}"
  line="$(jq -cn --arg _schema "$RECORDS_SCHEMA" --arg _run "$RECORDS_RUN_ID" --arg _type "$type" \
    --arg _time "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" --argjson _epoch "$(date +%s)" "$@" \
    "$RECORDS_REDACT_JQ ({schema: \$_schema, run: \$_run, time: \$_time, epoch: \$_epoch, type: \$_type} + ($expression)) | redact_all" 2>/dev/null)" || {
    records_warn "the event '$type' could not be built"
    return 0
  }
  records_append "$line"
}

# records_versions: prints the versions that make runs comparable, as JSON.
records_versions() {
  local root
  local template=""
  local prompts=""
  local agents=""

  root="$(git rev-parse --show-toplevel 2>/dev/null)" || root="."
  if [[ -f "$root/.agents/template.conf" ]]; then
    template="$(sed -n 's/^commit:[[:space:]]*//p' "$root/.agents/template.conf" | head -n 1)"
  fi
  # In the template itself the workflow is its own commit.
  [[ -n "$template" ]] || template="$(git -C "$root" rev-parse HEAD 2>/dev/null || true)"
  if compgen -G "$root/.agents/prompts/*.md" >/dev/null; then
    prompts="$(cat "$root"/.agents/prompts/*.md | git hash-object --stdin 2>/dev/null || true)"
  fi
  if [[ -f "$root/.agents/agents.conf" ]]; then
    agents="$(git hash-object "$root/.agents/agents.conf" 2>/dev/null || true)"
  fi
  jq -cn --arg template "$template" --arg prompts "$prompts" --arg agents "$agents" \
    '{template: $template, prompts: $prompts, agents_conf: $agents} | with_entries(select(.value != ""))'
}

# records_repository: prints owner/name of the origin remote, or the name of
# the directory; never a URL, which can carry credentials.
records_repository() {
  local url

  url="$(git remote get-url origin 2>/dev/null)" || url=""
  url="${url%.git}"
  if [[ "$url" =~ [:/]([^/:]+/[^/:]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    basename "$(records_primary)"
  fi
}

# records_previous <kind> <subject>: prints "<sequence>\t<id>" of the latest
# run of the same subject, or nothing. Runs are ordered by the sequence number
# of their start; a run from before sequence numbers counts as 0 and is
# ordered by its start time.
records_previous() {
  local dir

  dir="$(records_run_dir)" || return 0
  compgen -G "$dir/*.jsonl" >/dev/null || return 0
  { cat "$dir"/*.jsonl 2>/dev/null |
    jq -r -s --arg kind "$1" --arg subject "$2" \
      '[.[] | select(.type == "run-start" and .kind == $kind and (.subject | tostring) == $subject)]
       | sort_by([(.seq // 0), .epoch]) | last // empty | "\(.seq // 0)\t\(.run)"' 2>/dev/null; } || true
}

# records_sequence <kind> <subject> <run>: gives the run the next number of
# its subject and prints "<number>\t<previous run>". A number is claimed by a
# symbolic link from the number to the run, which only one run can create:
# two runs that start at once get different numbers, and each finds the run
# just before it by its link, without a lock that a killed run could leave
# behind. The first number falls back to the latest run without one.
records_sequence() {
  local links
  local n=0
  local previous=""
  local entry

  links="$(records_run_dir)/.sequence/$1-$2"
  mkdir -p "$links" 2>/dev/null || return 1
  for entry in "$links"/*; do
    entry="${entry##*/}"
    if [[ "$entry" =~ ^[0-9]+$ ]] && [[ "$entry" -gt "$n" ]]; then
      n="$entry"
    fi
  done
  n=$((n + 1))
  until ln -s "$3" "$links/$n" 2>/dev/null; do
    [[ -L "$links/$n" ]] || return 1
    n=$((n + 1))
  done
  if [[ "$n" -gt 1 ]]; then
    previous="$(readlink "$links/$((n - 1))" 2>/dev/null)" || previous=""
  else
    previous="$(records_previous "$1" "$2" 2>/dev/null)" || previous=""
    previous="${previous#*$'\t'}"
  fi
  printf '%s\t%s' "$n" "$previous"
}

# records_begin <kind> <subject> <command>
# Starts a run and exports it to the commands this one starts. Does nothing
# when a run is already going on: the command belongs to that run.
records_begin() {
  local kind="$1"
  local subject="$2"
  local command="$3"
  local dir
  local previous

  [[ -z "${RECORDS_RUN_ID:-}" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  dir="$(records_run_dir)" || return 0
  # Records are never committed: without the ignore rule nothing is recorded,
  # since the file would become part of what is reviewed and committed.
  if ! git -C "$(records_primary)" check-ignore -q ".agents/run/records/run.jsonl" 2>/dev/null; then
    echo "Note: no run record is kept, because Git does not ignore .agents/run/. Take over the template's .gitignore with ./scripts/sync-template.sh." >&2
    return 0
  fi
  if ! mkdir -p "$dir" 2>/dev/null; then
    records_warn "$dir cannot be created"
    return 0
  fi
  # The scripts run with errexit: nothing here may end them. A run follows
  # the run with the number before its own; whole seconds and run ids do not
  # tell runs apart that start in the same second.
  local latest
  local seq=""
  # The file of the run is created here, and only by this run: subshells of
  # one process share its id and, in Bash 3.2, the state of $RANDOM, so an id
  # that another run took is replaced by the next.
  local attempt=0
  while true; do
    RECORDS_RUN_ID="$(date -u +'%Y%m%dT%H%M%SZ')-$$-$RANDOM"
    RECORDS_FILE="$dir/$RECORDS_RUN_ID.jsonl"
    if (set -o noclobber; : >"$RECORDS_FILE") 2>/dev/null; then
      break
    fi
    attempt=$((attempt + 1))
    if [[ "$attempt" -ge 50 ]]; then
      records_warn "no file of its own could be created for the run in $dir"
      unset RECORDS_RUN_ID RECORDS_FILE
      return 0
    fi
  done
  if latest="$(records_sequence "$kind" "$subject" "$RECORDS_RUN_ID" 2>/dev/null)"; then
    seq="${latest%%$'\t'*}"
    previous="${latest#*$'\t'}"
  else
    records_warn "the run of $kind $subject got no number; it names no previous run"
    previous=""
  fi
  # The command that started the run, so that a command can tell whether it
  # runs as its own run or within another.
  RECORDS_COMMAND="$command"
  RECORDS_KIND="$kind"
  RECORDS_SUBJECT="$subject"
  export RECORDS_RUN_ID RECORDS_FILE RECORDS_COMMAND RECORDS_KIND RECORDS_SUBJECT
  local repository
  local versions
  repository="$(records_repository 2>/dev/null)" || repository=""
  versions="$(records_versions 2>/dev/null)" || versions='{}'
  [[ -n "$versions" ]] || versions='{}'
  records_emit run-start --arg kind "$kind" --arg subject "$subject" --arg command "$command" \
    --arg previous "$previous" --arg seq "$seq" --arg repository "$repository" --argjson versions "$versions" \
    '{kind: $kind, subject: $subject, command: $command, seq: (if $seq == "" then null else ($seq | tonumber) end), previous: (if $previous == "" then null else $previous end),
      repository: $repository, versions: $versions}'
  records_resumption "$kind" "$subject" "$previous" 2>/dev/null || true
}

# records_previous_end <run>: prints "<status> <epoch>" of the end of a run,
# or nothing when it has none.
records_previous_end() {
  local dir

  dir="$(records_run_dir)" || return 0
  [[ -f "$dir/$1.jsonl" ]] || return 0
  jq -r 'select(.type == "run-end") | "\(.status) \(.epoch)"' "$dir/$1.jsonl" 2>/dev/null | tail -n 1 || true
}

# records_feature_worktree <issue>: prints the worktree of feature/<issue>-*.
records_feature_worktree() {
  git worktree list --porcelain 2>/dev/null |
    awk -v prefix="refs/heads/feature/$1-" '
      /^worktree / { path = substr($0, 10) }
      /^branch / { if (index($2, prefix) == 1) { print path; exit } }' || true
}

# records_resumption <kind> <subject> <previous-run>
# Records what a script can see between the previous run of the subject and
# this one, without claiming who did it: this run follows a run that stopped
# with a status other than 0, and, for a feature, whether its handoff note
# changed after that stop. A person, a scheduler or a retry can each start a
# run, and any write changes the note, so this is a resumed event, not an
# intervention. Nothing of the note is recorded.
records_resumption() {
  local previous_end
  local status
  local ended
  local note
  local changed
  local note_changed="null"

  [[ -n "$3" ]] || return 0
  previous_end="$(records_previous_end "$3")"
  [[ -n "$previous_end" ]] || return 0
  status="${previous_end%% *}"
  ended="${previous_end##* }"
  [[ "$status" != "0" ]] || return 0
  if [[ "$1" == "feature" ]]; then
    note="$(records_feature_worktree "$2")/.agents/handoffs/$2.md"
    note_changed="false"
    if [[ -f "$note" ]]; then
      if [[ "$(uname -s)" == "Darwin" ]]; then
        changed="$(stat -f '%m' "$note" 2>/dev/null || echo 0)"
      else
        changed="$(stat -c '%Y' "$note" 2>/dev/null || echo 0)"
      fi
      [[ "$changed" -le "$ended" ]] || note_changed="true"
    fi
  fi
  records_emit resumed --arg after "$3" --argjson status "$status" --argjson changed "$note_changed" \
    '{after: $after, previous_status: $status, handoff_changed: $changed}'
}

# records_end <status>: ends the current run. A copy of its subject in
# .agents/records/ that a step of the run made is brought up to date, so that
# it holds the end and the status of the run.
records_end() {
  local primary

  # The experience record of a feature run (lib/experience.sh), before its
  # end. A verification on its own has nothing to observe beyond its result.
  if [[ "${RECORDS_KIND:-}" == "feature" && "${RECORDS_COMMAND##*/}" != "verify.sh" ]] &&
    declare -F experience_record >/dev/null; then
    experience_record "${1:-0}" || records_warn "the experience record of the run could not be made"
  fi
  records_emit run-end --argjson status "${1:-0}" '{status: $status}'
  [[ -n "${RECORDS_KIND:-}" && -n "${RECORDS_SUBJECT:-}" ]] || return 0
  primary="$(records_primary)" || return 0
  if [[ -f "$primary/.agents/records/$RECORDS_KIND-$RECORDS_SUBJECT.jsonl" ]]; then
    records_consolidate "$RECORDS_KIND" "$RECORDS_SUBJECT" 2>/dev/null ||
      records_warn "the copy in .agents/records/ was not brought up to date"
  fi
  return 0
}

# records_wrap <kind> <subject> <script> <argument>...
# Runs the script as a run of its own when no run is going on, and exits with
# its status; returns at once inside a run, so that the caller goes on. The
# script runs as a child, so its own traps and exits stay as they are, and the
# end of the run is recorded also when it fails. An interruption ends the run
# with status 130; a run that is killed has no end and stays incomplete.
records_wrap() {
  local kind="$1"
  local subject="$2"
  local script="$3"
  local status=0

  shift 3
  [[ -z "${RECORDS_RUN_ID:-}" && -z "${RECORDS_DISABLED:-}" && -n "$subject" ]] || return 0
  records_begin "$kind" "$subject" "$(basename "$script")"
  if [[ -z "${RECORDS_RUN_ID:-}" ]]; then
    # The run could not be started; the work goes on without a record.
    RECORDS_DISABLED=1 "$script" "$@" || status=$?
    exit "$status"
  fi
  trap 'records_end 130; exit 130' INT TERM
  "$script" "$@" || status=$?
  trap - INT TERM
  records_end "$status"
  exit "$status"
}

# records_intervention <what>: records something the human did.
records_intervention() {
  records_emit intervention --arg what "$1" \
    '{what: $what}'
}

# records_usage <provider> <profile> <output-file>
# Prints the usage that a provider reported for one call, as JSON.
records_usage() {
  local provider="$1"
  local profile="$2"
  local output_file="$3"
  local envelope="$output_file.envelope"
  local events="$output_file.events"


  if [[ "$profile" == "write" ]]; then
    jq -cn '{source: "interactive"}'
    return 0
  fi
  case "$provider" in
    claude)
      if [[ -s "$envelope" ]] && jq -e '(.usage | type) == "object"' "$envelope" >/dev/null 2>&1; then
        jq -c '.usage as $u | {
            source: "claude-result",
            input_tokens: ($u.input_tokens // null),
            output_tokens: ($u.output_tokens // null),
            cache_creation_input_tokens: ($u.cache_creation_input_tokens // null),
            cache_read_input_tokens: ($u.cache_read_input_tokens // null)
          }
          | .total_input = (if .input_tokens == null or .cache_creation_input_tokens == null or .cache_read_input_tokens == null
              then null
              else .input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens end)' "$envelope"
        return 0
      fi
      ;;
    codex)
      if [[ -s "$events" ]]; then
        # One event per turn; the turns of a call add up.
        # One event per completed turn; a turn whose usage is absent, null, or
        # lacks a field counts as a turn that did not report it. A field that
        # a turn did not report is null for the call, so that an incomplete
        # sum never passes for a total; what the other turns reported is kept
        # apart, under "partial". Lines that are not JSON are left out: the
        # events are read line by line.
        jq -cRs '[split("\n")[] | select(length > 0) | (try fromjson catch null) | objects] as $events
          | ([$events[] | select(.type == "turn.completed")]
             | if length > 0 then map(.usage | if type == "object" then . else {} end)
               else [$events[] | .usage? | objects] end) as $turns
          | def field($name): [$turns[] | .[$name]] as $values
              | if ($values | all(type == "number")) then {total: ($values | add), partial: null}
                elif ($values | any(type == "number")) then {total: null, partial: ([$values[] | numbers] | add)}
                else {total: null, partial: null} end;
          if ($turns | length) == 0 then {source: "unavailable"} else
            (field("input_tokens")) as $input | (field("cached_input_tokens")) as $cached | (field("output_tokens")) as $output
            | {
                source: "codex-events",
                turns: ($turns | length),
                turns_without_usage: ([$turns[] | select(length == 0)] | length),
                input_tokens: $input.total,
                cached_input_tokens: $cached.total,
                output_tokens: $output.total,
                total_input: $input.total
              }
            + ({input_tokens: $input.partial, cached_input_tokens: $cached.partial, output_tokens: $output.partial}
                | with_entries(select(.value != null)) | if length == 0 then {} else {partial: .} end)
          end' "$events" 2>/dev/null && return 0
      fi
      ;;
  esac
  jq -cn '{source: "unavailable"}'
}

# records_agent_start <id> <role> <profile> <provider> <model> [<level>] [<selection>]
# An agent call begins. A start without its agent-call is a call that was
# interrupted. <level> is the risk level that selected the agent, empty when
# the role runs without one, and <selection> where the selection came from.
records_agent_start() {
  records_emit agent-start --arg id "$1" --arg role "$2" --arg profile "$3" --arg agent "$4" --arg model "$5" \
    --arg level "${6:-}" --arg selection "${7:-}" \
    '{id: $id, role: $role, profile: $profile, agent: $agent, model: $model,
      level: (if $level == "" then null else $level end), selection: (if $selection == "" then null else $selection end)}'
}

# records_agent_call <role> <profile> <provider> <model> <seconds> <status> <output-file> [<id>] [<level>] [<selection>]
records_agent_call() {
  local usage

  [[ -n "${RECORDS_RUN_ID:-}" ]] || return 0
  usage="$(records_usage "$3" "$2" "$7" 2>/dev/null)" || usage=""
  [[ -n "$usage" ]] || usage='{"source": "unavailable"}'
  records_emit agent-call --arg role "$1" --arg profile "$2" --arg agent "$3" --arg model "$4" \
    --argjson seconds "$5" --argjson status "$6" --argjson usage "$usage" --arg id "${8:-}" \
    --arg level "${9:-}" --arg selection "${10:-}" \
    '{role: $role, profile: $profile, agent: $agent, model: $model, status: $status, seconds: $seconds, usage: $usage,
      level: (if $level == "" then null else $level end), selection: (if $selection == "" then null else $selection end)}
     + (if $id == "" then {} else {id: $id} end)'
}

# records_feature_events <issue> [jq-options...] <jq-program>
# Runs <jq-program> over the array of the events of feature <issue>, with
# the --arg options given before it, and prints its raw output: the events
# of the runs whose start names the feature; the runs of another feature or
# of a planning never count. Every run counts once: it is read from its own
# file while that exists, and from the copy of the feature
# (.agents/records/feature-<issue>.jsonl) only when its file is gone, as
# report.jq does, so that a run that both hold after a consolidation is not
# counted twice. Nothing when there is no record or no jq.
records_feature_events() {
  local issue="$1"
  local program
  local dir
  local copy
  local files=()
  local file

  shift
  program="${*: -1}"
  set -- "${@:1:$#-1}"
  command -v jq >/dev/null 2>&1 || return 0
  dir="$(records_run_dir)" || return 0
  copy="$(records_primary)/.agents/records/feature-$issue.jsonl"
  for file in "$dir"/*.jsonl; do
    [[ -f "$file" ]] && files+=("$file")
  done
  [[ "${#files[@]}" -gt 0 || -f "$copy" ]] || return 0
  # Every event with its source before it: 0 for a run file, 1 for the copy.
  {
    [[ "${#files[@]}" -eq 0 ]] || cat "${files[@]}" 2>/dev/null | jq -c -R 'fromjson? | objects | [0, .]' 2>/dev/null
    [[ ! -f "$copy" ]] || jq -c -R 'fromjson? | objects | [1, .]' <"$copy" 2>/dev/null
  } | jq -rs --arg subject "$issue" "$@" '
      def starts($events): [$events[] | select(.type == "run-start" and .kind == "feature" and (.subject | tostring) == $subject) | .run] | unique;
      map(select(.[0] == 0) | .[1]) as $from_files
      | map(select(.[0] == 1) | .[1]) as $from_copy
      | starts($from_files) as $runs_in_files
      | [starts($from_copy)[] | select(. as $run | any($runs_in_files[]; . == $run) | not)] as $runs_in_copy_only
      | [$from_files[] | select(.run as $run | any($runs_in_files[]; . == $run))]
        + [$from_copy[] | select(.run as $run | any($runs_in_copy_only[]; . == $run))]
      | '"$program" 2>/dev/null || true
}

# records_highest_level <issue>
# Prints the highest risk level that the records of feature <issue> hold:
# the levels run-feature.sh noted ('risk' events) and the levels at which
# its agents were started (records_feature_events). Nothing when there is no
# record or no level. A script that starts a role raises the level it
# computed to this one, so a later session never runs at a weaker configured
# level than an earlier one did.
records_highest_level() {
  records_feature_events "$1" '
    [.[] | select((.type == "risk" or .type == "agent-start" or .type == "agent-call") and (.level | type) == "string")
         | .level | {low: 0, medium: 1, high: 2}[.] // empty]
    | if length == 0 then empty else (max | ["low", "medium", "high"][.]) end'
}

# records_role_providers <issue> <role>
# Prints the providers that <role> ran with for feature <issue>, one per
# line, each followed by a tab and the number of its calls: the agent calls
# of the runs of the feature (records_feature_events), and the starts of
# calls that were interrupted. A session started with --agent on the command
# line counts with the provider it ran with, not the configured one.
# Nothing when the role has no recorded call.
records_role_providers() {
  records_feature_events "$1" --arg role "$2" '
    [.[] | select(.type == "agent-call" and .role == $role and (.agent | type) == "string")] as $calls
    | [$calls[] | .id // empty] as $ids
    | $calls + [.[] | select(.type == "agent-start" and .role == $role and (.agent | type) == "string"
                            and (.id as $id | any($ids[]; . == $id) | not))]
    | group_by(.agent) | .[] | "\(.[0].agent)\t\(length)"'
}

# records_consolidate <kind> <subject>
# Writes the runs of a feature or a planning together to
# .agents/records/<kind>-<subject>.jsonl in the primary checkout, in the
# order in which they were written. The run files stay, so a later copy holds
# every run of an earlier one. Fails when the copy cannot be written.
records_consolidate() {
  local kind="$1"
  local subject="$2"
  local primary
  local dir
  local target
  local runs

  primary="$(records_primary)" || return 1
  [[ -n "$primary" ]] || return 1
  dir="$primary/.agents/run/records"
  target="$primary/.agents/records/$kind-$subject.jsonl"
  # Without the ignore rule the copy would be committed: it is not made, and
  # that is no failure.
  if ! git -C "$primary" check-ignore -q ".agents/records/$kind-$subject.jsonl" 2>/dev/null; then
    # Nothing to lose when the subject has no run; otherwise the copy is
    # needed and cannot be made safely, which is a failure. grep -q reads the
    # files itself: a pipe into a second grep -q would let the first one die of
    # SIGPIPE under pipefail and hide a match among many files.
    if ! compgen -G "$dir/*.jsonl" >/dev/null ||
      ! grep -qF "\"subject\":\"$subject\"" "$dir"/*.jsonl 2>/dev/null; then
      return 0
    fi
    echo "Error: the run records of $kind $subject cannot be copied to .agents/records/, because Git does not ignore that directory in $primary. Take over the template's .gitignore with ./scripts/sync-template.sh." >&2
    return 1
  fi
  mkdir -p "$primary/.agents/records" || return 1
  # One copy of a subject at a time: a directory is made atomically, and a
  # copy waits up to thirty seconds for another to finish. Each copy writes
  # a temporary file of its own and replaces the target in one step.
  local lock="$primary/.agents/records/.$kind-$subject.lock"
  local waited=0
  local tmp
  local status=0
  until mkdir "$lock" 2>/dev/null; do
    if [[ "$waited" -ge 300 ]]; then
      records_warn "another copy of $kind $subject holds $lock"
      return 1
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  tmp="$(mktemp "$primary/.agents/records/.$kind-$subject.XXXXXX")" || { rmdir "$lock"; return 1; }
  # Read inside the lock, so that a later copy never holds less than an
  # earlier one. A run file that cannot be read keeps the copy as it was: it
  # could belong to this subject, and a copy without it would lose a run.
  runs=""
  local file
  local found
  for file in "$dir"/*.jsonl; do
    [[ -e "$file" ]] || continue
    if ! found="$(jq -r --arg kind "$kind" --arg subject "$subject" \
      'select(.type == "run-start" and .kind == $kind and (.subject | tostring) == $subject) | .run' "$file" 2>/dev/null)"; then
      records_warn "$file cannot be read; the copy of $kind $subject was left as it was"
      rm -f "$tmp"
      rmdir "$lock" 2>/dev/null || true
      return 1
    fi
    [[ -z "$found" ]] || runs+="$found"$'\n'
  done
  runs="${runs%$'\n'}"
  # A run whose file is gone stays in the copy: the copy is all that is left
  # of it. A run that has its file is taken from the file, which is newer.
  # A copy that cannot be read is kept as it is.
  local known
  local kept=""
  known="$(printf '%s\n' "$runs" | jq -R 'select(length > 0)' | jq -cs '.')" || status=1
  if [[ "$status" -eq 0 && -f "$target" ]]; then
    if ! kept="$(jq -c --argjson known "$known" 'select(.run as $run | $known | index([$run]) | not)' "$target")"; then
      records_warn "$target cannot be read; it was left as it was"
      status=1
    fi
  fi
  if [[ "$status" -eq 0 ]]; then
    {
      if [[ -n "$runs" ]]; then
        while IFS= read -r run; do
          cat "$dir/$run.jsonl"
        done <<<"$runs"
      fi
      [[ -z "$kept" ]] || printf '%s\n' "$kept"
    } | jq -c -s 'to_entries | sort_by(.value.epoch, .value.run, .key) | .[].value' >"$tmp" || status=1
  fi
  if [[ "$status" -eq 0 ]]; then
    mv "$tmp" "$target" || status=1
  fi
  rm -f "$tmp"
  rmdir "$lock" 2>/dev/null || true
  return "$status"
}

# records_id: prints an identifier for a pair of start and end events.
records_id() {
  printf '%s-%s%s' "$(date +%s)" "$RANDOM" "$RANDOM"
}

# records_step_start <id> <name>: a step of run-feature.sh begins. A start
# without its end is a step that was interrupted.
records_step_start() {
  records_emit step-start --arg id "$1" --arg name "$2" '{id: $id, name: $name}'
}

# records_step <name> <status> <seconds> [<id>]: a step of run-feature.sh
# ended.
records_step() {
  records_emit step --arg name "$1" --argjson status "$2" --argjson seconds "$3" --arg id "${4:-}" \
    '{name: $name, status: $status, seconds: $seconds} + (if $id == "" then {} else {id: $id} end)'
}

# records_wait_start <id> <name> <planned-seconds>: a pause before a step is
# tried again begins; records_wait records how long it really took.
records_wait_start() {
  records_emit wait-start --arg id "$1" --arg name "$2" --argjson planned "$3" '{id: $id, name: $name, planned: $planned}'
}

# records_wait <name> <seconds> [<id>]: a pause ended after <seconds>.
records_wait() {
  records_emit wait --arg name "$1" --argjson seconds "$2" --arg id "${3:-}" \
    '{name: $name, seconds: $seconds} + (if $id == "" then {} else {id: $id} end)'
}

# records_note <step> <outcome> <reason> <action>: a line of the log of
# run-feature.sh.
# records_gate <worktree> <status> <reasons>: one check of the completion
# gate, with its outcome, its reasons, one per line, and the fingerprint of
# the content it judged (lib/fingerprint.sh), so that two checks on one commit
# stay apart. It names the implementing sessions of the run before it, as the
# run recorded them: every session of the implementer or the triage
# implementer, a repair or a retry too, and the last of them, the session it
# judges. A check without a session since the one before judges the same
# session again.
records_gate() {
  local content=""
  local scratch
  local sessions='{"count": 0, "last": null}'

  [[ -n "${RECORDS_FILE:-}" ]] || return 0
  if declare -F fingerprint_worktree >/dev/null && scratch="$(mktemp -d "${TMPDIR:-/tmp}/records-gate.XXXXXX" 2>/dev/null)"; then
    content="$(fingerprint_worktree "$1" "$scratch" 2>/dev/null)" || content=""
    rm -rf "$scratch"
  fi
  if [[ -f "$RECORDS_FILE" ]]; then
    sessions="$(jq -cs '[.[] | select(.type == "agent-start" and (.role == "implementer" or .role == "triage-implementer"))]
      | {count: length, last: (last | if . == null then null else .id end)}' "$RECORDS_FILE" 2>/dev/null)" ||
      sessions='{"count": null, "last": null}'
  fi
  RECORDS_GATE_CHECKS=$((${RECORDS_GATE_CHECKS:-0} + 1))
  records_emit completion-gate --argjson check "$RECORDS_GATE_CHECKS" --argjson sessions "$sessions" \
    --arg status "${2:-}" --arg reasons "${3:-}" --arg content "$content" \
    '{check: $check, sessions: $sessions.count, session: $sessions.last, status: $status,
      reasons: ($reasons | split("\n") | map(select(length > 0))),
      content: (if $content == "" then null else $content end)}'
}

# records_artifact <kind> <path>: a review or a triage that this run wrote,
# by its path in the worktree, so that its experience record names what the
# run produced and nothing of another run.
records_artifact() {
  records_emit artifact --arg kind "$1" --arg path "$2" '{kind: $kind, path: $path}'
}

# records_risk <when> <level> <reasons> [<profile>]: the risk level of the
# feature and its reasons, one per line, at a moment of the run, and the
# workflow profile of the risk policy ('light', 'standard', or 'none').
records_risk() {
  records_emit risk --arg when "$1" --arg level "$2" --arg reasons "$3" --arg profile "${4:-}" \
    '{when: $when, level: $level, reasons: ($reasons | split("\n") | map(select(length > 0)))}
     + (if $profile == "" then {} else {profile: $profile} end)'
}

records_note() {
  records_emit note --arg step "$1" --arg outcome "$2" --arg reason "$3" --arg action "$4" \
    '{step: $step, outcome: $outcome, reason: $reason, action: $action}'
}

# records_verification_start <id> <groups>: a verification begins. A start
# without its end is a verification that was interrupted.
records_verification_start() {
  records_emit verification-start --arg id "$1" --arg groups "$2" '{id: $id, groups: $groups}'
}

# records_verification <status> <seconds> <reused> <groups> [<id>] [<budgets>]
# <budgets> is a JSON array of the budget results of the run
# (lib/verification.sh, verification_budgets_json); an empty array without
# a budget check.
records_verification() {
  local budgets="${6:-[]}"

  jq -e 'type == "array"' <<<"$budgets" >/dev/null 2>&1 || budgets='[]'
  records_emit verification --argjson status "$1" --argjson seconds "$2" --argjson reused "$3" --arg groups "$4" --arg id "${5:-}" \
    --argjson budgets "$budgets" \
    '{status: $status, seconds: $seconds, reused: $reused, groups: $groups, budgets: $budgets} + (if $id == "" then {} else {id: $id} end)'
}

# records_branch_issue: prints the Issue number of the feature branch that is
# checked out, or nothing.
records_branch_issue() {
  git branch --show-current 2>/dev/null | sed -n 's#^feature/\([0-9][0-9]*\)-.*#\1#p'
}

# The experience records belong to the runs; a copy of this file without them
# records the runs only.
if [[ -f "${BASH_SOURCE[0]%/*}/experience.sh" ]]; then
  source "${BASH_SOURCE[0]%/*}/experience.sh"
fi
