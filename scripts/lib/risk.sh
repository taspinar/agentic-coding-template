#!/usr/bin/env bash

# The risk level of a feature: low, medium, or high, from one policy. Source
# this file; do not execute it. It needs lib/guardrails.sh, which it sources.
#
# The level is the highest of three sources:
#
# 1. the path-based minimum: the highest class of any path the feature
#    changed, by the classes in .agents/policies/risk.conf, and the default
#    of that file for a path no class names;
# 2. the fixed escalations to high: a changed or removed line in a
#    verification configuration, a change to an existing test file, a change
#    to an existing file under .agents/policies/, .agents/prompts/, or
#    .agents/schemas/ (the policy itself among them), and a change to an
#    existing dependency or toolchain manifest the policy names. An
#    escalation reads only changed or removed existing lines and files: a
#    file the feature adds, and the lines of a new file, never escalate by
#    themselves, whatever they hold; a protected path keeps its high class by
#    the path rule. No escalation reads the content of a line;
# 3. what an agent recorded: 'risk' in the implementer's completion record,
#    and the independent reviewer's architecture_impact, of which major and
#    breaking count as high.
#
# An agent can raise the level, never lower it: a recorded level below the
# computed one is ignored and reported. The rules are read from the base
# branch as it is now, like the merge approval gate's, so a feature cannot
# relax the rules it is classified by; the diff is taken from where the
# feature left its base. When that base cannot be determined, or the changes
# of the feature cannot be enumerated, the level is high.
#
# The same policy says what each level requires of the workflow
# (risk_requirement): '<level>: verification: full|groups <group>...' for the
# verification of the intermediate review rounds of run-feature.sh, and
# '<level>: review: full|delta|none' for its later rounds. Without the line a
# level requires the full verification and allows a review of changes only
# (delta), which is what the workflow did before the policy knew the levels.
# 'none' is accepted for low only. Of the refs the rules come from, the
# strictest requirement counts, and a value that is not accepted counts as
# the strictest and is reported.

if ! declare -F guardrails_rules_refs >/dev/null; then
  source "${BASH_SOURCE[0]%/*}/guardrails.sh"
fi

RISK_CONFIG=".agents/policies/risk.conf"

# A project whose base has no risk.conf gets what the template ships: every
# feature is medium or high, with the files of the workflow and its gate as
# the high class.
RISK_BUILTIN_DEFAULT="medium"
RISK_BUILTIN_HIGH=("${GUARDRAILS_BUILTIN_PROTECTED[@]}" "${GUARDRAILS_CHECK_LISTS[@]}" scripts/check-risk.sh scripts/lib/risk.sh)
RISK_BUILTIN_TESTS=(tests test)
# A change under these escalates to high in every project.
RISK_ESCALATION_DIRS=(.agents/policies .agents/prompts .agents/schemas)
# Left out of the diff: the artifacts a run writes while it works.
RISK_EXCLUDES=(":(exclude).agents/reviews" ":(exclude).agents/triage" ":(exclude).agents/run/records" ":(exclude).agents/records")
# What a level requires of the workflow, '<level>: <kind>: <value>' in the
# policy, and what the template ships for every level: the full verification
# before each review round, and a review of changes only when it can build on
# the round before.
RISK_REQUIREMENT_KINDS="verification|review"
RISK_DEFAULT_VERIFICATION="full"
RISK_DEFAULT_REVIEW="delta"

# risk_is_level <text>
risk_is_level() {
  [[ "$1" == "low" || "$1" == "medium" || "$1" == "high" ]]
}

# risk_rank <level>: 0 for low, 1 for medium, 2 for high; -1 otherwise.
risk_rank() {
  case "$1" in
    low) echo 0 ;;
    medium) echo 1 ;;
    high) echo 2 ;;
    *) echo -1 ;;
  esac
}

# risk_highest <level>...: the highest of the levels; nothing without one.
risk_highest() {
  local best=""
  local level

  for level in "$@"; do
    risk_is_level "$level" || continue
    [[ -n "$best" && "$(risk_rank "$best")" -ge "$(risk_rank "$level")" ]] || best="$level"
  done
  [[ -z "$best" ]] || printf '%s\n' "$best"
}

