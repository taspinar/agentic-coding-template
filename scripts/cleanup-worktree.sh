#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage:"
  echo "  $0 <issue-number>        Remove the merged worktree of feature/<issue>-*"
  echo "  $0 planning/<name>       Remove the merged planning worktree"
  echo "  $0 <worktree-path>       Remove the merged worktree at a path"
  echo "  $0 --merged              Remove every worktree whose pull request is merged"
  echo
  echo "Add --discard to remove an unmerged worktree and its branch after confirmation."
  echo "Run from the primary checkout."
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

discard=0
merged_mode=0
target=""
for argument in "$@"; do
  case "$argument" in
    --discard) discard=1 ;;
    --merged) merged_mode=1 ;;
    -*) usage ;;
    *)
      [[ -z "$target" ]] || usage
      target="$argument"
      ;;
  esac
done
[[ "$merged_mode" -eq 1 && -z "$target" && "$discard" -eq 0 ]] || [[ "$merged_mode" -eq 0 && -n "$target" ]] || usage

command -v gh >/dev/null 2>&1 || fail "GitHub CLI 'gh' is not installed."
command -v jq >/dev/null 2>&1 || fail "jq is required."

# The primary checkout is the first entry of the worktree list.
primary="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"
current="$(git rev-parse --show-toplevel)"
current="$(cd "$current" && pwd -P)"
primary="$(cd "$primary" && pwd -P)"
[[ "$current" == "$primary" ]] ||
  fail "run cleanup-worktree.sh from the primary checkout ($primary), not from a linked worktree."

# linked_worktrees [all]: prints "<path>\t<branch>" for every linked worktree
# on a feature or planning branch, or on any branch with "all". Paths are
# compared resolved, because Git may print them unresolved.
linked_worktrees() {
  local scope="${1:-workflow}"
  local path
  local branch

  git worktree list --porcelain | awk -v scope="$scope" '
    /^worktree / { path = substr($0, 10) }
    /^branch refs\/heads\// {
      branch = substr($0, 19)
      if (scope == "all" || branch ~ /^feature\// || branch ~ /^planning\//) {
        print path "\t" branch
      }
    }
  ' | while IFS=$'\t' read -r path branch; do
    [[ -d "$path" && "$(cd "$path" && pwd -P)" != "$primary" ]] || continue
    printf '%s\t%s\n' "$path" "$branch"
  done
}

# merged_head <branch>: prints the head commit of the merged pull request of
# a branch, or nothing when no pull request of it is merged.
merged_head() {
  gh pr list --head "$1" --state merged --limit 1 --json headRefOid --jq '.[0].headRefOid // empty' </dev/null
}

