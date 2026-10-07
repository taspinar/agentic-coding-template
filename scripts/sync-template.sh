#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 [--to <ref>] [--from <commit>] [--template <url-or-path>]"
  echo
  echo "Takes over the changes the workflow template made since the version this"
  echo "project has. Only the files listed under 'paths:' in .agents/template.conf"
  echo "are touched. Run it from the primary checkout without uncommitted changes"
  echo "to tracked files; on 'main' it first creates a branch."
  echo
  echo "  A file the project did not change is replaced."
  echo "  A file both changed is merged; a conflict is left in the file and reported."
  echo "  A file that is new in the template is added."
  echo "  A file the template removed is reported, never deleted."
  echo
  echo "--to selects the template version (default: its default branch). --from"
  echo "overrides the recorded template commit of the project. --template overrides"
  echo "the recorded location of the template."
  echo
  echo "The script never commits or pushes. It exits 1 when a conflict is left."
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

to_ref=""
from_commit=""
template=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --to | --from | --template)
      [[ $# -ge 2 && -n "$2" ]] || fail "$1 requires a value."
      case "$1" in
        --to) to_ref="$2" ;;
        --from) from_commit="$2" ;;
        --template) template="$2" ;;
      esac
      shift 2
      ;;
    *) usage ;;
  esac
done

root="$(git rev-parse --show-toplevel)"
config="$root/.agents/template.conf"
config_relative=".agents/template.conf"

# config_value <file> <key>: prints the value of the first '<key>: ' line.
config_value() {
  [[ -f "$1" ]] || return 0
  sed -n "s/^$2:[[:space:]]*//p" "$1" | head -n 1
}

# plain_path <path>: succeeds when neither <path> nor a directory above it,
# inside the project, is a symbolic link. Writing through a link would change
# a file that is not the template's.
plain_path() {
  local current="$1"

  while [[ "$current" != "." && "$current" != "/" ]]; do
    [[ ! -L "$root/$current" ]] || return 1
    current="$(dirname "$current")"
  done
}

# The configuration is written at the end, so it must be a file of the
# project itself, like every file the sync writes.
plain_path "$config_relative" && [[ ! -e "$config" || -f "$config" ]] ||
  fail "$config_relative is not a regular file of this project (it is, or lies under, a symbolic link). The sync writes there, so it stops."

[[ -n "$template" ]] || template="$(config_value "$config" repository)"
[[ -n "$template" ]] ||
  fail "no template is recorded in $config_relative. Pass --template <url-or-path>."

[[ -z "$(git -C "$root" status --porcelain --untracked-files=no)" ]] ||
  fail "there are uncommitted changes to tracked files. Commit or stash them first, so the sync can be reviewed and undone on its own."

work="$(mktemp -d "${TMPDIR:-/tmp}/sync-template.XXXXXX")"
trap 'rm -rf "$work"' EXIT

echo "Fetching the template: $template"
git clone --quiet --bare "$template" "$work/template.git" 2>"$work/clone.err" || {
  cat "$work/clone.err" >&2
  fail "could not fetch the template."
}
template_git() {
  git --git-dir="$work/template.git" "$@"
}

target="$(template_git rev-parse --verify --quiet "${to_ref:-HEAD}^{commit}")" ||
  fail "the template has no version '${to_ref:-HEAD}'."

# The template-owned files are those of the target version, so a file the
# template started to own is picked up; an older template without the list
# falls back to the project's own.
template_git show "$target:$config_relative" >"$work/target.conf" 2>/dev/null || : >"$work/target.conf"
paths_value="$(config_value "$work/target.conf" paths)"
[[ -n "$paths_value" ]] || paths_value="$(config_value "$config" paths)"
[[ -n "$paths_value" ]] ||
  fail "neither the template nor $config_relative lists the template files under 'paths:'."
specs=()
read -r -a specs <<<"$paths_value"
# The project decides what is its own: every exclusion in its list stays in
# force, whatever the template lists.
project_specs=()
read -r -a project_specs <<<"$(config_value "$config" paths)"
for spec in ${project_specs[@]+"${project_specs[@]}"}; do
  [[ "$spec" != ":(exclude)"* && "$spec" != ":!"* && "$spec" != ":^"* ]] || specs+=("$spec")
done

