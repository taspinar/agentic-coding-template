#!/usr/bin/env bash

# The merge approval gate: which changes of a feature need the owner's
# approval. Source this file; do not execute it.
#
# The gate rests on what the diff contains, not on what an agent says about
# it. The rules are read from the base branch as it is now, so a feature
# cannot relax the rules it is checked by, and a protection that was added to
# the base after the feature started applies to it. The diff is taken from
# the point where the feature left its base.

GUARDRAILS_CONFIG=".agents/policies/guardrails.conf"

# Protected in every project: the ADRs, and the files that define or carry
# out the gate.
GUARDRAILS_BUILTIN_PROTECTED=(
  docs/decisions
  .github/workflows
  .github/CODEOWNERS
  "$GUARDRAILS_CONFIG"
  .agents/policies/autonomy.md
  .agents/prompts/reviewer.md
  .agents/schemas
  scripts/check-guardrails.sh
  scripts/lib/guardrails.sh
  .agents/agents.conf
  scripts/lib/agent.sh
  scripts/lib/review-data.sh
  scripts/lib/review-run.sh
  scripts/lib/fingerprint.sh
  scripts/review-feature.sh
  scripts/finish-feature.sh
  scripts/publish-feature.sh
  scripts/run-feature.sh
)

# The verification configuration: adding a check is sensitive, changing or
# removing a line is protected.
GUARDRAILS_CHECK_LISTS=(scripts/verify.conf scripts/verify-workflow.conf)

# guardrails_rules_refs <root> <base-branch>
# Prints the refs the rules are read from, separated by spaces: the local
# base branch and origin/<base>, whichever exist. The rules of both apply, so
# a protection counts as soon as either knows it, whichever of the two is
# behind. This is independent of where the diff starts.
guardrails_rules_refs() {
  local refs=""
  local ref

  for ref in "$2" "origin/$2"; do
    ! git -C "$1" rev-parse --verify --quiet "$ref^{commit}" >/dev/null || refs+="${refs:+ }$ref"
  done
  printf '%s\n' "$refs"
}

# guardrails_pathspecs <root> <rules-refs> <kind>
# Prints the pathspecs of a kind ('protected' or 'sensitive') from the gate
# configuration in each of <rules-refs> (separated by spaces), one per line.
# Without the file there are none.
guardrails_pathspecs() {
  local ref

  for ref in $2; do
    git -C "$1" show "$ref:$GUARDRAILS_CONFIG" 2>/dev/null |
      sed -n "s/^$3:[[:space:]]*//p" | tr -s '[:space:]' '\n'
  done | grep . | sort -u || true
}

