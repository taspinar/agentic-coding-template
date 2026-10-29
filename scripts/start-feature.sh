#!/usr/bin/env bash

set -euo pipefail

# The arguments as given, for a run that records itself (lib/records.sh).
records_arguments=("$@")

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/agent.sh"
source "$script_dir/lib/completion.sh"
source "$script_dir/lib/fingerprint.sh"
source "$script_dir/lib/issue-comments.sh"
source "$script_dir/lib/risk.sh"

usage() {
  echo "Usage: $0 <issue-number> [slug] [base-branch] [--agent <agent>] [--model <model>] [--risk <level>] [--unattended]"
  echo "       $0 <issue-number> --resume [--agent <agent>] [--model <model>] [--risk <level>] [--unattended]"
  echo
  echo "The slug names the branch (feature/<issue>-<slug>) and the worktree. Without"
  echo "one, it is derived from the Issue title. The agent and model come from role"
  echo "'implementer' in .agents/agents.conf unless --agent and --model are given."
  echo
  echo "--resume continues interrupted work: it starts a new implementer session in"
  echo "the existing worktree of the Issue, which reads the handoff note and the"
  echo "state of the worktree instead of an earlier conversation."
  echo
  echo "The level of the risk policy that selects the agent is at least what the"
  echo "owner says: the label 'risk: high' or 'risk: medium' of the Issue, which is"
  echo "kept for the whole feature, and --risk low|medium|high for this run. A feature"
  echo "without changes is at the default of the policy until then. A hint raises the"
  echo "level, never lowers it; one below the computed level is ignored and reported."
  echo
  echo "--unattended runs the implementer without a terminal: it asks nothing and ends"
  echo "by itself, and its final message is stored and shown. The script exits 3 when"
  echo "the agent reports that it cannot continue without you."
  echo
  echo "Examples:"
  echo "  $0 3"
  echo "  $0 3 site-skeleton"
  echo "  $0 3 site-skeleton develop"
  echo "  $0 4 multiplayer --agent claude --model fable"
  echo "  $0 4 --resume"
  exit 1
}