# risk_config_exists <root> <ref>
risk_config_exists() {
  git -C "$1" cat-file -e "$2:$RISK_CONFIG" 2>/dev/null
}

# risk_config_lines <root> <ref> <key>
# Prints the value of every line of the policy of <ref> that has the key, as
# written, one line each; nothing when the file or the key is absent.
risk_config_lines() {
  git -C "$1" show "$2:$RISK_CONFIG" 2>/dev/null |
    sed -n "s/^$3:[[:space:]]*//p" || true
}

# risk_config_values <root> <ref> <key>
# Prints the values of a key in the policy of <ref>, one per line; nothing
# when the file or the key is absent. The requirement lines of a level
# ('<level>: verification: ...', '<level>: review: ...') are not paths and
# are left out.
risk_config_values() {
  risk_config_lines "$1" "$2" "$3" |
    grep -Ev "^($RISK_REQUIREMENT_KINDS):" | tr -s '[:space:]' '\n' | grep . || true
}

# risk_requirement_value <root> <ref> <level> <kind>
# Prints the requirement of <kind> ('verification' or 'review') for <level>
# in the policy of <ref>, as written, with single spaces; nothing when the
# file or the line is absent. The first such line counts.
risk_requirement_value() {
  risk_config_lines "$1" "$2" "$3" |
    sed -n "s/^$4:[[:space:]]*//p" | sed -n 1p | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'
}

# risk_requirement <root> <rules-refs> <level> <kind>
# Prints on the first line what the level requires: for 'verification', 'full'
# or 'groups <group> ...' (the groups of verify.sh that the intermediate
# review rounds run); for 'review', 'full', 'delta', or 'none'. Every line
# after it names a value of the policy that is not accepted. The requirement
# is the strictest over the refs (full before groups; full before delta before
# none), the built-in default (RISK_DEFAULT_VERIFICATION,
# RISK_DEFAULT_REVIEW) stands for a ref without the line, and a value that
# is not accepted counts as the strictest: a word the policy does not know, a
# group name that is none, or 'none' for a level other than low.
risk_requirement() {
  local root="$1"
  local rules="$2"
  local level="$3"
  local kind="$4"
  local ref
  local value
  local rank=-1
  local groups=""
  local problems=""

  for ref in $rules; do
    value="$(risk_requirement_value "$root" "$ref" "$level" "$kind")"
    case "$kind" in
      verification)
        if [[ -z "$value" || "$value" == "full" ]]; then
          rank=1
        elif [[ "$value" =~ ^groups([[:space:]][a-z0-9][a-z0-9-]*)+$ ]]; then
          [[ "$rank" -ge 0 ]] || rank=0
          groups+="${value#groups}"
        else
          problems+="$level: verification: $value is not accepted in $RISK_CONFIG of $ref (full, or groups <group>...); the full verification applies"$'\n'
          rank=1
        fi
        ;;
      review)
        case "$value" in
          "") [[ "$rank" -ge 1 ]] || rank=1 ;;
          full) rank=2 ;;
          delta) [[ "$rank" -ge 1 ]] || rank=1 ;;
          none)
            if [[ "$level" == "low" ]]; then
              [[ "$rank" -ge 0 ]] || rank=0
            else
              problems+="$level: review: none is refused in $RISK_CONFIG of $ref: only a low-risk feature may go without a review; a complete review applies"$'\n'
              rank=2
            fi
            ;;
          *)
            problems+="$level: review: $value is not accepted in $RISK_CONFIG of $ref (full, delta, or none for low); a complete review applies"$'\n'
            rank=2
            ;;
        esac
        ;;
    esac
  done

  case "$kind" in
    verification)
      if [[ "$rank" -eq 0 ]]; then
        echo "groups$(printf '%s\n' $groups | sort -u | tr '\n' ' ' | sed 's/ $//; s/^/ /')"
      else
        echo "$RISK_DEFAULT_VERIFICATION"
      fi
      ;;
    review)
      case "$rank" in
        0) echo "none" ;;
        1) echo "$RISK_DEFAULT_REVIEW" ;;
        *) echo "full" ;;
      esac
      ;;
  esac
  printf '%s' "$problems"
}

