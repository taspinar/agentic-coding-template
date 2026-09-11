#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 <review-file> <agent> [model]"
  echo
  echo "Examples:"
  echo "  $0 .agents/reviews/feature-5-rendering-review-01.md claude"
  echo "  $0 .agents/reviews/feature-5-rendering-review-01.md codex gpt-5.6"
  exit 1
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage
fi

review_input="$1"
agent="$2"
model="${3:-}"

root="$(git rev-parse --show-toplevel)"
prompt_file="$root/.agents/prompts/triage-reviewer.md"

if [[ ! -f "$review_input" ]]; then
  echo "Error: review artifact not found: $review_input"
  exit 1
fi

review_dir="$(cd "$(dirname "$review_input")" && pwd -P)"
review_path="$review_dir/$(basename "$review_input")"
reviews_root="$root/.agents/reviews"

if [[ "$review_path" != "$reviews_root/"*.md ]]; then
  echo "Error: review artifact must match .agents/reviews/*.md"
  echo "Received: $review_path"
  exit 1
fi

if [[ ! -f "$prompt_file" ]]; then
  echo "Error: triage prompt not found: $prompt_file"
  exit 1
fi

case "$agent" in
  codex | claude) ;;
  *)
    echo "Error: unsupported agent '$agent'"
    echo "Supported agents: codex, claude"
    exit 1
    ;;
esac

if ! command -v "$agent" >/dev/null 2>&1; then
  echo "Error: '$agent' command not found."
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: GitHub CLI 'gh' is not installed."
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "Error: GitHub CLI is not authenticated."
  echo "Run: gh auth login"
  exit 1
fi

tmp_work="$(mktemp -d "${TMPDIR:-/tmp}/triage-review.XXXXXX")"
trap 'rm -rf "$tmp_work"' EXIT

findings_file="$tmp_work/findings.tsv"
decisions_file="$tmp_work/decisions.tsv"
followup_titles_file="$tmp_work/followup-titles.tsv"
mapping_file="$tmp_work/mappings.tsv"
: >"$followup_titles_file"
: >"$mapping_file"