# cleanup <path> <branch>: removes one worktree and its branch when that is
# safe. Returns 0 when removed, 1 when kept, and 2 when a removal failed;
# prints the reason. Callers run it in a condition, so every destructive step
# checks its own status.
cleanup() {
  local path="$1"
  local branch="$2"
  local head
  local tip
  local answer=""

  path="$(cd "$path" && pwd -P)"
  if [[ "$path" == "$current" ]]; then
    echo "Kept $branch: this is the checkout you run the script in. Run it from the primary checkout."
    return 1
  fi

  # Ignored files, such as review and triage results, do not count.
  if [[ -n "$(git -C "$path" status --porcelain)" ]]; then
    echo "Kept $branch: $path has uncommitted changes."
    return 1
  fi

  if ! head="$(merged_head "$branch")"; then
    echo "Kept $branch: could not ask GitHub about its pull request."
    return 1
  fi
  tip="$(git -C "$path" rev-parse HEAD)"

  if [[ -z "$head" || "$head" != "$tip" ]]; then
    if [[ "$discard" -eq 1 ]]; then
      printf "Discard %s and its worktree %s, although it is not merged? [y/N] " "$branch" "$path"
      read -r answer || true
      case "$answer" in
        y | Y | yes | YES) ;;
        *)
          echo "Kept $branch."
          return 1
          ;;
      esac
    elif [[ -z "$head" ]]; then
      echo "Kept $branch: its pull request is not merged."
      return 1
    else
      echo "Kept $branch: it has commits after its merged pull request."
      return 1
    fi
  fi

  if ! git worktree remove "$path"; then
    echo "Error: could not remove the worktree of $branch at $path; the branch was kept." >&2
    return 2
  fi
  if ! git branch -D "$branch" >/dev/null; then
    echo "Error: removed the worktree of $branch, but could not delete the branch." >&2
    return 2
  fi
  echo "Removed $branch and its worktree $path."
  if [[ "$branch" == planning/* && -n "$head" && "$head" == "$tip" ]]; then
    removed_planning=1
  fi
  return 0
}

removed=0
removed_planning=0
main_updated=0
errors=0
if [[ "$merged_mode" -eq 1 ]]; then
  while IFS=$'\t' read -r path branch; do
    [[ -n "$path" ]] || continue
    status=0
    cleanup "$path" "$branch" </dev/null || status=$?
    case "$status" in
      0) removed=$((removed + 1)) ;;
      2) errors=$((errors + 1)) ;;
    esac
  done < <(linked_worktrees)
  [[ "$removed" -gt 0 || "$errors" -gt 0 ]] || echo "No merged worktree to remove."
else
  # Resolve the target to exactly one worktree.
  matches="$(linked_worktrees | awk -F '\t' -v target="$target" '
    BEGIN { issue = (target ~ /^[0-9]+$/) }
    issue && index($2, "feature/" target "-") == 1 { print; next }
    !issue && $2 == target { print; next }
  ')"
  if [[ -z "$matches" && -e "$target" ]]; then
    target_path="$(cd "$target" && pwd -P)"
    matches="$(linked_worktrees all | while IFS=$'\t' read -r path branch; do
      [[ "$(cd "$path" && pwd -P)" == "$target_path" ]] && printf '%s\t%s\n' "$path" "$branch"
    done || true)"
  fi
  [[ -n "$matches" ]] || fail "no feature or planning worktree matches: $target"
  [[ "$(printf '%s\n' "$matches" | grep -c .)" -eq 1 ]] || fail "more than one worktree matches: $target"

  IFS=$'\t' read -r path branch <<<"$matches"
  status=0
  cleanup "$path" "$branch" || status=$?
  case "$status" in
    0) removed=1 ;;
    1) exit 1 ;;
    *) errors=1 ;;
  esac
fi

git worktree prune

if [[ "$removed" -gt 0 ]]; then
  # Bring main up to date with the merged work. Untracked files do not prevent
  # a fast-forward; modified tracked files do.
  if [[ "$(git -C "$primary" branch --show-current)" == "main" &&
        -z "$(git -C "$primary" status --porcelain --untracked-files=no)" ]]; then
    if git -C "$primary" pull -q --ff-only origin main; then
      echo "Updated main in $primary."
      main_updated=1
    else
      echo "Warning: could not fast-forward main in $primary; update it by hand with: git pull --ff-only origin main"
    fi
  else
    git -C "$primary" fetch -q origin main || true
    echo "Fetched origin/main, but did not update $primary: it is not on main or has uncommitted changes to tracked files."
    echo "Update it by hand with: git pull --ff-only origin main"
  fi

  # After a merged planning, the description that start-planning.sh copied is
  # in the repository. Remove an untracked original that is byte-identical.
  description="$primary/docs/PROJECT_DESCRIPTION.md"
  if [[ "$removed_planning" -eq 1 && "$main_updated" -eq 1 && -f "$description" ]]; then
    while IFS= read -r -d '' candidate; do
      if [[ -f "$primary/$candidate" && ! -L "$primary/$candidate" ]] && cmp -s "$primary/$candidate" "$description"; then
        rm "$primary/$candidate"
        echo "Removed $candidate: it is identical to docs/PROJECT_DESCRIPTION.md, which is now in the repository."
      fi
    done < <(git -C "$primary" ls-files --others --exclude-standard -z)
  fi

  echo
  echo "Next: create the Issue of the next roadmap feature, using its ID from docs/roadmap.md:"
  echo "  ./scripts/create-feature-issue.sh <feature-id>    # for example F01"
fi

[[ "$errors" -eq 0 ]] || exit 1