# risk_requirements <root> <rules-refs> <level>
# Prints 'verification: <requirement>' and 'review: <requirement>' for the
# level, then one line 'refused: <problem>' per value of the policy that is
# not accepted.
risk_requirements() {
  local verification
  local review

  verification="$(risk_requirement "$1" "$2" "$3" verification)"
  review="$(risk_requirement "$1" "$2" "$3" review)"
  echo "verification: $(printf '%s\n' "$verification" | sed -n 1p)"
  echo "review: $(printf '%s\n' "$review" | sed -n 1p)"
  { printf '%s\n' "$verification" | sed 1d; printf '%s\n' "$review" | sed 1d; } | grep . | sed 's/^/refused: /' || true
}

# risk_default <root> <rules-refs>
# Prints the default level of the rules: the highest default of the refs,
# with the built-in one for a ref without the file or the key. An invalid
# default counts as high.
risk_default() {
  local ref
  local value
  local levels=()

  for ref in $2; do
    value="$(risk_config_values "$1" "$ref" default | head -n 1)"
    if [[ -z "$value" ]]; then
      levels+=("$RISK_BUILTIN_DEFAULT")
    elif risk_is_level "$value"; then
      levels+=("$value")
    else
      levels+=(high)
    fi
  done
  risk_highest "$RISK_BUILTIN_DEFAULT" ${levels[@]+"${levels[@]}"}
}