if ! awk -v output="$findings_file" '
  function trim(value) {
    sub(/^[[:space:]]+/, "", value)
    sub(/[[:space:]]+$/, "", value)
    return value
  }

  function singular(value) {
    return value == "Suggestions" ? "Suggestion" : value
  }

  function emit_finding(severity, raw, line_number, source_type,    id, title, token, rest, count, parts) {
    raw = trim(raw)
    ordinal[severity]++
    id = singular(severity) "-" ordinal[severity]
    title = raw

    if (raw ~ /^(Critical|Major|Minor|Suggestion)[[:space:]]+[0-9]+[.):-]?([[:space:]]+|$)/) {
      count = split(raw, parts, /[[:space:]]+/)
      token = parts[2]
      gsub(/[.):-]+$/, "", token)
      id = parts[1] " " token
      rest = raw
      sub(/^(Critical|Major|Minor|Suggestion)[[:space:]]+[0-9]+[.):-]?[[:space:]]*/, "", rest)
      title = trim(rest)
    } else if (raw ~ /^[CMS][0-9]+[.):-]?([[:space:]]+|$)/) {
      token = raw
      sub(/[[:space:]].*$/, "", token)
      gsub(/[.):-]+$/, "", token)
      id = token
      rest = raw
      sub(/^[CMS][0-9]+[.):-]?[[:space:]]*/, "", rest)
      title = trim(rest)
    }

    if (title == "") {
      title = raw
    }

    gsub(/\t/, " ", id)
    gsub(/\t/, " ", title)
    total++
    printf "F%03d\t%s\t%s\t%s\t%d\t%s\n", total, severity, id, title, line_number, source_type > output
  }

  /^## Critical[[:space:]]*$/ {
    section = "Critical"
    next
  }
  /^## Major[[:space:]]*$/ {
    section = "Major"
    next
  }
  /^## Minor[[:space:]]*$/ {
    section = "Minor"
    next
  }
  /^## Suggestions[[:space:]]*$/ {
    section = "Suggestions"
    next
  }
  /^## Verdict[[:space:]]*$/ {
    section = ""
    next
  }
  /^##[[:space:]]+/ {
    section = ""
    next
  }

  section != "" {
    value = trim($0)

    if ($0 ~ /^###[[:space:]]+/) {
      raw = $0
      sub(/^###[[:space:]]+/, "", raw)
      entries++
      entry_section[entries] = section
      entry_type[entries] = "heading"
      entry_text[entries] = raw
      entry_line[entries] = NR
      headings[section]++
      next
    }

    if ($0 ~ /^-[[:space:]]+/) {
      raw = $0
      sub(/^-[[:space:]]+/, "", raw)
      entries++
      entry_section[entries] = section
      entry_type[entries] = "bullet"
      entry_text[entries] = raw
      entry_line[entries] = NR
      bullets[section]++
      next
    }

    lower = tolower(value)
    empty_section = (lower == "none" || lower == "none." || lower == "none identified" || lower == "none identified." || lower == "no findings" || lower == "no findings." || lower ~ /^no (critical|major|minor|suggestion|suggestions)( findings?)?[.]?$/)
    if (value != "" && value !~ /^<!--/ && !empty_section) {
      meaningful[section]++
    }
  }

  END {
    severities[1] = "Critical"
    severities[2] = "Major"
    severities[3] = "Minor"
    severities[4] = "Suggestions"

    for (i = 1; i <= entries; i++) {
      severity = entry_section[i]
      if (entry_type[i] == "heading" || (entry_type[i] == "bullet" && headings[severity] == 0)) {
        emit_finding(severity, entry_text[i], entry_line[i], entry_type[i])
      }
    }

    for (i = 1; i <= 4; i++) {
      severity = severities[i]
      if (headings[severity] == 0 && bullets[severity] == 0 && meaningful[severity] > 0) {
        printf "Error: unstructured content in review section %s; use ### headings or bullet findings.\n", severity > "/dev/stderr"
        invalid = 1
      }
    }

    close(output)
    if (invalid) {
      exit 2
    }
  }
' "$review_path"; then
  rm -f "$findings_file"
  exit 1
fi

source_issue="$(awk '
  /^Issue:[[:space:]]*#[0-9]+/ {
    if (match($0, /#[0-9]+/)) {
      value = substr($0, RSTART + 1, RLENGTH - 1)
      print value
      exit
    }
  }
' "$review_path")"

if [[ -z "$source_issue" ]]; then
  branch="$(git branch --show-current)"
  if [[ "$branch" =~ ^feature/([0-9]+)- ]]; then
    source_issue="${BASH_REMATCH[1]}"
  fi
fi

source_issue_context="Not available."
source_issue_title=""
feature_ref=""
if [[ -n "$source_issue" ]]; then
  source_issue_context="$(gh issue view "$source_issue" \
    --json title,body \
    --template 'Title: {{.title}}{{"\n\n"}}{{.body}}')"
  source_issue_title="${source_issue_context%%$'\n'*}"
  source_issue_title="${source_issue_title#Title: }"
  if [[ "$source_issue_title" =~ (^|[^[:alnum:]])(F[0-9]+)([^[:alnum:]]|$) ]]; then
    feature_ref="${BASH_REMATCH[2]}"
  fi
fi

reviewer_verdict="$(awk '
  /^## Verdict[[:space:]]*$/ {
    in_verdict = 1
    next
  }
  in_verdict && /^##[[:space:]]+/ {
    exit
  }
  in_verdict && $0 !~ /^[[:space:]]*$/ {
    print
    exit
  }
' "$review_path")"
reviewer_verdict="${reviewer_verdict:-Not recorded}"

review_relative="${review_path#"$root"/}"
review_stem="$(basename "$review_path" .md)"
review_ref=""
if [[ "$review_stem" =~ review-([0-9]+) ]]; then
  printf -v review_ref 'R%02d' "$((10#${BASH_REMATCH[1]}))"
fi
findings_manifest="$(<"$findings_file")"
if [[ -z "$findings_manifest" ]]; then
  findings_manifest="(empty)"
fi

start_prompt="Read and follow .agents/prompts/triage-reviewer.md.

Source review artifact: ${review_relative}
Source feature Issue: ${source_issue:-unknown}
Source feature Issue context:
${source_issue_context}

Findings manifest (key, severity, identifier, title, source line, source type):
${findings_manifest}

Classify exactly these entries and return only the required TSV records."

review_hash_before="$(git hash-object "$review_path")"
status_before="$(git status --porcelain=v1 --untracked-files=all)"

echo "Starting independent review triage:"
echo "  Review: $review_relative"
echo "  Agent:  $agent"
if [[ -n "$model" ]]; then
  echo "  Model:  $model"
else
  echo "  Model:  default"
fi
echo