resume=0
arguments=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --resume) resume=1 ;;
    --risk)
      # The owner's hint for this run, which lib/risk.sh reads, also in the
      # scripts that this run starts.
      [[ $# -ge 2 ]] && risk_is_level "$2" || agent_fail "--risk requires a level: low, medium, or high."
      export WORKFLOW_RISK_HINT="$2"
      shift
      ;;
    *) arguments+=("$1") ;;
  esac
  shift
done

agent_parse_args ${arguments[@]+"${arguments[@]}"}
[[ "${#AGENT_POSITIONAL[@]}" -ge 1 && "${#AGENT_POSITIONAL[@]}" -le 3 ]] || usage
[[ "$resume" -eq 0 || "${#AGENT_POSITIONAL[@]}" -eq 1 ]] || usage

issue="${AGENT_POSITIONAL[0]}"
records_wrap feature "$issue" "$0" ${records_arguments[@]+"${records_arguments[@]}"}
# A session that the human resumes by hand is an intervention; run-feature.sh
# resumes within its own run, where this command is not the run's own.
if [[ "$resume" -eq 1 && "${RECORDS_COMMAND:-}" == "start-feature.sh" ]]; then
  records_intervention "resumed the implementation by hand"
fi
slug="${AGENT_POSITIONAL[1]:-}"
base="${AGENT_POSITIONAL[2]:-main}"

[[ "$issue" =~ ^[0-9]+$ ]] || agent_fail "issue number must be numeric: $issue"

# read_comments: the owner's later comments on the Issue, which the reviewer
# and the triage agent get too, appended to the prompt as
# COMMENTS_PROMPT. The session does not start without them.
read_comments() {
  command -v gh >/dev/null 2>&1 ||
    agent_fail "GitHub CLI 'gh' is needed to read the comments of Issue #$issue."
  issue_comments "$issue" implementer ||
    agent_fail "could not read the comments of Issue #$issue ($ISSUE_COMMENTS_ERROR). The implementer was not started, since it would work without the owner's clarifications."
  COMMENTS_PROMPT=""
  if [[ -n "$ISSUE_COMMENTS_SECTION" ]]; then
    COMMENTS_PROMPT="

$ISSUE_COMMENTS_SECTION"
  fi
}

# run_session <worktree> <prompt>: runs the implementer and reports the result.
run_session() {
  local session_worktree="$1"
  local agent_status=0

  local final_message="$session_worktree/.agents/run/$issue-implementer.md"
  local blocked=""

  echo "Starting $agent ($model)..."
  echo
  if [[ "$AGENT_UNATTENDED" -eq 1 ]]; then
    if ! git -C "$session_worktree" check-ignore -q ".agents/run/$issue-implementer.md" 2>/dev/null; then
      echo "Error: Git does not ignore .agents/run/ in $session_worktree, so the final message of an unattended session would become part of the feature." >&2
      echo "Add '.agents/run/' to .gitignore there, or take over the template's .gitignore with ./scripts/sync-template.sh." >&2
      echo "The feature worktree is preserved. Then continue with: $0 $issue --resume --unattended" >&2
      records_stop "${0##*/}" "Git does not ignore .agents/run/ in $session_worktree, so the final message of an unattended session would become part of the feature."
      exit 1
    fi
    mkdir -p "$(dirname "$final_message")"
    rm -f "$final_message"
    agent_run unattended "$agent" "$model" "$session_worktree" "$2

$AGENT_UNATTENDED_PROMPT" "$final_message" || agent_status=$?
    if [[ -s "$final_message" ]]; then
      echo "Final message of the implementer:"
      echo
      sed 's/^/  /' "$final_message"
    fi
    blocked="$(agent_blocked_reason "$final_message")"
  else
    agent_run write "$agent" "$model" "$session_worktree" "$2" || agent_status=$?
  fi

  echo
  if [[ "$agent_status" -eq 0 && -n "$blocked" ]]; then
    echo "The implementer stopped because it needs you: $blocked" >&2
    echo "The feature worktree is preserved at: $session_worktree" >&2
    echo "Answer in the handoff note or change the Issue, then continue with: $0 $issue --resume" >&2
    records_stop "${0##*/}" "The implementer stopped because it needs you: $blocked"
    exit 3
  fi
  if [[ "$agent_status" -ne 0 ]]; then
    echo "Error: the implementation agent exited with status $agent_status." >&2
    echo "The feature worktree is preserved at: $session_worktree" >&2
    echo "Continue the work with: $0 $issue --resume" >&2
    records_stop "${0##*/}" "the implementation agent exited with status $agent_status."
    # The statuses 3, 4, and 5 have a meaning of their own in the workflow:
    # a blocked session, a failed verification, and a changed review or
    # triage. An agent that happens to exit with one of them just failed.
    [[ "$agent_status" -lt 3 || "$agent_status" -gt 5 ]] || agent_status=1
    exit "$agent_status"
  fi
  echo "The implementation session ended. Nothing is committed yet."
  echo
  # A session that ended is not a feature that is complete: the completion
  # gate says where the work stands, from the implementer's own record and
  # its handoff note.
  session_gate="$(completion_gate "$session_worktree" "$issue" 2>/dev/null || true)"
  # Within run-feature.sh the run checks the gate itself, once per check.
  local records_command="${RECORDS_COMMAND:-}"
  if [[ "${records_command##*/}" == "start-feature.sh" ]]; then
    records_gate "$session_worktree" "$(printf '%s\n' "$session_gate" | sed -n 1p)" "$(printf '%s\n' "$session_gate" | sed 1d)" 2>/dev/null || true
  fi
  if completion_ready "$(printf '%s\n' "$session_gate" | sed -n 1p)"; then
    echo "The implementer reports the Issue as $(printf '%s\n' "$session_gate" | sed -n 1p | tr '_' ' ') ($COMPLETION_DIR/$issue.json)."
    printf '%s\n' "$session_gate" | sed '1d; s/^/  - /'
    echo
    echo "Next, in the feature worktree:"
    echo "  cd \"$session_worktree\""
    echo "  ./scripts/review-feature.sh $issue    # verifies first, unless the session verified this content"
  else
    echo "The Issue is not complete ($(printf '%s\n' "$session_gate" | sed -n 1p)):"
    printf '%s\n' "$session_gate" | sed '1d; s/^/  - /'
    echo
    echo "Continue the work with: $0 $issue --resume"
    echo "finish-feature.sh commits only a feature whose completion gate passes."
  fi
}

if [[ "$resume" -eq 1 ]]; then
  repo_root="$(git rev-parse --show-toplevel)"
  # The worktree whose branch belongs to the Issue; the primary checkout
  # counts when the feature was developed there.
  found="$(git -C "$repo_root" worktree list --porcelain |
    awk -v prefix="refs/heads/feature/${issue}-" '
      /^worktree / { path = substr($0, 10) }
      /^branch / { if (index($2, prefix) == 1) print path }')"
  [[ -n "$found" ]] ||
    agent_fail "no worktree is on a branch feature/${issue}-*; there is nothing to resume. Start the feature with: $0 $issue"
  [[ "$(printf '%s\n' "$found" | grep -c .)" -eq 1 ]] ||
    agent_fail "more than one worktree is on a branch feature/${issue}-*: $(printf '%s' "$found" | tr '\n' ' ')"
  worktree="$found"
  branch="$(git -C "$worktree" branch --show-current)"
  # The base the feature was created from; 'main' for a feature that was
  # created before the base was recorded.
  resume_base="$(git -C "$worktree" config --get "branch.$branch.workflow-base" || true)"
  resume_base="${resume_base:-main}"

  # The agent of the implementer by the risk level of the feature as it is
  # now, never below the level an earlier session ran at (lib/agent.sh).
  agent_computed="$(agent_computed_level "$worktree" "$resume_base")"
  agent_selected="$(agent_feature_level "$issue" "${agent_computed%%$'\t'*}" "${agent_computed#*$'\t'}")"
  agent_level="${agent_selected%%$'\t'*}"
  agent_level_why="${agent_selected#*$'\t'}"
  agent_resolve "$repo_root" implementer "$AGENT_CLI_PROVIDER" "$AGENT_CLI_MODEL" "$agent_level"
  agent="$AGENT_PROVIDER"
  model="$AGENT_MODEL"

  echo "Resuming feature:"
  echo "  Issue:    #$issue"
  echo "  Branch:   $branch"
  echo "  Base:     $resume_base"
  echo "  Worktree: $worktree"
  echo "  Agent:    $agent"
  echo "  Model:    $model"
  echo "  Level:    $agent_level ($agent_level_why)"
  echo "  Selected: by $(agent_selection_text)"

  # The note the earlier session kept. Files that changed after it was last
  # written are named, because the note does not describe them.
  note_relative=".agents/handoffs/$issue.md"
  note="$worktree/$note_relative"
  if [[ -f "$note" ]] && grep -q '[^[:space:]]' "$note"; then
    newer=""
    # NUL-separated records, so any file name is read as it is. A rename or
    # copy is followed by a record with the original path, which is skipped.
    # A deleted file has no time to compare, so it is named as well.
    skip_origin=0
    while IFS= read -r -d '' record; do
      if [[ "$skip_origin" -eq 1 ]]; then
        skip_origin=0
        continue
      fi
      state="${record:0:2}"
      path="${record:3}"
      [[ "$state" != *R* && "$state" != *C* ]] || skip_origin=1
      if [[ ! -e "$worktree/$path" && ! -L "$worktree/$path" ]]; then
        newer+="- $path (deleted)"$'\n'
      elif [[ "$worktree/$path" -nt "$note" ]]; then
        newer+="- $path"$'\n'
      fi
    done < <(git -C "$worktree" status --porcelain -z --untracked-files=all)
    echo "  Handoff:  $note_relative${newer:+ (older than some changed files)}"
    note_prompt="The earlier session kept a handoff note: $note_relative. Read it first."
    if [[ -n "$newer" ]]; then
      note_prompt+="
The note is STALE in part: these files changed after it was last written, so
it does not describe them. Trust the files, not the note, where they differ:
${newer%$'\n'}"
    fi
  else
    echo "  Handoff:  none"
    note_prompt="The earlier session left no handoff note in $note_relative, so the state of the
work has to be read from the repository."
  fi
  read_comments
  echo

  RESUME_PROMPT="Read and follow .agents/prompts/implementer.md.

You are resuming interrupted work on GitHub Issue #${issue} in this worktree.
An earlier session ended before the work was complete. You do not have its
conversation.

${note_prompt}

Before you change anything, establish where the work stands:
- Read GitHub Issue #${issue} using the GitHub CLI, and the matching
  .agents/plans/${issue}-*.md if one exists.
- Inspect 'git status' and the diff against the base of this branch
  (git merge-base HEAD origin/${resume_base}), including untracked files.
- If .agents/reviews/ or .agents/triage/ holds a review or an approved triage
  of this branch, the interrupted session may have been resolving its FIX_NOW
  findings; read the latest one.
- Check what a handoff note claims against the files before relying on it.

Then tell the human in a few lines what is done and what remains, and
continue. Do not redo work that is complete; verify it instead. Before you
end, bring the completion record, the handoff note, and the summary up to
date with where the work stands then (implementer contract, 'Completion').

Work only on this issue.

Do not commit, push, merge, or deploy.${COMMENTS_PROMPT}"

  run_session "$worktree" "$RESUME_PROMPT"
  exit 0
fi

# The title of the Issue, from which the slug is derived when none is given,
# and its labels, of which 'risk: high' and 'risk: medium' raise the level of
# the feature (lib/risk.sh).
slug_advice=""
[[ -n "$slug" ]] || slug_advice=" Pass a slug instead."
command -v gh >/dev/null 2>&1 || agent_fail "GitHub CLI 'gh' is needed to read the title and the labels of Issue #$issue."
# Only a connection or a service that fails for a moment is tried again:
# a timeout, a reset or refused connection, a host that cannot be resolved,
# or a server error. Anything else, such as an Issue that does not exist or
# a refusal, stops at once with its reason. A failure that stays temporary
# ends with status 75, which run-feature.sh tries again too.
gh_wait="${START_FEATURE_GH_WAIT:-5}"
gh_attempt=1
gh_errors="$(mktemp "${TMPDIR:-/tmp}/start-feature-gh.XXXXXX")" || agent_fail "could not create a temporary file."
trap 'rm -f "$gh_errors"' EXIT
while ! issue_view="$(gh issue view "$issue" --json title,labels --jq '.title, (.labels // [] | .[].name)' </dev/null 2>"$gh_errors")"; do
  gh_error="$(tail -n 3 "$gh_errors" 2>/dev/null || true)"
  if ! printf '%s\n' "$gh_error" |
    grep -Eiq 'timeout|timed out|connection (reset|refused)|could not resolve host|no such host|network is unreachable|temporary failure|EOF|HTTP 5[0-9][0-9]|50[234] |service unavailable|bad gateway'; then
    agent_fail "could not read the title of Issue #$issue: ${gh_error:-gh failed without a message}.$slug_advice"
  fi
  if [[ "$gh_attempt" -ge 3 ]]; then
    echo "Error: could not read the title of Issue #$issue after $gh_attempt attempts: $gh_error. Try again later${slug_advice:+, or pass a slug}." >&2
    records_stop "${0##*/}" "could not read the title of Issue #$issue after $gh_attempt attempts: $gh_error. Try again later${slug_advice:+, or pass a slug}."
    exit 75
  fi
  echo "Reading Issue #$issue failed ($gh_error); trying again in $gh_wait seconds." >&2
  sleep "$gh_wait"
  gh_wait=$((gh_wait * 2))
  gh_attempt=$((gh_attempt + 1))
done
rm -f "$gh_errors"
trap - EXIT
issue_title="$(printf '%s\n' "$issue_view" | sed -n 1p)"
issue_labels=()
while IFS= read -r label; do
  [[ -z "$label" ]] || issue_labels+=("$label")
done < <(printf '%s\n' "$issue_view" | sed 1d)
label_level="$(risk_label_level ${issue_labels[@]+"${issue_labels[@]}"})"

if [[ -z "$slug" ]]; then
  # Derive the slug from the Issue title: without a leading feature ID, in
  # lowercase, as at most four words joined by hyphens.
  slug="$(printf '%s' "$issue_title" |
    sed -E 's/^[[:space:]]*F[0-9]+[^[:alnum:]]*//' |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9]+/ /g' |
    awk '{ n = (NF < 4 ? NF : 4); for (i = 1; i <= n; i++) printf "%s%s", (i > 1 ? "-" : ""), $i }')"
  [[ -n "$slug" ]] || agent_fail "could not derive a slug from the title of Issue #$issue; pass a slug instead."