# risk_union_values <root> <rules-refs> <key> <builtin>...
# Prints the values of a key over all refs, one per line; the built-in
# values when no ref has the key.
risk_union_values() {
  local root="$1"
  local rules="$2"
  local key="$3"
  local ref
  local values

  shift 3
  values="$(for ref in $rules; do risk_config_values "$root" "$ref" "$key"; done | grep . | sort -u || true)"
  if [[ -n "$values" ]]; then
    printf '%s\n' "$values"
  elif [[ $# -gt 0 ]]; then
    printf '%s\n' "$@"
  fi
}

# risk_existing_changed <root> <from> <to> <pathspec...>
# Prints the paths under the pathspecs that exist in <from> and are changed
# or removed, one per line as '<M|D><TAB><path>'. A file the feature adds is
# left out, also an untracked one: it is new, whatever it holds. With an
# empty <to> the working tree is compared.
risk_existing_changed() {
  local root="$1"
  local from="$2"
  local to="$3"

  shift 3
  [[ $# -gt 0 ]] || return 0
  if [[ -n "$to" ]]; then
    git -C "$root" diff --name-status --no-renames "$from" "$to" -- "$@"
  else
    git -C "$root" diff --name-status --no-renames "$from" -- "$@"
  fi | awk -F '\t' '$1 !~ /^A/ && $2 != "" { printf "%s\t%s\n", substr($1, 1, 1), $2 }' | sort -u
}

# risk_classify <root> <rules-refs> <from> [<to>]
# Prints one line per finding: '<level><TAB><path><TAB><reason>'. The path
# classes of each ref are applied on their own and the findings are joined,
# so a class in one ref is not cancelled by the other. Then the fixed
# escalations.
risk_classify() {
  local root="$1"
  local rules="$2"
  local from="$3"
  local to="${4:-}"
  local ref
  local level
  local default
  local value
  local specs=()
  local spec
  local path
  local all
  local classed
  local list

  all="$(guardrails_changed "$root" "$from" "$to" . "${RISK_EXCLUDES[@]}" | grep . | sort -u || true)"

  for ref in $rules; do
    classed=""
    if risk_config_exists "$root" "$ref"; then
      value="$(risk_config_values "$root" "$ref" default | head -n 1)"
      if [[ -z "$value" ]]; then
        default="$RISK_BUILTIN_DEFAULT"
      elif risk_is_level "$value"; then
        default="$value"
      else
        default="high"
        printf 'high\t%s\t%s\n' "$RISK_CONFIG" "the default of the policy is not a level: $value"
      fi
      for level in high medium low; do
        specs=()
        while IFS= read -r spec; do specs+=("$spec"); done < <(risk_config_values "$root" "$ref" "$level")
        [[ "${#specs[@]}" -gt 0 ]] || continue
        while IFS= read -r path; do
          [[ -n "$path" ]] || continue
          classed+="$path"$'\n'
          printf '%s\t%s\t%s\n' "$level" "$path" "listed as $level in $RISK_CONFIG"
        done < <(guardrails_changed "$root" "$from" "$to" "${specs[@]}" "${RISK_EXCLUDES[@]}" | sort -u)
      done
      while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        printf '%s\t%s\t%s\n' "$default" "$path" "no class of $RISK_CONFIG names it; the default is $default"
      done < <(comm -23 <(printf '%s\n' "$all" | grep . || true) <(printf '%s' "$classed" | grep . | sort -u || true))
    else
      while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        classed+="$path"$'\n'
        printf 'high\t%s\t%s\n' "$path" "a file of the workflow and its gate; the base has no $RISK_CONFIG, so the built-in high class applies"
      done < <(guardrails_changed "$root" "$from" "$to" "${RISK_BUILTIN_HIGH[@]}" "${RISK_EXCLUDES[@]}" | sort -u)
      while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        printf '%s\t%s\t%s\n' "$RISK_BUILTIN_DEFAULT" "$path" "the base has no $RISK_CONFIG; the default is $RISK_BUILTIN_DEFAULT"
      done < <(comm -23 <(printf '%s\n' "$all" | grep . || true) <(printf '%s' "$classed" | grep . | sort -u || true))
    fi
  done

  # The fixed escalations. A changed or removed line in a verification
  # configuration, as the merge approval gate finds it.
  while IFS=$'\t' read -r level path _; do
    [[ "$level" == "protected" ]] || continue
    for list in "${GUARDRAILS_CHECK_LISTS[@]}"; do
      [[ "$path" == "$list" ]] || continue
      printf 'high\t%s\t%s\n' "$path" "a check or a line of the verification configuration is changed or removed"
    done
  done < <(guardrails_classify "$root" "$rules" "$from" "$to" | sort -u)

  # A change to an existing test file; a new, standalone test file is none.
  specs=()
  while IFS= read -r spec; do specs+=("$spec"); done < <(risk_union_values "$root" "$rules" tests "${RISK_BUILTIN_TESTS[@]}")
  while IFS=$'\t' read -r level path; do
    [[ -n "$path" ]] || continue
    if [[ "$level" == "D" ]]; then
      printf 'high\t%s\t%s\n' "$path" "an existing test file is removed"
    else
      printf 'high\t%s\t%s\n' "$path" "an existing test file is changed"
    fi
  done < <(risk_existing_changed "$root" "$from" "$to" "${specs[@]}" "${RISK_EXCLUDES[@]}")

  # An existing policy, agent contract, or schema that is changed or removed.
  # A file the feature adds under these directories is new and does not
  # escalate by itself; in the template it is high by the path rule.
  while IFS=$'\t' read -r level path; do
    [[ -n "$path" ]] || continue
    if [[ "$path" == "$RISK_CONFIG" ]]; then
      printf 'high\t%s\t%s\n' "$path" "the risk policy itself is changed"
    elif [[ "$level" == "D" ]]; then
      printf 'high\t%s\t%s\n' "$path" "a policy, an agent contract, or a schema is removed"
    else
      printf 'high\t%s\t%s\n' "$path" "a policy, an agent contract, or a schema is changed"
    fi
  done < <(risk_existing_changed "$root" "$from" "$to" "${RISK_ESCALATION_DIRS[@]}")

  # An existing manifest the project names that is changed or removed.
  specs=()
  while IFS= read -r spec; do specs+=("$spec"); done < <(risk_union_values "$root" "$rules" manifests)
  if [[ "${#specs[@]}" -gt 0 ]]; then
    while IFS=$'\t' read -r level path; do
      [[ -n "$path" ]] || continue
      if [[ "$level" == "D" ]]; then
        printf 'high\t%s\t%s\n' "$path" "a dependency or toolchain manifest is removed"
      else
        printf 'high\t%s\t%s\n' "$path" "a dependency or toolchain manifest is changed"
      fi
    done < <(risk_existing_changed "$root" "$from" "$to" "${specs[@]}")
  fi
}

# risk_enumerable <root> <from> [<to>]
# Succeeds when Git can list the changes of the feature as risk_classify
# enumerates them: the diff from <from> to <to>, or to the working tree with
# its untracked files when <to> is empty.
risk_enumerable() {
  local root="$1"
  local from="$2"
  local to="${3:-}"

  if [[ -n "$to" ]]; then
    git -C "$root" diff --name-only --no-renames "$from" "$to" -- . >/dev/null 2>&1
  else
    git -C "$root" diff --name-only --no-renames "$from" -- . >/dev/null 2>&1 &&
      git -C "$root" ls-files --others --exclude-standard >/dev/null 2>&1
  fi
}

# risk_computed <root> <rules-refs> <from> [<to>]
# Prints the level that follows from the diff on the first line, and the
# reasons for exactly that level after it, one per line as '<path>: <reason>'.
# The changes are enumerated once first: when Git cannot list them (a bad
# object, an unreadable tree), the level is high, so a failing diff never
# passes as a feature that changed nothing.
risk_computed() {
  local findings
  local level

  if ! risk_enumerable "$1" "$3" "${4:-}"; then
    risk_undetermined "the changes of the feature could not be enumerated (git diff failed)"
    return 0
  fi
  findings="$(risk_classify "$@" | sort -u)"
  level="$(printf '%s\n' "$findings" | awk -F '\t' 'NF >= 3 { print $1 }' | sort -u | tr '\n' ' ')"
  # shellcheck disable=SC2086
  level="$(risk_highest $level)"
  if [[ -z "$level" ]]; then
    level="$(risk_default "$1" "$2")"
    echo "$level"
    echo "no path is changed; the default of $RISK_CONFIG is $level"
    return 0
  fi
  echo "$level"
  printf '%s\n' "$findings" | awk -F '\t' -v level="$level" '$1 == level { printf "%s: %s\n", $2, $3 }'
}

# risk_undetermined <why>
# The lines of risk_computed for a feature whose diff cannot be classified.
risk_undetermined() {
  echo "high"
  echo "$1; a feature whose changes cannot be classified is high"
}

# risk_recorded <completion-record>
# Prints what the implementer recorded as 'risk' in the completion record,
# whatever it is; nothing without a record or the field.
risk_recorded() {
  [[ -n "$1" && -f "$1" ]] || return 0
  jq -r 'if type == "object" and has("risk") then (.risk | tostring) else empty end' "$1" 2>/dev/null || true
}

# risk_claim_below <computed-lines> <completion-record>
# Succeeds when the record claims a valid level below the computed one.
risk_claim_below() {
  local computed
  local claim

  computed="$(printf '%s\n' "$1" | sed -n 1p)"
  claim="$(risk_recorded "$2")"
  risk_is_level "$claim" && [[ "$(risk_rank "$claim")" -lt "$(risk_rank "$computed")" ]]
}

# risk_decision <computed-lines> <completion-record> <review-json>
# The effective level: the computed one, raised by what the agents recorded,
# never lowered. Prints the level on the first line and every reason after
# it. <completion-record> and <review-json> may be empty or missing.
risk_decision() {
  local lines="$1"
  local record="$2"
  local review="$3"
  local computed
  local level
  local claim
  local impact
  local reasons

  computed="$(printf '%s\n' "$lines" | sed -n 1p)"
  reasons="$(printf '%s\n' "$lines" | sed 1d)"
  level="$computed"

  claim="$(risk_recorded "$record")"
  if [[ -n "$claim" ]]; then
    if ! risk_is_level "$claim"; then
      reasons+=$'\n'"the completion record claims a risk level that does not exist ($claim); it is ignored"
    elif [[ "$(risk_rank "$claim")" -gt "$(risk_rank "$level")" ]]; then
      level="$claim"
      reasons+=$'\n'"the implementer recorded risk: $claim in the completion record, above the computed $computed"
    elif [[ "$(risk_rank "$claim")" -lt "$(risk_rank "$computed")" ]]; then
      reasons+=$'\n'"the completion record claims risk: $claim, below the computed $computed; a recorded level cannot lower the computed one and is ignored"
    else
      reasons+=$'\n'"the implementer recorded risk: $claim in the completion record, the same as computed"
    fi
  fi

  if [[ -n "$review" && -f "$review" ]]; then
    impact="$(guardrails_review_level "$review")"
    case "$impact" in
      major | breaking)
        level="high"
        reasons+=$'\n'"the independent review classified the impact on the architecture as $impact"
        ;;
    esac
  fi

  echo "$level"
  printf '%s\n' "$reasons" | grep . || true
}