case "$agent" in
  codex)
    codex_args=(
      exec
      --sandbox read-only
      --ephemeral
      --color never
      --cd "$root"
      --output-last-message "$decisions_file"
    )
    if [[ -n "$model" ]]; then
      codex_args+=(--model "$model")
    fi
    codex "${codex_args[@]}" "$start_prompt" >/dev/null
    ;;
  claude)
    claude_args=(
      --print
      --permission-mode plan
      --tools "Read,Glob,Grep"
      --no-session-persistence
    )
    if [[ -n "$model" ]]; then
      claude_args+=(--model "$model")
    fi
    (
      cd "$root"
      claude "${claude_args[@]}" "$start_prompt"
    ) >"$decisions_file"
    ;;
esac

review_hash_after="$(git hash-object "$review_path")"
status_after="$(git status --porcelain=v1 --untracked-files=all)"

if [[ "$review_hash_before" != "$review_hash_after" ]]; then
  echo "Error: triage agent modified the source review artifact."
  exit 1
fi

if [[ "$status_before" != "$status_after" ]]; then
  echo "Error: triage agent modified the working tree."
  git status --short
  exit 1
fi

if ! awk -F '\t' '
  FILENAME == ARGV[1] {
    keys[++finding_count] = $1
    severity[$1] = $2
    known[$1] = 1
    next
  }

  $0 == "NO_FINDINGS" {
    if (finding_count != 0 || NR != 1) {
      print "Error: unexpected NO_FINDINGS output." > "/dev/stderr"
      invalid = 1
    }
    no_findings = 1
    next
  }

  {
    if (NF != 6) {
      printf "Error: triage record must have six tab-separated fields: %s\n", $0 > "/dev/stderr"
      invalid = 1
      next
    }

    key = $1
    decision = $2
    if (!known[key]) {
      printf "Error: triage output contains unknown finding key %s.\n", key > "/dev/stderr"
      invalid = 1
    }
    if (seen[key]++) {
      printf "Error: finding key %s was classified more than once.\n", key > "/dev/stderr"
      invalid = 1
    }
    if (decision != "FIX_NOW" && decision != "DEFER" && decision != "ACCEPT") {
      printf "Error: invalid triage decision for %s: %s\n", key, decision > "/dev/stderr"
      invalid = 1
    }
    if ((severity[key] == "Critical" || severity[key] == "Major") && decision != "FIX_NOW") {
      printf "Error: %s finding %s must be FIX_NOW.\n", severity[key], key > "/dev/stderr"
      invalid = 1
    }
    if ($3 == "" || $3 == "-") {
      printf "Error: finding %s requires a rationale.\n", key > "/dev/stderr"
      invalid = 1
    }
    if (decision == "DEFER" && ($4 == "" || $4 == "-" || $5 == "" || $5 == "-" || $6 == "" || $6 == "-")) {
      printf "Error: deferred finding %s requires an issue title, action, and acceptance criteria.\n", key > "/dev/stderr"
      invalid = 1
    }
    if (decision != "DEFER" && ($4 != "-" || $5 != "-" || $6 != "-")) {
      printf "Error: non-deferred finding %s must use dashes for follow-up fields.\n", key > "/dev/stderr"
      invalid = 1
    }
  }

  END {
    if (finding_count == 0 && !no_findings) {
      print "Error: expected NO_FINDINGS for an empty review." > "/dev/stderr"
      invalid = 1
    }
    if (finding_count > 0 && no_findings) {
      invalid = 1
    }
    for (i = 1; i <= finding_count; i++) {
      if (!seen[keys[i]]) {
        printf "Error: finding %s was not classified.\n", keys[i] > "/dev/stderr"
        invalid = 1
      }
    }
    if (invalid) {
      exit 1
    }
  }
' "$findings_file" "$decisions_file"; then
  echo "Error: triage agent returned an invalid decision manifest."
  exit 1
fi

while IFS=$'\t' read -r key decision rationale proposed_issue_title recommended_action acceptance_criteria; do
  [[ "$decision" == "DEFER" ]] || continue

  finding_id="$(awk -F '\t' -v wanted="$key" '$1 == wanted { print $3; exit }' "$findings_file")"
  finding_ref="${finding_id// /-}"
  if [[ "$finding_id" =~ ^Suggestion[[:space:]]+([0-9]+)$ ]]; then
    finding_ref="S${BASH_REMATCH[1]}"
  elif [[ "$finding_id" =~ ^Critical[[:space:]]+([0-9]+)$ ]]; then
    finding_ref="C${BASH_REMATCH[1]}"
  elif [[ "$finding_id" =~ ^Major[[:space:]]+([0-9]+)$ ]]; then
    finding_ref="M${BASH_REMATCH[1]}"
  elif [[ "$finding_id" =~ ^Minor[[:space:]]+([0-9]+)$ ]]; then
    finding_ref="Minor-${BASH_REMATCH[1]}"
  fi

  prefixed_issue_title=""
  if [[ -n "$feature_ref" ]]; then
    prefixed_issue_title="[$feature_ref]"
  elif [[ -n "$source_issue" ]]; then
    prefixed_issue_title="[#$source_issue]"
  fi
  if [[ -n "$review_ref" ]]; then
    prefixed_issue_title+="[$review_ref]"
  fi
  prefixed_issue_title+="[$finding_ref] $proposed_issue_title"

  printf '%s\t%s\n' "$key" "$prefixed_issue_title" >>"$followup_titles_file"