# guardrails_changed <root> <from> <to> <pathspec...>
# Prints the paths that differ between <from> and <to> under the pathspecs.
# With an empty <to> the working tree is compared, including untracked files.
guardrails_changed() {
  local root="$1"
  local from="$2"
  local to="$3"

  shift 3
  [[ $# -gt 0 ]] || return 0
  if [[ -n "$to" ]]; then
    git -C "$root" diff --name-only --no-renames "$from" "$to" -- "$@"
  else
    git -C "$root" diff --name-only --no-renames "$from" -- "$@"
    git -C "$root" ls-files --others --exclude-standard -- "$@"
  fi
}

# guardrails_classify <root> <rules-ref> <from> [<to>]
# Prints one line per finding: '<kind><TAB><path><TAB><reason>', where kind is
# 'protected' or 'sensitive'. Prints nothing when the gate has no finding.
guardrails_classify() {
  local root="$1"
  local rules="$2"
  local from="$3"
  local to="${4:-}"
  local path
  local list
  local removed
  local specs=()
  local spec
  local ref
  local kind

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    case "$path" in
      docs/decisions/*) printf 'protected\t%s\t%s\n' "$path" "an ADR is added, changed, or removed" ;;
      *) printf 'protected\t%s\t%s\n' "$path" "the file defines or carries out the workflow and its gate" ;;
    esac
  done < <(guardrails_changed "$root" "$from" "$to" "${GUARDRAILS_BUILTIN_PROTECTED[@]}" | sort -u)

  for list in "${GUARDRAILS_CHECK_LISTS[@]}"; do
    [[ -n "$(guardrails_changed "$root" "$from" "$to" "$list")" ]] || continue
    if [[ -n "$to" ]]; then
      removed="$(git -C "$root" diff -U0 --no-renames "$from" "$to" -- "$list")"
    else
      removed="$(git -C "$root" diff -U0 --no-renames "$from" -- "$list")"
    fi
    if printf '%s\n' "$removed" | grep -Eq '^-[^-]' || { [[ -z "$to" ]] && [[ ! -e "$root/$list" ]]; }; then
      printf 'protected\t%s\t%s\n' "$list" "an existing check or line is changed or removed"
    else
      printf 'sensitive\t%s\t%s\n' "$list" "a check is added"
    fi
  done

  # The paths the project lists. Each ref's pathspecs are matched on their
  # own and the findings are joined: an exclusion in one ref must not cancel
  # a protection in the other.
  for ref in $rules; do
    for kind in protected sensitive; do
      specs=()
      while IFS= read -r spec; do specs+=("$spec"); done < <(guardrails_pathspecs "$root" "$ref" "$kind")
      while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        printf '%s\t%s\t%s\n' "$kind" "$path" "listed as $kind in $GUARDRAILS_CONFIG"
      done < <(guardrails_changed "$root" "$from" "$to" ${specs[@]+"${specs[@]}"} | sort -u)
    done
  done
}

# guardrails_level
# Reads the output of guardrails_classify and prints the heaviest kind:
# 'protected', 'sensitive', or 'none'.
guardrails_level() {
  awk -F '\t' '
    $1 == "protected" { protected = 1 }
    $1 == "sensitive" { sensitive = 1 }
    END { print (protected ? "protected" : (sensitive ? "sensitive" : "none")) }'
}

# guardrails_review_level <review-json>
# Prints the heaviest classification of the impact on the architecture in a
# review and the rounds it builds on: a review of changes only looks at what
# changed since an earlier round, so it cannot lower what that round found.
# Prints 'missing' when a round in the chain has no valid classification.
guardrails_review_level() {
  local review="$1"
  local heaviest="none"
  local level
  local since
  local stem

  while true; do
    [[ -n "$review" && -f "$review" ]] || { echo "missing"; return 0; }
    level="$(jq -r 'if (.architecture_impact | type) == "object" then (.architecture_impact.level // "") else "" end' "$review" 2>/dev/null || true)"
    case "$level" in
      none) ;;
      minor) [[ "$heaviest" != "none" ]] || heaviest="minor" ;;
      major) [[ "$heaviest" == "breaking" ]] || heaviest="major" ;;
      breaking) heaviest="breaking" ;;
      *) echo "missing"; return 0 ;;
    esac
    since="$(jq -r 'if (.scope | type) == "object" and .scope.kind == "changes" then .scope.since_round else empty end' "$review" 2>/dev/null || true)"
    [[ -n "$since" ]] || break
    stem="${review%-review-[0-9][0-9].json}"
    review="$stem-review-$(printf '%02d' "$since").json"
  done
  echo "$heaviest"
}

# guardrails_decision <root> <rules-ref> <from> <review-json>
# Decides whether the owner must approve the merge of the feature in the
# working tree at <root>, compared with <from>, by the rules in <rules-ref>.
# Prints 'owner' or 'none' on the first line and one reason per following
# line. The heaviest of the two sources decides: the rules, checked on the
# diff, and the classification by the independent reviewer. A missing or
# invalid classification gives no permission. <review-json> may be empty when
# there is no review.
guardrails_decision() {
  local root="$1"
  local rules="$2"
  local from="$3"
  local review="$4"
  local findings
  local level
  local rationale
  local reasons=""

  findings="$(guardrails_classify "$root" "$rules" "$from" | sort -u)"
  if [[ "$(printf '%s\n' "$findings" | guardrails_level)" == "protected" ]]; then
    reasons+="$(printf '%s\n' "$findings" | awk -F '\t' '$1 == "protected" { printf "%s: %s\n", $2, $3 }')"$'\n'
  fi

  level="$(guardrails_review_level "$review")"
  case "$level" in
    none | minor) ;;
    major | breaking)
      # The rationale of the latest round, when that round gave this level;
      # otherwise an earlier round did, and its review holds the rationale.
      rationale="$(jq -r --arg level "$level" 'if .architecture_impact.level == $level then .architecture_impact.rationale else "found in an earlier review round that this round builds on" end' "$review" | tr '\n' ' ')"
      reasons+="the independent review classified the impact on the architecture as $level: $rationale"$'\n'
      ;;
    *) reasons+="no valid classification of the impact on the architecture by an independent reviewer"$'\n' ;;
  esac

  if [[ -n "$reasons" ]]; then
    echo "owner"
    printf '%s' "$reasons" | grep .
  else
    echo "none"
    echo "the independent review classified the impact on the architecture as $level, and no protected path is changed"
  fi
}
