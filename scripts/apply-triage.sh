#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 <triage-file> <agent> [model]"
  echo
  echo "Examples:"
  echo "  $0 .agents/triage/feature-5-rendering-review-01-triage.md codex"
  echo "  $0 .agents/triage/feature-5-rendering-review-01-triage.md claude opus"
  exit 1
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage
fi

triage_input="$1"
agent="$2"
model="${3:-}"

root="$(git rev-parse --show-toplevel)"
prompt_file="$root/.agents/prompts/triage-implementer.md"

if [[ ! -f "$triage_input" ]]; then
  echo "Error: triage artifact not found: $triage_input"
  exit 1
fi

triage_dir="$(cd "$(dirname "$triage_input")" && pwd -P)"
triage_path="$triage_dir/$(basename "$triage_input")"
triage_root="$root/.agents/triage"

if [[ "$triage_path" != "$triage_root/"*.md ]]; then
  echo "Error: triage artifact must match .agents/triage/*.md"
  echo "Received: $triage_path"
  exit 1
fi

if [[ ! -f "$prompt_file" ]]; then
  echo "Error: triage implementer prompt not found: $prompt_file"
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

approval_metadata_count="$(awk '/^Approved at:/ { count++ } END { print count + 0 }' "$triage_path")"
approval_valid_count="$(awk '
  /^Approved at: [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/ {
    count++
  }
  END {
    print count + 0
  }
' "$triage_path")"
if [[ "$approval_metadata_count" -ne 1 || "$approval_valid_count" -ne 1 ]]; then
  echo "Error: triage artifact must contain exactly one valid UTC approval timestamp."
  exit 1
fi

source_review_count="$(awk -F '\`' '/^Source review: `[^`]+`$/ { count++ } END { print count + 0 }' "$triage_path")"
if [[ "$source_review_count" -ne 1 ]]; then
  echo "Error: triage artifact must contain exactly one source review."
  exit 1
fi

source_review_relative="$(awk -F '\`' '/^Source review: `[^`]+`$/ { print $2; exit }' "$triage_path")"
source_review_candidate="$root/$source_review_relative"
if [[ ! -f "$source_review_candidate" ]]; then
  echo "Error: source review artifact not found: $source_review_relative"
  exit 1
fi

source_review_dir="$(cd "$(dirname "$source_review_candidate")" && pwd -P)"
source_review_path="$source_review_dir/$(basename "$source_review_candidate")"
if [[ "$source_review_path" != "$root/.agents/reviews/"*.md ]]; then
  echo "Error: source review must match .agents/reviews/*.md"
  exit 1
fi

source_issue_metadata_count="$(awk '/^Source feature Issue:/ { count++ } END { print count + 0 }' "$triage_path")"
source_issue_valid_count="$(awk '/^Source feature Issue: #[0-9]+[[:space:]]*$/ { count++ } END { print count + 0 }' "$triage_path")"
if [[ "$source_issue_metadata_count" -gt 1 || "$source_issue_metadata_count" -ne "$source_issue_valid_count" ]]; then
  echo "Error: triage artifact contains ambiguous source Issue metadata."
  exit 1
fi

source_issue="$(awk '
  /^Source feature Issue: #[0-9]+[[:space:]]*$/ {
    match($0, /#[0-9]+/)
    print substr($0, RSTART + 1, RLENGTH - 1)
  }
' "$triage_path")"

review_issue_metadata_count="$(awk '/^Issue:/ { count++ } END { print count + 0 }' "$source_review_path")"
review_issue_valid_count="$(awk '/^Issue:[[:space:]]*#[0-9]+[[:space:]]*$/ { count++ } END { print count + 0 }' "$source_review_path")"
if [[ "$review_issue_metadata_count" -gt 1 || "$review_issue_metadata_count" -ne "$review_issue_valid_count" ]]; then
  echo "Error: source review contains ambiguous Issue metadata."
  exit 1
fi

review_issue="$(awk '
  /^Issue:[[:space:]]*#[0-9]+[[:space:]]*$/ {
    match($0, /#[0-9]+/)
    print substr($0, RSTART + 1, RLENGTH - 1)
  }
' "$source_review_path")"

if [[ -n "$source_issue" && -n "$review_issue" && "$source_issue" != "$review_issue" ]]; then
  echo "Error: triage and review artifacts reference different source Issues."
  exit 1
fi
if [[ -z "$source_issue" ]]; then
  source_issue="$review_issue"
fi

branch="$(git branch --show-current)"
if [[ "$branch" != feature/* ]]; then
  echo "Error: apply-triage.sh must run in an existing feature worktree."
  echo "Current branch: $branch"
  exit 1
fi

if [[ -z "$source_issue" && "$branch" =~ ^feature/([0-9]+)- ]]; then
  source_issue="${BASH_REMATCH[1]}"
fi

if [[ -n "$source_issue" && "$branch" != feature/${source_issue}-* ]]; then
  echo "Error: current branch does not match source Issue #$source_issue."
  echo "Current branch: $branch"
  exit 1
fi

if [[ -n "$source_issue" ]]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "Error: GitHub CLI 'gh' is not installed."
    exit 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    echo "Error: GitHub CLI is not authenticated."
    echo "Run: gh auth login"
    exit 1
  fi
  resolved_issue="$(gh issue view "$source_issue" --json number --template '{{.number}}')"
  if [[ "$resolved_issue" != "$source_issue" ]]; then
    echo "Error: could not validate source Issue #$source_issue."
    exit 1
  fi
fi

tmp_work="$(mktemp -d "${TMPDIR:-/tmp}/apply-triage.XXXXXX")"
trap 'rm -rf "$tmp_work"' EXIT
fix_scope_file="$tmp_work/fix-now.md"
fix_count_file="$tmp_work/fix-count"
review_findings_file="$tmp_work/review-findings.txt"
: >"$fix_scope_file"

awk '
  function trim(value) {
    sub(/^[[:space:]]+/, "", value)
    sub(/[[:space:]]+$/, "", value)
    return value
  }

  function singular(value) {
    return value == "Suggestions" ? "Suggestion" : value
  }

  function emit_finding(severity, raw,    id, title, token, rest, count, parts) {
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
    print id ". " title
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
  /^##[[:space:]]+/ {
    section = ""
    next
  }
  section != "" && /^###[[:space:]]+/ {
    value = $0
    sub(/^###[[:space:]]+/, "", value)
    entries++
    entry_section[entries] = section
    entry_type[entries] = "heading"
    entry_value[entries] = value
    headings[section]++
    next
  }
  section != "" && /^-[[:space:]]+/ {
    value = $0
    sub(/^-[[:space:]]+/, "", value)
    entries++
    entry_section[entries] = section
    entry_type[entries] = "bullet"
    entry_value[entries] = value
  }
  END {
    for (i = 1; i <= entries; i++) {
      section = entry_section[i]
      if (entry_type[i] == "heading" || (entry_type[i] == "bullet" && headings[section] == 0)) {
        emit_finding(section, entry_value[i])
      }
    }
  }
' "$source_review_path" >"$review_findings_file"

if ! awk -v output="$fix_scope_file" -v count_output="$fix_count_file" -v review_findings="$review_findings_file" '
  BEGIN {
    while ((getline source_heading < review_findings) > 0) {
      source_headings[source_heading]++
    }
    close(review_findings)
  }

  function expected_decision(value) {
    if (value == "fix") {
      return "FIX_NOW"
    }
    if (value == "defer") {
      return "DEFER"
    }
    if (value == "accept") {
      return "ACCEPT"
    }
    return ""
  }

  function finish_finding(    expected) {
    if (!in_finding) {
      return
    }

    expected = expected_decision(section)
    if (decision_count != 1) {
      printf "Error: finding %s must contain exactly one Decision field.\n", finding_id > "/dev/stderr"
      invalid = 1
    } else if (decision != expected) {
      printf "Error: finding %s is under the wrong decision section.\n", finding_id > "/dev/stderr"
      invalid = 1
    }

    if (seen[finding_id]++) {
      printf "Error: duplicate triage finding identifier: %s\n", finding_id > "/dev/stderr"
      invalid = 1
    }

    if (source_headings[finding_heading] != 1) {
      printf "Error: triage finding does not map uniquely to the source review: %s\n", finding_heading > "/dev/stderr"
      invalid = 1
    }

    if (section == "fix") {
      printf "%s", block > output
      fix_count++
    }

    in_finding = 0
    finding_id = ""
    finding_heading = ""
    decision = ""
    decision_count = 0
    block = ""
  }

  /^## Fix now[[:space:]]*$/ {
    finish_finding()
    section = "fix"
    section_count[section]++
    next
  }
  /^## Deferred[[:space:]]*$/ {
    finish_finding()
    section = "defer"
    section_count[section]++
    next
  }
  /^## Accepted[[:space:]]*$/ {
    finish_finding()
    section = "accept"
    section_count[section]++
    next
  }
  /^## Traceability[[:space:]]*$/ {
    finish_finding()
    section = "trace"
    section_count[section]++
    next
  }
  /^##[[:space:]]+/ {
    finish_finding()
    section = ""
    next
  }

  /^###[[:space:]]+/ {
    finish_finding()
    if (section != "fix" && section != "defer" && section != "accept") {
      print "Error: finding heading appears outside a triage decision section." > "/dev/stderr"
      invalid = 1
      next
    }

    heading = $0
    sub(/^###[[:space:]]+/, "", heading)
    separator = index(heading, ". ")
    if (separator == 0) {
      printf "Error: malformed finding heading: %s\n", $0 > "/dev/stderr"
      invalid = 1
      next
    }

    finding_id = substr(heading, 1, separator - 1)
    finding_heading = heading
    in_finding = 1
    block = $0 "\n"
    next
  }

  in_finding {
    block = block $0 "\n"
    if ($0 ~ /^- Decision: /) {
      decision = $0
      sub(/^- Decision: /, "", decision)
      decision_count++
    }
  }

  END {
    finish_finding()

    required[1] = "fix"
    required[2] = "defer"
    required[3] = "accept"
    required[4] = "trace"
    for (i = 1; i <= 4; i++) {
      name = required[i]
      if (section_count[name] != 1) {
        printf "Error: triage artifact must contain exactly one %s section.\n", name > "/dev/stderr"
        invalid = 1
      }
    }

    close(output)
    print fix_count + 0 > count_output
    close(count_output)
    if (invalid) {
      exit 1
    }
  }
' "$triage_path"; then
  echo "Error: malformed or ambiguous triage artifact."
  exit 1
fi

fix_count="$(<"$fix_count_file")"
if [[ "$fix_count" -eq 0 ]]; then
  echo "No FIX_NOW findings found; no implementation agent was started."
  exit 0
fi

triage_relative="${triage_path#"$root"/}"
fix_scope="$(<"$fix_scope_file")"

echo "Approved FIX_NOW scope from $triage_relative:"
echo
printf '%s\n' "$fix_scope"
echo "Findings to resolve: $fix_count"
echo
printf "Start a write-capable $agent agent for this scope? [y/N] "
read -r approval
case "$approval" in
  y | Y | yes | YES) ;;
  *)
    echo "Apply triage declined; no implementation agent was started."
    exit 0
    ;;
esac

start_prompt="Read and follow .agents/prompts/triage-implementer.md.

Source feature Issue: ${source_issue:-unknown}
Source review artifact: ${source_review_relative}
Approved triage artifact: ${triage_relative}

Resolve exactly these approved FIX_NOW findings:

${fix_scope}

Do not implement any DEFER or ACCEPT finding.
Do not commit, push, merge, deploy, or create/close Issues."

file_signature() {
  local path="$1"
  local mode
  local content_hash
  if [[ ! -e "$path" ]]; then
    echo "MISSING"
    return
  fi
  if [[ "$(uname -s)" == "Darwin" ]]; then
    if ! mode="$(stat -f '%Lp' "$path" 2>/dev/null)"; then
      mode="UNREADABLE"
    fi
  else
    if ! mode="$(stat -c '%a' "$path" 2>/dev/null)"; then
      mode="UNREADABLE"
    fi
  fi
  if ! content_hash="$(git hash-object "$path" 2>/dev/null)"; then
    content_hash="UNREADABLE"
  fi
  printf '%s:%s\n' "$content_hash" "$mode"
}

review_signature_before="$(file_signature "$source_review_path")"
triage_signature_before="$(file_signature "$triage_path")"

echo
echo "Starting $agent implementation agent..."
echo

set +e
case "$agent" in
  codex)
    codex_args=(
      --sandbox workspace-write
      --ask-for-approval never
    )
    if [[ -n "$model" ]]; then
      codex_args+=(--model "$model")
    fi
    (
      cd "$root"
      codex "${codex_args[@]}" "$start_prompt"
    )
    agent_status=$?
    ;;
  claude)
    claude_args=(
      --permission-mode acceptEdits
    )
    if [[ -n "$model" ]]; then
      claude_args+=(--model "$model")
    fi
    (
      cd "$root"
      claude "${claude_args[@]}" "$start_prompt"
    )
    agent_status=$?
    ;;
esac
set -e

review_signature_after="$(file_signature "$source_review_path")"
triage_signature_after="$(file_signature "$triage_path")"

protected_artifact_changed=0
if [[ "$review_signature_before" != "$review_signature_after" ]]; then
  echo "Error: implementation agent modified the source review artifact."
  protected_artifact_changed=1
fi

if [[ "$triage_signature_before" != "$triage_signature_after" ]]; then
  echo "Error: implementation agent modified the approved triage artifact."
  protected_artifact_changed=1
fi

echo
echo "Running repository verification..."
set +e
(
  cd "$root"
  ./scripts/verify.sh
)
verification_status=$?
set -e

if [[ "$protected_artifact_changed" -ne 0 ]]; then
  exit 1
fi

if [[ "$agent_status" -ne 0 ]]; then
  echo "Error: implementation agent exited with status $agent_status."
  if [[ "$verification_status" -ne 0 ]]; then
    echo "Repository verification also failed with status $verification_status."
  fi
  exit "$agent_status"
fi

if [[ "$verification_status" -ne 0 ]]; then
  echo "Error: repository verification failed with status $verification_status."
  exit "$verification_status"
fi

echo
echo "FIX_NOW implementation completed and verification passed."
echo "Inspect the diff, then run a new independent review and triage when needed."