done <"$decisions_file"

render_proposal() {
  awk -F '\t' '
    FILENAME == ARGV[1] {
      id[$1] = $3
      title[$1] = $4
      next
    }
    FILENAME == ARGV[3] {
      followup_title[$1] = $2
      next
    }
    $0 == "NO_FINDINGS" {
      next
    }
    {
      count[$2]++
      key[$2, count[$2]] = $1
      rationale[$1] = $3
    }
    END {
      groups[1] = "FIX_NOW"
      groups[2] = "DEFER"
      groups[3] = "ACCEPT"
      for (g = 1; g <= 3; g++) {
        group = groups[g]
        print group
        if (count[group] == 0) {
          print "- (none)"
        } else {
          for (i = 1; i <= count[group]; i++) {
            finding_key = key[group, i]
            printf "- %s %s — %s\n", id[finding_key], title[finding_key], rationale[finding_key]
            if (group == "DEFER") {
              printf "  Follow-up Issue: %s\n", followup_title[finding_key]
            }
          }
        }
        print ""
      }
    }
  ' "$findings_file" "$decisions_file" "$followup_titles_file"
}

echo
echo "Proposed triage:"
echo
render_proposal

deferred_count="$(awk -F '\t' '$2 == "DEFER" { count++ } END { print count + 0 }' "$decisions_file")"
if [[ "$deferred_count" -gt 0 ]]; then
  echo "Approval will create $deferred_count follow-up GitHub issue(s)."
fi

printf "Proceed with this triage? [y/N] "
read -r approval
case "$approval" in
  y | Y | yes | YES) ;;
  *)
    echo "Triage declined; no artifact or GitHub issues were created."
    exit 0
    ;;
esac

triage_dir="$root/.agents/triage"
mkdir -p "$triage_dir"
artifact="$triage_dir/${review_stem}-triage.md"
artifact_number=2
while [[ -e "$artifact" ]]; do
  artifact="$triage_dir/${review_stem}-triage-$(printf '%02d' "$artifact_number").md"
  artifact_number=$((artifact_number + 1))
done
artifact_relative="${artifact#"$root"/}"

{
  echo "# Review Triage — $review_stem"
  echo
  echo "Source review: \`$review_relative\`"
  if [[ -n "$source_issue" ]]; then
    echo
    echo "Source feature Issue: #$source_issue"
  fi
  echo
  echo "Reviewer verdict: $reviewer_verdict"
  echo
  echo "Triage agent: $agent"
  if [[ -n "$model" ]]; then
    echo
    echo "Triage model: $model"
  fi
  echo
  echo "Approved at: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo
} >"$artifact"

append_artifact_group() {
  local decision="$1"
  local heading="$2"

  {
    echo "## $heading"
    echo
    awk -F '\t' -v wanted="$decision" '
      FILENAME == ARGV[1] {
        severity[$1] = $2
        id[$1] = $3
        title[$1] = $4
        line[$1] = $5
        next
      }
      FILENAME == ARGV[3] {
        followup_title[$1] = $2
        next
      }
      $0 == "NO_FINDINGS" {
        next
      }
      $2 == wanted {
        found = 1
        printf "### %s. %s\n\n", id[$1], title[$1]
        printf "- Severity: %s\n", severity[$1]
        printf "- Decision: %s\n", $2
        printf "- Source line: %s\n", line[$1]
        printf "- Rationale: %s\n", $3
        if ($2 == "DEFER") {
          printf "- Proposed Issue: %s\n", followup_title[$1]
          printf "- Recommended action: %s\n", $5
          printf "- Acceptance criteria: %s\n", $6
          print "- Created Issue: see Traceability"
        }
        print ""
      }
      END {
        if (!found) {
          print "None."
          print ""
        }
      }
    ' "$findings_file" "$decisions_file" "$followup_titles_file"
  } >>"$artifact"
}

