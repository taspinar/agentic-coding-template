#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/agent.sh"

usage() {
  echo "Usage: $0 <issue-number> [slug] [base-branch] [--agent <agent>] [--model <model>] [--unattended]"
  echo "       $0 <issue-number> --resume [--agent <agent>] [--model <model>] [--unattended]"
  echo
  echo "The slug names the branch (feature/<issue>-<slug>) and the worktree. Without"
  echo "one, it is derived from the Issue title. The agent and model come from role"
  echo "'implementer' in .agents/agents.conf unless --agent and --model are given."
  echo
  echo "--resume continues interrupted work: it starts a new implementer session in"
  echo "the existing worktree of the Issue, which reads the handoff note and the"
  echo "state of the worktree instead of an earlier conversation."
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
for argument in "$@"; do
  if [[ "$argument" == "--resume" ]]; then
    resume=1
  else
    arguments+=("$argument")
  fi
done

agent_parse_args ${arguments[@]+"${arguments[@]}"}
[[ "${#AGENT_POSITIONAL[@]}" -ge 1 && "${#AGENT_POSITIONAL[@]}" -le 3 ]] || usage
[[ "$resume" -eq 0 || "${#AGENT_POSITIONAL[@]}" -eq 1 ]] || usage

issue="${AGENT_POSITIONAL[0]}"
slug="${AGENT_POSITIONAL[1]:-}"
base="${AGENT_POSITIONAL[2]:-main}"

[[ "$issue" =~ ^[0-9]+$ ]] || agent_fail "issue number must be numeric: $issue"

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
    exit 3
  fi
  if [[ "$agent_status" -ne 0 ]]; then
    echo "Error: the implementation agent exited with status $agent_status." >&2
    echo "The feature worktree is preserved at: $session_worktree" >&2
    echo "Continue the work with: $0 $issue --resume" >&2
    # Status 3 is reserved for a session that reported it is blocked.
    [[ "$agent_status" -ne 3 ]] || agent_status=1
    exit "$agent_status"
  fi
  echo "The implementation session ended. Nothing is committed yet."
  echo
  echo "Next, in the feature worktree:"
  echo "  cd \"$session_worktree\""
  echo "  ./scripts/review-feature.sh $issue    # verifies first, unless the session verified this content"
  echo
  echo "When the work is not complete, continue it with: $0 $issue --resume"
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

  agent_resolve "$repo_root" implementer "$AGENT_CLI_PROVIDER" "$AGENT_CLI_MODEL"
  agent="$AGENT_PROVIDER"
  model="$AGENT_MODEL"

  echo "Resuming feature:"
  echo "  Issue:    #$issue"
  echo "  Branch:   $branch"
  echo "  Base:     $resume_base"
  echo "  Worktree: $worktree"
  echo "  Agent:    $agent"
  echo "  Model:    $model"

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
continue. Do not redo work that is complete; verify it instead.

Work only on this issue.

Do not commit, push, merge, or deploy."

  run_session "$worktree" "$RESUME_PROMPT"
  exit 0
fi

if [[ -z "$slug" ]]; then
  # Derive the slug from the Issue title: without a leading feature ID, in
  # lowercase, as at most four words joined by hyphens.
  command -v gh >/dev/null 2>&1 || agent_fail "GitHub CLI 'gh' is needed to derive the slug; pass a slug instead."
  issue_title="$(gh issue view "$issue" --json title --jq '.title' </dev/null)" ||
    agent_fail "could not read the title of Issue #$issue; pass a slug instead."
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

agent_resolve "$repo_root" implementer "$AGENT_CLI_PROVIDER" "$AGENT_CLI_MODEL"
agent="$AGENT_PROVIDER"
model="$AGENT_MODEL"

echo "Preparing feature:"
echo "  Issue:    #$issue"
echo "  Branch:   $branch"
echo "  Worktree: $worktree"
echo "  Agent:    $agent"
echo "  Model:    $model"
echo

# Modified tracked files would not be part of the feature worktree, which is
# created from the remote base. Untracked files do not matter.
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "Error: this checkout has uncommitted changes to tracked files."
  echo "Commit or stash them before starting a feature."
  exit 1
fi

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
  exit 1
fi

if [[ -e "$worktree" ]]; then
  echo "Error: worktree path already exists: $worktree"
  exit 1
fi

# Create isolated worktree from latest remote base.
git worktree add "$worktree" -b "$branch" "origin/$base"
# Remember the base for a session that resumes the work.
git -C "$worktree" config "branch.$branch.workflow-base" "$base"

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

Do not commit, push, merge, or deploy."

run_session "$worktree" "$START_PROMPT"
