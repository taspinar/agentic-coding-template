#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/agent.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/scope.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/fingerprint.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/planning.sh"

usage() {
  cat <<EOF
Usage: $0 [name] [--description <file>] [--agent <agent>] [--model <model>]
       $0 <name> --change <file> [--grill] [--agent <agent>] [--model <model>]

The agent and model of each phase come from .agents/agents.conf (roles
project-grill and project-planner). --agent and --model override both phases.

--description copies an existing project description into the planning
worktree as docs/PROJECT_DESCRIPTION.md. Project Grill reads it first.

--change starts a change cycle for a planning that is already approved: a new
feature, a changed requirement, or another technical direction. The change
request is copied to docs/changes/<name>.md, and the planner changes only what
it requires. Add --grill when the change adds or alters a requirement; Project
Grill then asks about the change only and you approve the changed requirements
first. Without --grill the requirements stay as they are.

Examples:
  $0
  $0 --description ~/notes/project-idea.md
  $0 --agent claude --model fable
  $0 shopping-list --change ~/notes/shopping-list.md
  $0 household-sharing --change ~/notes/sharing.md --grill
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

agent_parse_args "$@"
agent_reject_unattended

description_source=""
change_source=""
with_grill=0
names=()
set -- ${AGENT_POSITIONAL[@]+"${AGENT_POSITIONAL[@]}"}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --description)
      [[ $# -ge 2 && -n "$2" ]] || fail "--description requires a file."
      description_source="$2"
      shift 2
      ;;
    --change)
      [[ $# -ge 2 && -n "$2" ]] || fail "--change requires a file."
      change_source="$2"
      shift 2
      ;;
    --grill)
      with_grill=1
      shift
      ;;
    --*)
      fail "unknown option: $1"
      ;;
    *)
      names+=("$1")
      shift
      ;;
  esac
done

if [[ "${#names[@]}" -gt 1 ]]; then
  usage
  exit 1
fi

name="${names[0]:-project-bootstrap}"

change_cycle=0
if [[ -n "$change_source" ]]; then
  change_cycle=1
  [[ -z "$description_source" ]] ||
    fail "--change and --description cannot be combined: a change cycle keeps the original description."
  [[ "${#names[@]}" -eq 1 ]] ||
    fail "a change cycle needs a name, which also names the change request: $0 <name> --change <file>"
  [[ -f "$change_source" ]] || fail "change request is not a regular file: $change_source"
  [[ -r "$change_source" && -s "$change_source" ]] ||
    fail "change request is empty or unreadable: $change_source"
  change_source="$(cd "$(dirname "$change_source")" && pwd -P)/$(basename "$change_source")"
elif [[ "$with_grill" -eq 1 ]]; then
  fail "--grill belongs to a change cycle; the first planning always starts with Project Grill."
fi

if [[ -n "$description_source" ]]; then
  [[ -f "$description_source" ]] ||
    fail "project description is not a regular file: $description_source"
  [[ -r "$description_source" && -s "$description_source" ]] ||
    fail "project description is empty or unreadable: $description_source"
  description_source="$(cd "$(dirname "$description_source")" && pwd -P)/$(basename "$description_source")"
fi

