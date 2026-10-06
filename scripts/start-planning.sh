#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/agent.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/scope.sh"

usage() {
  cat <<EOF
Usage: $0 [name] [--description <file>] [--agent <agent>] [--model <model>]

The agent and model of each phase come from .agents/agents.conf (roles
project-grill and project-planner). --agent and --model override both phases.

--description copies an existing project description into the planning
worktree as docs/PROJECT_DESCRIPTION.md. Project Grill reads it first.

Examples:
  $0
  $0 architecture-refresh
  $0 --description ~/notes/project-idea.md
  $0 --agent claude --model fable
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

agent_parse_args "$@"

description_source=""
names=()
set -- ${AGENT_POSITIONAL[@]+"${AGENT_POSITIONAL[@]}"}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --description)
      [[ $# -ge 2 && -n "$2" ]] || fail "--description requires a file."
      description_source="$2"
      shift 2
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
if [[ -n "$description_source" && "$description_source" == "$repo_root"/* ]]; then
  clean_paths+=(":(exclude,literal)${description_source#"$repo_root"/}")
fi
if [[ -n "$(git -C "$repo_root" status --porcelain -- "${clean_paths[@]}")" ]]; then
  fail "current worktree is not clean. Commit or stash changes first."
fi

if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch"; then
  fail "planning branch already exists: $branch"
fi

if [[ -e "$worktree" || -L "$worktree" ]]; then
  fail "planning worktree path already exists: $worktree"
fi

echo "Preparing project planning:"
echo "  Branch:   $branch"
echo "  Worktree: $worktree"
echo "  Grill:    $grill_agent ($grill_model)"
echo "  Planner:  $planner_agent ($planner_model)"
if [[ -n "$description_source" ]]; then
  echo "  Description: $description_source"
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

git -C "$repo_root" worktree add "$worktree" -b "$branch" origin/main ||
  fail "could not create planning worktree."

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

  cat <<EOF
Read and follow ${prompt_path#"$repo_root"/}.

You are running the $phase phase for project bootstrap.
Work only in this planning worktree:
$worktree

Do not commit, push, open or merge a pull request, create GitHub Issues,
implement application features, or deploy.
EOF

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
fi

grill_baseline="$state_dir/grill-baseline.tsv"
planner_baseline="$state_dir/planner-baseline.tsv"
snapshot_forbidden_paths "grill" "$grill_baseline"
snapshot_forbidden_paths "planner" "$planner_baseline"

run_agent "Project Grill" "$grill_prompt" "$grill_agent" "$grill_model" \
  "Phase 1 of 2. The agent asks you questions and writes docs/PROJECT_REQUIREMENTS.md.
After the session, this script shows the requirements and asks for your approval.
When you approve, phase 2 starts by itself: project planning in a new session."
require_unchanged_head "Project Grill"
require_scope_unchanged "grill" "$grill_baseline" "Project Grill"

validate_requirements "Draft"

echo
echo "Project requirements proposed by Project Grill:"
echo
cat "$requirements"
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
validate_requirements "Approved"
approved_requirements_signature="$(requirements_signature)"

run_agent "project planning" "$planner_prompt" "$planner_agent" "$planner_model" \
  "Phase 2 of 2. A new session writes the architecture, roadmap, and ADRs from the
approved requirements. After the session, this script checks the result."
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

  base_blob="$(git -C "$worktree" rev-parse "$base_head:$artifact" 2>/dev/null || true)"
  current_blob="$(git -C "$worktree" hash-object "$artifact_path")"
  [[ -z "$base_blob" || "$current_blob" != "$base_blob" ]] ||
    post_creation_fail "project planner left $artifact content unchanged."

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

echo
echo "Project bootstrap planning completed."
echo "Planning worktree: $worktree"
echo
echo "Next, in the planning worktree, review the planning with an independent agent:"
echo "  cd \"$worktree\""
echo "  ./scripts/review-planning.sh"
echo
echo "Revise and review until the review passes, then approve with ./scripts/finish-planning.sh,"
echo "which prints the commit and push steps for the planning PR."