# The template version the project has: given, recorded, or else the template
# commit with the most files identical to the project's.
base="$from_commit"
[[ -n "$base" ]] || base="$(config_value "$config" commit)"
if [[ -n "$base" ]]; then
  base="$(template_git rev-parse --verify --quiet "$base^{commit}")" ||
    fail "the template has no commit '$base'. Pass --from <commit>."
else
  echo "No template version is recorded; looking for the best match..."
  git -C "$root" ls-files -s | sed 's/^[0-9]* \([0-9a-f]*\) [0-9]'$'\t''/\1 /' | LC_ALL=C sort >"$work/project.blobs"
  best=0
  candidates=()
  while IFS= read -r commit; do
    template_git ls-tree -r "$commit" | sed 's/^[0-9]* blob \([0-9a-f]*\)'$'\t''/\1 /' | LC_ALL=C sort >"$work/commit.blobs"
    matches="$(LC_ALL=C comm -12 "$work/project.blobs" "$work/commit.blobs" | grep -c . || true)"
    # Newest first, so an equal count keeps the newer commit as the base.
    if [[ "$matches" -gt "$best" ]]; then
      best="$matches"
      base="$commit"
      candidates=("$commit")
    elif [[ "$matches" -eq "$best" ]]; then
      candidates+=("$commit")
    fi
  done < <(template_git rev-list "$target")
  [[ -n "$base" && "$best" -gt 0 ]] ||
    fail "no template version shares a file with this project. Pass --from <commit>."
  # Several versions can match equally well, when the template changed only
  # files that the project changed too. Taking the newest would then skip
  # those template changes, so the choice is the user's.
  ambiguous=0
  for commit in "${candidates[@]}"; do
    template_git diff --quiet "$commit" "$base" -- "${specs[@]}" || ambiguous=1
  done
  if [[ "$ambiguous" -eq 1 ]]; then
    echo "Error: the template version of this project cannot be determined." >&2
    echo "These versions match it equally well ($best identical files) and differ in template files:" >&2
    for commit in "${candidates[@]}"; do
      template_git log -1 --format='  %h %ad %s' --date=short "$commit" >&2
    done
    echo "Pass --from <commit> with the version the project was created from or last synced with; the oldest is the safe choice." >&2
    exit 1
  fi
  echo "The project matches template commit ${base:0:7} best ($best identical files); using it as the base."
  echo "Pass --from <commit> when that is not the version the project was created from."
fi
recorded="$(config_value "$config" commit)"

template_git merge-base --is-ancestor "$base" "$target" ||
  fail "template commit ${base:0:7} is not part of version ${target:0:7}. Pass --to or --from."

if [[ "$base" == "$target" && "$recorded" == "$target" &&
  "$(config_value "$config" repository)" == "$template" ]]; then
  echo "Already up to date with template commit ${target:0:7}."
  exit 0
fi

branch="$(git -C "$root" branch --show-current)"
if [[ "$branch" == "main" ]]; then
  branch="fix/sync-template-${target:0:7}"
  git -C "$root" switch -q -c "$branch" 2>/dev/null ||
    fail "could not create branch $branch. When it is left from an earlier sync, switch to it or delete it, and run the sync again."
  echo "Created branch $branch."
fi

echo
if [[ "$base" == "$target" ]]; then
  echo "The project already has template commit ${target:0:7}; only recording it and its location."
else
  echo "Template changes from ${base:0:7} to ${target:0:7}:"
  template_git log --format='  %h %s' "$base..$target"
fi
echo

replaced=()
merged=()
added=()
conflicts=()
notes=()

# mode_of <commit> <path>: prints the Git file mode, or nothing when absent.
mode_of() {
  template_git ls-tree "$1" -- "$2" | cut -c1-6
}

# set_mode <path>: gives the project's file the executable bit of the target.
set_mode() {
  if [[ "$(mode_of "$target" "$1")" == "100755" ]]; then
    chmod +x "$root/$1"
  else
    chmod -x "$root/$1"
  fi
}

# A file is never rewritten in place: the new content is written next to it
# and moved over it. One of the files can be this script, which Bash is still
# reading, and a file that keeps its inode would change under it.
staged_suffix=".sync-template.$$"

# take <path>: writes the target version of <path> into the project.
take() {
  mkdir -p "$(dirname "$root/$1")"
  template_git show "$target:$1" >"$root/$1$staged_suffix"
  mv -f "$root/$1$staged_suffix" "$root/$1"
  set_mode "$1"
}