append_artifact_group "FIX_NOW" "Fix now"
append_artifact_group "DEFER" "Deferred"
append_artifact_group "ACCEPT" "Accepted"

{
  echo "## Traceability"
  echo
} >>"$artifact"

while IFS=$'\t' read -r key decision rationale proposed_issue_title recommended_action acceptance_criteria; do
  [[ "$decision" == "DEFER" ]] || continue

  issue_title="$(awk -F '\t' -v wanted="$key" '$1 == wanted { print $2; exit }' "$followup_titles_file")"
  finding_record="$(awk -F '\t' -v wanted="$key" '$1 == wanted { print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6; exit }' "$findings_file")"
  IFS=$'\t' read -r severity finding_id finding_title source_line source_type <<<"$finding_record"
  trace_token="triage-source:${review_relative}#${key}"

  existing_issue_url=""
  shopt -s nullglob
  for previous_artifact in "$triage_dir/${review_stem}-triage"*.md; do
    existing_issue_url="$(awk -v prefix="- $finding_id → [#" '
      index($0, prefix) == 1 && match($0, /\(https:\/\/[^)]+\)/) {
        print substr($0, RSTART + 1, RLENGTH - 2)
        exit
      }
    ' "$previous_artifact")"
    [[ -z "$existing_issue_url" ]] || break
  done
  shopt -u nullglob

  if [[ -z "$existing_issue_url" ]]; then
    existing_issue_url="$(gh issue list \
      --state all \
      --limit 100 \
      --search "\"$trace_token\" in:body" \
      --json url \
      --jq '.[0].url // empty')"
  fi

  if [[ -n "$existing_issue_url" ]]; then
    issue_number="${existing_issue_url##*/}"
    if [[ ! "$issue_number" =~ ^[0-9]+$ ]]; then
      echo "Error: could not determine existing Issue number from: $existing_issue_url"
      exit 1
    fi
    printf '%s\t%s\t%s\n' "$finding_id" "$issue_number" "$existing_issue_url" >>"$mapping_file"
    echo "- $finding_id → [#$issue_number]($existing_issue_url)" >>"$artifact"
    echo "Reusing existing follow-up Issue #$issue_number for $finding_id."
    continue
  fi

  finding_excerpt="$(awk -v start="$source_line" -v source_type="$source_type" '
    NR < start {
      next
    }
    NR > start && ($0 ~ /^###[[:space:]]+/ || $0 ~ /^##[[:space:]]+/) {
      exit
    }
    NR > start && source_type == "bullet" && $0 ~ /^-[[:space:]]+/ {
      exit
    }
    {
      print
    }
  ' "$review_path")"

  issue_body_file="$tmp_work/${key}-issue.md"
  {
    echo "<!-- $trace_token -->"
    echo
    echo "# $issue_title"
    echo
    echo "## Context"
    echo
    if [[ -n "$source_issue" ]]; then
      echo "Deferred finding from the independent review of Issue #$source_issue."
    else
      echo "Deferred finding from an independent review."
    fi
    echo
    echo "Original finding: $finding_id"
    echo
    echo "## Finding"
    echo
    echo "$finding_excerpt"
    echo
    echo "## Evidence"
    echo
    echo "See \`$review_relative\`, line $source_line ($severity)."
    echo
    echo "## Why it matters"
    echo
    echo "$rationale"
    echo
    echo "## Recommended action"
    echo
    echo "$recommended_action"
    echo
    echo "## Acceptance criteria"
    echo
    echo "- $acceptance_criteria"
    echo "- \`./scripts/verify.sh\` passes."
  } >"$issue_body_file"

  echo "Creating follow-up Issue for $finding_id..."
  issue_url="$(gh issue create --title "$issue_title" --body-file "$issue_body_file")"
  issue_number="${issue_url##*/}"
  if [[ ! "$issue_number" =~ ^[0-9]+$ ]]; then
    echo "Error: could not determine Issue number from: $issue_url"
    exit 1
  fi

  printf '%s\t%s\t%s\n' "$finding_id" "$issue_number" "$issue_url" >>"$mapping_file"
  echo "- $finding_id → [#$issue_number]($issue_url)" >>"$artifact"
done <"$decisions_file"

if [[ ! -s "$mapping_file" ]]; then
  echo "No follow-up Issues created." >>"$artifact"
fi

echo
echo "Triage completed:"
echo "  Artifact: $artifact_relative"
echo
render_proposal

if [[ -s "$mapping_file" ]]; then
  echo "Deferred Issue mappings:"
  awk -F '\t' '{ printf "- %s → #%s\n", $1, $2 }' "$mapping_file"
fi