[[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
  fail "planning name must match [a-z0-9][a-z0-9-]*: $name"

command -v git >/dev/null 2>&1 || fail "Git is required."

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" ||
  fail "run this script from inside a Git repository."
repo_name="$(basename "$repo_root")"
branch="planning/$name"
worktree="$(dirname "$repo_root")/${repo_name}-planning-${name}"
grill_prompt="$repo_root/.agents/prompts/project-grill.md"
planner_prompt="$repo_root/.agents/prompts/project-planner.md"

agent_resolve "$repo_root" project-grill "$AGENT_CLI_PROVIDER" "$AGENT_CLI_MODEL"
grill_agent="$AGENT_PROVIDER"
grill_model="$AGENT_MODEL"
agent_resolve "$repo_root" project-planner "$AGENT_CLI_PROVIDER" "$AGENT_CLI_MODEL"
planner_agent="$AGENT_PROVIDER"
planner_model="$AGENT_MODEL"

[[ -f "$grill_prompt" ]] || fail "missing Project Grill prompt: $grill_prompt"
[[ -f "$planner_prompt" ]] || fail "missing project-planner prompt: $planner_prompt"

# An uncommitted description inside the repository is the only change that
# does not count as a dirty checkout.
clean_paths=(.)
for source_file in "$description_source" "$change_source"; do
  if [[ -n "$source_file" && "$source_file" == "$repo_root"/* ]]; then
    clean_paths+=(":(exclude,literal)${source_file#"$repo_root"/}")
  fi
done
if [[ -n "$(git -C "$repo_root" status --porcelain -- "${clean_paths[@]}")" ]]; then
  fail "current worktree is not clean. Commit or stash changes first."
fi

if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch"; then
  fail "planning branch already exists: $branch"
fi

if [[ -e "$worktree" || -L "$worktree" ]]; then
  fail "planning worktree path already exists: $worktree"
fi

change_relative="docs/changes/$name.md"
if [[ "$change_cycle" -eq 1 ]]; then
  echo "Preparing a planning change cycle:"
else
  echo "Preparing project planning:"
fi
echo "  Branch:   $branch"
echo "  Worktree: $worktree"
if [[ "$change_cycle" -eq 0 || "$with_grill" -eq 1 ]]; then
  echo "  Grill:    $grill_agent ($grill_model)"
fi
echo "  Planner:  $planner_agent ($planner_model)"
if [[ -n "$description_source" ]]; then
  echo "  Description: $description_source"
fi
if [[ "$change_cycle" -eq 1 ]]; then
  echo "  Change:   $change_source"
fi
echo

git -C "$repo_root" fetch origin main ||
  fail "could not fetch origin/main."
git -C "$repo_root" rev-parse --verify --quiet "refs/remotes/origin/main" \
  >/dev/null ||
  fail "origin/main is unavailable."

set +e
git -C "$repo_root" ls-remote --exit-code --heads origin "$branch" \
  >/dev/null 2>&1
remote_branch_status=$?
set -e
if [[ "$remote_branch_status" -eq 0 ]]; then
  fail "planning branch already exists on origin: $branch"
elif [[ "$remote_branch_status" -ne 2 ]]; then
  fail "could not check origin for an existing planning branch."
fi

# A change cycle changes a planning that exists and was approved.
if [[ "$change_cycle" -eq 1 ]]; then
  git -C "$repo_root" show "origin/main:docs/PROJECT_REQUIREMENTS.md" 2>/dev/null |
    grep -Fqx "Status: Approved" ||
    fail "origin/main has no approved docs/PROJECT_REQUIREMENTS.md; a change cycle needs an approved planning. Start the first planning without --change."
  for document in docs/architecture.md docs/roadmap.md; do
    git -C "$repo_root" cat-file -e "origin/main:$document" 2>/dev/null ||
      fail "origin/main has no $document; a change cycle needs an approved planning."
  done
  ! git -C "$repo_root" cat-file -e "origin/main:$change_relative" 2>/dev/null ||
    fail "$change_relative already exists on origin/main; choose another name for this change."
fi

git -C "$repo_root" worktree add "$worktree" -b "$branch" origin/main ||
  fail "could not create planning worktree."

# A change cycle starts from a planning whose approval is current. The new
# worktree holds exactly origin/main, so the approval is checked there; a
# worktree that fails the check has nothing in it yet and is removed again.
if [[ "$change_cycle" -eq 1 ]]; then
  approval_scratch="$(mktemp -d "${TMPDIR:-/tmp}/start-planning-approval.XXXXXX")"
  approval_status=0
  approval_reason="$(planning_approval_status "$worktree" "$approval_scratch")" || approval_status=$?
  rm -rf "$approval_scratch"
  if [[ "$approval_status" -ne 0 ]]; then
    git -C "$repo_root" worktree remove --force "$worktree" >/dev/null 2>&1 || true
    git -C "$repo_root" branch -q -D "$branch" >/dev/null 2>&1 || true
    fail "the planning on origin/main has no current approval: $approval_reason A change cycle changes an approved planning; approve it first with ./scripts/finish-planning.sh in its planning worktree and merge that."
  fi
fi

echo
echo "Created planning worktree: $worktree"

base_head="$(git -C "$worktree" rev-parse HEAD)"
approval_tmp=""
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/start-planning-state.XXXXXX")"

cleanup() {
  if [[ -n "$approval_tmp" ]]; then
    rm -f "$approval_tmp"
  fi
  rm -rf "$state_dir"
}
trap cleanup EXIT

post_creation_fail() {
  local message="$1"
  local status="${2:-1}"

  echo "Error: $message" >&2
  echo "Planning worktree preserved at: $worktree" >&2
  echo "Inspect it with: git -C \"$worktree\" status --short" >&2
  echo "After correcting the problem, remove the worktree and branch safely or continue the planning artifacts manually." >&2
  exit "$status"
}

require_unchanged_head() {
  local phase="$1"
  local current_head

  current_head="$(git -C "$worktree" rev-parse HEAD)"
  [[ "$current_head" == "$base_head" ]] ||
    post_creation_fail "$phase created a commit; planning agents must leave HEAD unchanged."
}

file_mode() {
  scope_file_mode "$1"
}

# Project Grill may change only the requirements. The planner may change the
# requirements path too, but its content, type, and mode are checked
# separately against the approved signature.
grill_allowed() {
  [[ "$1" == "docs/PROJECT_REQUIREMENTS.md" ]]
}

planner_allowed() {
  [[ "$1" == "docs/PROJECT_REQUIREMENTS.md" ]] || scope_planner_allowed "$1"
}

snapshot_forbidden_paths() {
  scope_snapshot "$worktree" "${1}_allowed" "$2"
}

require_scope_unchanged() {
  local scope="$1"
  local baseline="$2"
  local phase="$3"
  local current_snapshot="$state_dir/${scope}-current.tsv"

  snapshot_forbidden_paths "$scope" "$current_snapshot"
  scope_unchanged "$baseline" "$current_snapshot" ||
    post_creation_fail "$phase exceeded its allowed file scope."
}

requirements_signature() {
  if [[ -L "$requirements" ]]; then
    printf 'symlink:%s:%s\n' "$(file_mode "$requirements")" "$(readlink "$requirements")"
  elif [[ -f "$requirements" ]]; then
    printf 'regular:%s:%s\n' "$(file_mode "$requirements")" "$(git -C "$worktree" hash-object "$requirements")"
  else
    printf 'missing\n'
  fi
}

phase_prompt() {
  local prompt_path="$1"
  local phase="$2"
  local phase_subject="project bootstrap"

  [[ "$change_cycle" -eq 0 ]] || phase_subject="a change to the approved planning"

  cat <<EOF
Read and follow ${prompt_path#"$repo_root"/}.

You are running the $phase phase for $phase_subject.
Work only in this planning worktree:
$worktree

Do not commit, push, open or merge a pull request, create GitHub Issues,
implement application features, or deploy.
EOF

  if [[ "$change_cycle" -eq 1 ]]; then
    cat <<EOF

This is a change cycle, not the first planning: follow the "Change cycle"
section of your contract. The human's change request is $change_relative.
Read it first, and do not modify it. Change only what it requires.
EOF
  fi

  if [[ -n "$description_source" ]]; then
    cat <<EOF

The user supplied a project description as $description_relative.
Read it before anything else. Do not modify it.
EOF
  fi
}

run_agent() {
  local phase="$1"
  local prompt_path="$2"
  local agent="$3"
  local model="$4"
  local prompt
  local status

  prompt="$(phase_prompt "$prompt_path" "$phase")"

  echo
  echo "Starting $phase with $agent ($model)..."
  echo "$5"
  echo

  set +e
  agent_run write "$agent" "$model" "$worktree" "$prompt"
  status=$?
  set -e

  if [[ "$status" -ne 0 ]]; then
    post_creation_fail "$phase failed with status $status." "$status"
  fi
}

requirements="$worktree/docs/PROJECT_REQUIREMENTS.md"
required_sections=(
  "## Project goal"
  "## Target users"
  "## Primary use cases and journeys"
  "## MVP scope"
  "## Non-goals"
  "## UX expectations"
  "## Data and persistence"
  "## Authentication and authorization"
  "## External integrations"
  "## Runtime and deployment constraints"
  "## Security and privacy constraints"
  "## Major product decisions"
  "## Unresolved questions"
)

validate_requirements() {
  local expected_status="$1"
  local section
  local section_count
  local section_state
  local status_count
  local approval_count

  [[ -f "$requirements" && ! -L "$requirements" && -s "$requirements" ]] ||
    post_creation_fail "docs/PROJECT_REQUIREMENTS.md must be a non-empty regular file."

  status_count="$(awk '/^Status: / { count++ } END { print count + 0 }' "$requirements")"
  approval_count="$(awk '/^Approved at: / { count++ } END { print count + 0 }' "$requirements")"
  [[ "$status_count" -eq 1 && "$approval_count" -eq 1 ]] ||
    post_creation_fail "project requirements must contain exactly one Status and Approved at line."

  for section in "${required_sections[@]}"; do
    section_count="$(awk -v heading="$section" '$0 == heading { count++ } END { print count + 0 }' "$requirements")"
    [[ "$section_count" -eq 1 ]] ||
      post_creation_fail "project requirements must contain required section '$section' exactly once."

    section_state="$(awk -v heading="$section" '
      $0 == heading {
        inside = 1
        next
      }
      inside && /^## / {
        exit
      }
      inside && $0 ~ /[^[:space:]]/ {
        if ($0 == "None.") {
          none = 1
        } else {
          content = 1
        }
      }
      END {
        if (content) {
          print "content"
        } else if (none) {
          print "none"
        } else {
          print "empty"
        }
      }
    ' "$requirements")"
    [[ "$section_state" != "empty" ]] ||
      post_creation_fail "project requirements section '$section' has no content."

    case "$section" in
      "## Project goal" | "## Target users" | "## Primary use cases and journeys" | "## MVP scope" | "## UX expectations" | "## Data and persistence" | "## Runtime and deployment constraints")
        [[ "$section_state" == "content" ]] ||
          post_creation_fail "project requirements section '$section' requires substantive content, not None."
        ;;
    esac
  done

  if grep -Fq '<!-- REQUIRED:' "$requirements"; then
    post_creation_fail "project requirements still contain required template placeholders."
  fi

  case "$expected_status" in
    Draft)
      grep -Fqx "Status: Draft" "$requirements" ||
        post_creation_fail "Project Grill must leave requirements in Draft status."
      grep -Fqx "Approved at: Not approved" "$requirements" ||
        post_creation_fail "Draft requirements must say 'Approved at: Not approved'."
      ;;
    Approved)
      grep -Fqx "Status: Approved" "$requirements" ||
        post_creation_fail "requirements approval status was not recorded."
      grep -Eq '^Approved at: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$requirements" ||
        post_creation_fail "requirements approval timestamp is missing or malformed."
      ;;
  esac
}

approve_requirements() {
  local approved_at
  local original_mode

  approved_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  original_mode="$(file_mode "$requirements")"
  approval_tmp="$(mktemp "${requirements}.tmp.XXXXXX")"

  awk -v approved_at="$approved_at" '
    /^Status: Draft$/ {
      print "Status: Approved"
      next
    }
    /^Approved at: Not approved$/ {
      print "Approved at: " approved_at
      next
    }
    { print }
  ' "$requirements" >"$approval_tmp" ||
    post_creation_fail "could not prepare approved project requirements."

  chmod "$original_mode" "$approval_tmp" ||
    post_creation_fail "could not preserve project requirements permissions."
  mv "$approval_tmp" "$requirements" ||
    post_creation_fail "could not atomically record requirements approval."
  approval_tmp=""
}

# Copy the description before the scope baselines are taken, so it is part of
# the protected state of both phases instead of an out-of-scope change.
description_relative="docs/PROJECT_DESCRIPTION.md"
if [[ -n "$description_source" ]]; then
  description_target="$worktree/$description_relative"
  [[ ! -L "$description_target" && (! -e "$description_target" || -f "$description_target") ]] ||
    post_creation_fail "$description_relative exists in the worktree and is not a regular file."
  mkdir -p "$worktree/docs" && cp "$description_source" "$description_target" ||
    post_creation_fail "could not copy the project description into the planning worktree."
  chmod 644 "$description_target" ||
    post_creation_fail "could not set permissions on $description_relative."
  echo "Copied project description to: $description_relative"
  echo "The original stays where it is; cleanup-worktree.sh removes an identical copy in this checkout after the planning is merged."
fi

# The change request is copied before the baselines too. It gets its own file,
# so the original project description stays what it was.
if [[ "$change_cycle" -eq 1 ]]; then
  mkdir -p "$worktree/docs/changes" && cp "$change_source" "$worktree/$change_relative" ||
    post_creation_fail "could not copy the change request into the planning worktree."
  chmod 644 "$worktree/$change_relative" ||
    post_creation_fail "could not set permissions on $change_relative."
  echo "Copied the change request to: $change_relative"
fi

grill_baseline="$state_dir/grill-baseline.tsv"
planner_baseline="$state_dir/planner-baseline.tsv"
snapshot_forbidden_paths "grill" "$grill_baseline"
snapshot_forbidden_paths "planner" "$planner_baseline"

base_requirements_signature="$(requirements_signature)"
requirements_changed=1

if [[ "$change_cycle" -eq 1 && "$with_grill" -eq 0 ]]; then
  # The change is said to fit the approved requirements; the planner stops
  # when it does not, and the planning review checks it.
  requirements_changed=0
  echo
  echo "The requirements stay as approved; Project Grill is skipped (no --grill)."
else
  if [[ "$change_cycle" -eq 1 ]]; then
    grill_notice="Phase 1 of 2. The agent asks you about the change only and updates
docs/PROJECT_REQUIREMENTS.md where the change requires it. After the session,
this script shows what changed and asks for your approval. When you approve,
phase 2 starts by itself: planning the change in a new session."
  else
    grill_notice="Phase 1 of 2. The agent asks you questions and writes docs/PROJECT_REQUIREMENTS.md.
After the session, this script shows the requirements and asks for your approval.
When you approve, phase 2 starts by itself: project planning in a new session."
  fi
  run_agent "Project Grill" "$grill_prompt" "$grill_agent" "$grill_model" "$grill_notice"
  require_unchanged_head "Project Grill"
  require_scope_unchanged "grill" "$grill_baseline" "Project Grill"

  if [[ "$change_cycle" -eq 1 && "$(requirements_signature)" == "$base_requirements_signature" ]]; then
    # Project Grill found that the change needs no requirement change.
    requirements_changed=0
    echo
    echo "Project Grill left the approved requirements unchanged; no new approval is needed."
  fi
fi

if [[ "$requirements_changed" -eq 1 ]]; then
  validate_requirements "Draft"

  echo
  if [[ "$change_cycle" -eq 1 ]]; then
    echo "Changes to the project requirements proposed by Project Grill:"
    echo
    git -C "$worktree" --no-pager diff --no-color "$base_head" -- docs/PROJECT_REQUIREMENTS.md
  else
    echo "Project requirements proposed by Project Grill:"
    echo
    cat "$requirements"
  fi
  echo

  answer=""
  read -r -p "Approve these project requirements and continue to architecture planning? [y/N] " answer || true
  case "$answer" in
    y | Y | yes | YES | Yes) ;;
    *)
      echo
      echo "Requirements were not approved; project planning did not start."
      echo "Planning worktree preserved at: $worktree"
      exit 2
      ;;
  esac

  approve_requirements
fi
validate_requirements "Approved"
approved_requirements_signature="$(requirements_signature)"

if [[ "$change_cycle" -eq 1 ]]; then
  planner_notice="A new session changes the architecture, the roadmap, or the ADRs as far as the
change requires. After the session, this script checks the result."
else
  planner_notice="Phase 2 of 2. A new session writes the architecture, roadmap, and ADRs from the
approved requirements. After the session, this script checks the result."
fi

run_agent "project planning" "$planner_prompt" "$planner_agent" "$planner_model" "$planner_notice"
require_unchanged_head "project planner"

if [[ "$(requirements_signature)" != "$approved_requirements_signature" ]]; then
  post_creation_fail "project planner modified the approved requirements artifact."
fi

require_scope_unchanged "planner" "$planner_baseline" "project planner"

for artifact in docs/architecture.md docs/roadmap.md; do
  artifact_path="$worktree/$artifact"
  [[ -f "$artifact_path" && ! -L "$artifact_path" && -s "$artifact_path" ]] ||
    post_creation_fail "project planner must produce $artifact as a non-empty regular file."
  artifact_mode="$(file_mode "$artifact_path")"
  [[ ! "$artifact_mode" =~ [1357] ]] ||
    post_creation_fail "$artifact must not be executable or have special executable mode bits."

  # The first planning writes both documents. A change may leave either one
  # as it is; that the planner produced a change is checked below.
  if [[ "$change_cycle" -eq 0 ]]; then
    base_blob="$(git -C "$worktree" rev-parse "$base_head:$artifact" 2>/dev/null || true)"
    current_blob="$(git -C "$worktree" hash-object "$artifact_path")"
    [[ -z "$base_blob" || "$current_blob" != "$base_blob" ]] ||
      post_creation_fail "project planner left $artifact content unchanged."
  fi

  case "$artifact" in
    docs/architecture.md)
      grep -Fq "Replace this template" "$artifact_path" &&
        post_creation_fail "docs/architecture.md still contains template placeholder text."
      ;;
    docs/roadmap.md)
      grep -Fq "Define initial product slice" "$artifact_path" &&
        post_creation_fail "docs/roadmap.md still contains template placeholder text."
      ;;
  esac
done

decisions_dir="$worktree/docs/decisions"
if [[ -e "$decisions_dir" || -L "$decisions_dir" ]]; then
  [[ -d "$decisions_dir" && ! -L "$decisions_dir" ]] ||
    post_creation_fail "docs/decisions must be a regular directory when present."

  while IFS= read -r -d '' decision_file; do
    decision_name="${decision_file#"$decisions_dir/"}"
    [[ "$decision_name" == *.md && "$decision_name" != */* ]] ||
      post_creation_fail "planner decision artifacts must be direct Markdown files: docs/decisions/$decision_name"
    [[ -f "$decision_file" && ! -L "$decision_file" ]] ||
      post_creation_fail "planner decision artifact must be a regular Markdown file: docs/decisions/$decision_name"
  done < <(find "$decisions_dir" -mindepth 1 -maxdepth 1 -print0)
fi

if ! git -C "$worktree" diff --quiet --diff-filter=D "$base_head" -- docs/decisions; then
  post_creation_fail "project planner deleted an existing decision artifact."
fi

# roadmap_feature_ids: reads a roadmap on standard input and prints the IDs of
# its feature headings, outside fenced code blocks.
roadmap_feature_ids() {
  awk '
    /^(```|~~~)/ { fenced = !fenced }
    !fenced && /^#+[[:space:]]+F[0-9]+/ {
      match($0, /F[0-9]+/)
      print substr($0, RSTART, RLENGTH)
    }
  ' | LC_ALL=C sort -u
}

completed="Project bootstrap planning"
if [[ "$change_cycle" -eq 1 ]]; then
  completed="Planning change cycle"

  # The planner must have produced the change, in whichever document it fits.
  [[ -n "$(git -C "$worktree" status --porcelain -- docs/architecture.md docs/roadmap.md docs/decisions)" ]] ||
    post_creation_fail "project planner changed neither the architecture, the roadmap, nor an ADR; the change was not planned."

  # Feature IDs are referred to by Issues, branches, and commits, so a
  # change never removes or renumbers one.
  git -C "$worktree" show "$base_head:docs/roadmap.md" | roadmap_feature_ids >"$state_dir/features-before"
  roadmap_feature_ids <"$worktree/docs/roadmap.md" >"$state_dir/features-after"
  removed_features="$(LC_ALL=C comm -23 "$state_dir/features-before" "$state_dir/features-after" | tr '\n' ' ')"
  [[ -z "$removed_features" ]] ||
    post_creation_fail "project planner removed or renumbered roadmap feature(s): ${removed_features% }. Feature IDs are stable; mark a feature as dropped instead of removing it."
fi

echo
echo "$completed completed."
echo "Planning worktree: $worktree"
echo
echo "Next, in the planning worktree, review the planning with an independent agent:"
echo "  cd \"$worktree\""
echo "  ./scripts/review-planning.sh"
echo
echo "Revise and review until the review passes, then approve with ./scripts/finish-planning.sh,"
echo "which prints the commit and push steps for the planning PR."