# merge <path>: merges the template's change into the project's file. Exits
# non-zero when a conflict is left in the file.
merge() {
  local merge_status=0

  cp -p "$root/$1" "$root/$1$staged_suffix"
  git merge-file -L project -L "template ${base:0:7}" -L "template ${target:0:7}" \
    "$root/$1$staged_suffix" "$work/base" "$work/target" >/dev/null 2>&1 || merge_status=$?
  mv -f "$root/$1$staged_suffix" "$root/$1"
  return "$merge_status"
}

while IFS=$'\t' read -r status path; do
  [[ -n "$path" ]] || continue
  file="$root/$path"
  if ! plain_path "$path"; then
    notes+=("$path: is, or lies under, a symbolic link in the project; left unchanged")
    continue
  fi
  if [[ -e "$file" && ! -f "$file" ]]; then
    notes+=("$path: is not a regular file in the project; left unchanged")
    continue
  fi
  mode_changed=0
  [[ "$status" == "A" || "$(mode_of "$base" "$path")" == "$(mode_of "$target" "$path")" ]] || mode_changed=1
  case "$status" in
    D)
      [[ ! -e "$file" ]] ||
        notes+=("$path: removed from the template; delete it when the project no longer needs it")
      continue
      ;;
    A) : >"$work/base" ;;
    *) template_git show "$base:$path" >"$work/base" ;;
  esac
  template_git show "$target:$path" >"$work/target"

  if [[ ! -e "$file" ]]; then
    if [[ "$status" == "A" ]]; then
      take "$path"
      added+=("$path")
    else
      notes+=("$path: changed in the template, but the project has no such file; left out")
    fi
  elif cmp -s "$file" "$work/target"; then
    # Same content already; a change of the executable bit still applies.
    if [[ "$mode_changed" -eq 1 ]]; then
      set_mode "$path"
      replaced+=("$path (file mode)")
    fi
  elif [[ "$status" != "A" ]] && cmp -s "$file" "$work/base"; then
    take "$path"
    replaced+=("$path")
  elif merge "$path"; then
    [[ "$mode_changed" -eq 0 ]] || set_mode "$path"
    merged+=("$path")
  else
    [[ "$mode_changed" -eq 0 ]] || set_mode "$path"
    conflicts+=("$path")
  fi
done < <(template_git diff --no-renames --name-status "$base" "$target" -- "${specs[@]}")

# Record the template the project now follows and the version it has. The
# repository is recorded too, so a sync from another location, such as a
# fork, is continued from there.
mkdir -p "$(dirname "$config")"
[[ -f "$config" ]] || printf 'paths: %s\n' "$paths_value" >"$config"
{
  has_repository=0
  has_commit=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      repository:*)
        printf 'repository: %s\n' "$template"
        has_repository=1
        ;;
      commit:*)
        printf 'commit: %s\n' "$target"
        has_commit=1
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done <"$config"
  [[ "$has_repository" -eq 1 ]] || printf '\nrepository: %s\n' "$template"
  [[ "$has_commit" -eq 1 ]] || printf '\ncommit: %s\n' "$target"
} >"$work/config"
cp "$work/config" "$config$staged_suffix"
mv -f "$config$staged_suffix" "$config"

print_list() {
  local title="$1"

  shift
  [[ $# -gt 0 ]] || return 0
  echo "$title"
  printf '  %s\n' "$@"
}

print_list "Replaced (the project had not changed them):" ${replaced[@]+"${replaced[@]}"}
print_list "Merged with the project's changes:" ${merged[@]+"${merged[@]}"}
print_list "Added:" ${added[@]+"${added[@]}"}
print_list "Needs your attention:" ${notes[@]+"${notes[@]}"}
print_list "CONFLICTS, marked in the file with <<<<<<< and >>>>>>>:" ${conflicts[@]+"${conflicts[@]}"}
echo
echo "Recorded template commit ${target:0:7} in $config_relative."
echo "Nothing is committed. To undo, discard the changes with 'git checkout -- .' and"
echo "delete the files listed under 'Added'."
echo
if [[ "${#conflicts[@]}" -gt 0 ]]; then
  echo "Resolve the conflicts above, then:" >&2
else
  echo "Next:"
fi
echo "  ./scripts/verify.sh --all"
echo "  git add -A && git commit -m \"Sync workflow scripts with the template (${target:0:7})\""
echo "  Push the branch and open a pull request."
[[ "${#conflicts[@]}" -eq 0 ]] || exit 1