fi
[[ "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]] || agent_fail "slug must match [a-z0-9][a-z0-9-]*: $slug"

branch="feature/${issue}-${slug}"

repo_root="$(git rev-parse --show-toplevel)"
repo_name="$(basename "$repo_root")"
worktree="$(dirname "$repo_root")/${repo_name}-${issue}-${slug}"

# The agent of the implementer by the risk level of the feature. A feature
# that is started has no changes yet, so its level is the default of the
# risk policy of the base, as check-risk.sh would compute it; a session that
# resumes the work computes the level from the changes in the worktree. The
# level never falls below one that an earlier session of the Issue ran at.
# The owner's hints raise it from the start: the risk label of the Issue and
# --risk (lib/risk.sh), as check-risk.sh counts them once the feature exists.
risk_hint_lines="${label_level:+$label_level issue-label}"
if [[ -n "${WORKFLOW_RISK_HINT:-}" ]]; then
  risk_hint_lines+="${risk_hint_lines:+$'\n'}$WORKFLOW_RISK_HINT command-line"
fi
agent_decision="$(risk_decision "$(risk_default "$repo_root" "$(guardrails_rules_refs "$repo_root" "$base")")"$'\n'"the default of the risk policy of $base; the feature has no changes yet" "" "" "$risk_hint_lines")"
agent_computed="$(printf '%s\n' "$agent_decision" | sed -n 1p)"
agent_selected="$(agent_feature_level "$issue" "$agent_computed" "$(printf '%s\n' "$agent_decision" | sed 1d | awk 'NR > 1 { printf "; " } { printf "%s", $0 }')")"
agent_level="${agent_selected%%$'\t'*}"
agent_level_why="${agent_selected#*$'\t'}"
agent_resolve "$repo_root" implementer "$AGENT_CLI_PROVIDER" "$AGENT_CLI_MODEL" "$agent_level"
agent="$AGENT_PROVIDER"
model="$AGENT_MODEL"

echo "Preparing feature:"
echo "  Issue:    #$issue"
echo "  Branch:   $branch"
echo "  Worktree: $worktree"
echo "  Agent:    $agent"
echo "  Model:    $model"
echo "  Level:    $agent_level ($agent_level_why)"
echo "  Selected: by $(agent_selection_text)"
echo

# Modified tracked files would not be part of the feature worktree, which is
# created from the remote base. Untracked files do not matter.
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "Error: this checkout has uncommitted changes to tracked files."
  echo "Commit or stash them before starting a feature."
  records_stop "${0##*/}" "this checkout has uncommitted changes to tracked files."
  exit 1
fi

# Read before anything is created, so a failure leaves nothing behind.
read_comments
echo

# Warn if no plan exists.
# This is allowed when the roadmap/issue explicitly says no plan is required.
if ! ls "$repo_root/.agents/plans/${issue}-"*.md >/dev/null 2>&1; then
  echo "Warning: no .agents/plans/${issue}-*.md found."
  echo "This is fine if the issue does not require a separate implementation plan."
  echo
fi

# Refresh base branch reference.
git fetch origin "$base"

# Prevent accidental duplicate branch/worktree creation.
if git show-ref --verify --quiet "refs/heads/$branch"; then
  echo "Error: branch already exists: $branch"
  records_stop "${0##*/}" "branch already exists: $branch"
  exit 1
fi

if [[ -e "$worktree" ]]; then
  echo "Error: worktree path already exists: $worktree"
  records_stop "${0##*/}" "worktree path already exists: $worktree"
  exit 1
fi

# Create isolated worktree from latest remote base.
git worktree add "$worktree" -b "$branch" "origin/$base"
# Remember the base for a session that resumes the work, and the risk label
# of the Issue for every script of the feature (lib/risk.sh).
git -C "$worktree" config "branch.$branch.workflow-base" "$base"
[[ -z "$label_level" ]] || git -C "$worktree" config "branch.$branch.$RISK_LABEL_KEY" "$label_level"
# The run record notes the owner's hints and the level they gave the first
# session.
if [[ -n "$risk_hint_lines" ]]; then
  records_risk "at the start of the implementation" "$agent_computed" "$(printf '%s\n' "$agent_decision" | sed 1d)" "" "$risk_hint_lines" 2>/dev/null || true
fi

echo
echo "Created feature worktree:"
echo "  $worktree"
echo

# A new worktree has none of the project's ignored files, such as installed
# dependencies or a build cache. A project can prepare them, for example by
# copying them from the primary checkout, in an optional script that runs in
# the worktree before the agent starts. A failure does not stop the feature:
# the preparation only saves time.
setup="$worktree/scripts/worktree-setup.sh"
if [[ -f "$setup" ]]; then
  if [[ -x "$setup" ]]; then
    echo "Preparing the worktree with scripts/worktree-setup.sh..."
    setup_status=0
    (cd "$worktree" && ./scripts/worktree-setup.sh "$repo_root") || setup_status=$?
    if [[ "$setup_status" -ne 0 ]]; then
      echo "Warning: scripts/worktree-setup.sh failed with status $setup_status; continuing without it." >&2
    fi
  else
    echo "Warning: scripts/worktree-setup.sh is not executable; skipped." >&2
  fi
  echo
fi

START_PROMPT="Read and follow .agents/prompts/implementer.md.

Your assigned work item is GitHub Issue #${issue}.

Read GitHub Issue #${issue} using the GitHub CLI.

Read the matching .agents/plans/${issue}-*.md if one exists.

Work only on this issue.

Do not commit, push, merge, or deploy.${COMMENTS_PROMPT}"

run_session "$worktree" "$START_PROMPT"
