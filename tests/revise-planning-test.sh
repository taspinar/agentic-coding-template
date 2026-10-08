#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/revise-planning-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "revise-planning test failed: $*" >&2
  exit 1
}

source "$source_root/tests/lib-fakes.sh"
make_fake_agents "$tmp/bin"

review=".agents/reviews/planning-project-bootstrap-review-01.json"
revision=".agents/reviews/planning-project-bootstrap-review-01-revision"
valid_decisions='{"decisions": [
  {"finding_id": "M1", "decision": "ADOPT", "rationale": "Offline use is an MVP requirement."},
  {"finding_id": "MIN1", "decision": "REJECT", "rationale": "The name follows the requirements."},
  {"finding_id": "S1", "decision": "ESCALATE", "rationale": "Sharing scope is a product decision."}
]}'
export MOCK_OUTPUT="$valid_decisions"

# Creates a planning repository with a current planning review of round 1.
setup_repo() {
  local repo="$tmp/$1"

  mkdir -p "$repo/docs/decisions" "$repo/.agents/reviews"
  copy_workflow "$repo"
  printf 'project-planner: claude model-p\n' >"$repo/.agents/agents.conf"
  printf '# Agents\n' >"$repo/AGENTS.md"
  printf '# Project Requirements\n\nStatus: Approved\nApproved at: 2026-01-01T00:00:00Z\n\n## MVP scope\n\nOffline recipes.\n' \
    >"$repo/docs/PROJECT_REQUIREMENTS.md"
  printf '# Architecture\n\nLocal storage.\n' >"$repo/docs/architecture.md"
  printf '# Roadmap\n\n## F01 — Recipes\n\n- Goal: list recipes.\n' >"$repo/docs/roadmap.md"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.name "Revise Test"
  git -C "$repo" config user.email "revise-test@example.com"
  git -C "$repo" add .
  git -C "$repo" commit -qm "Seed"
  git -C "$repo" switch -q -c planning/project-bootstrap

  jq -n '{
    schema: "review/v1", kind: "planning", issue: null, round: 1,
    branch: "planning/project-bootstrap", base: "origin/main", merge_base: "aaaa", head: "bbbb",
    reviewed_tree: "", reviewed_paths: ["docs/PROJECT_DESCRIPTION.md", "docs/changes", "docs/PROJECT_REQUIREMENTS.md", "docs/architecture.md", "docs/roadmap.md", "docs/decisions"],
    reviewer: {agent: "codex", model: "model-r"}, created_at: "2026-01-01T00:00:00Z",
    verdict: "CHANGES_REQUIRED", limitations: "",
    findings: [
      {id: "M1", severity: "major", title: "Offline use is unplanned", evidence: "docs/roadmap.md", impact: "An MVP requirement is missing.", recommendation: "Add a feature for offline use."},
      {id: "MIN1", severity: "minor", title: "Feature name is vague", evidence: "docs/roadmap.md, F01", impact: "Readability.", recommendation: "Rename F01."},
      {id: "S1", severity: "suggestion", title: "Consider sharing", evidence: "docs/roadmap.md", impact: "Households share recipes.", recommendation: "Add sharing."}
    ]
  }' >"$repo/$review"
  record_reviewed_tree "$repo" "$repo/$review"

  printf '%s\n' "$repo"
}

run_revise() {
  local repo="$1"
  local answer="$2"
  shift 2

  (
    cd "$repo"
    printf '%s\n' "$answer" |
      PATH="$tmp/bin:/usr/bin:/bin" MOCK_AGENT_LOG="$repo.log" ./scripts/revise-planning.sh "$@"
  ) >"$repo.out" 2>&1
}

write_sessions() {
  grep -c -- "--permission-mode acceptEdits" "$1.log" 2>/dev/null || true
}

add_offline_feature="printf '\\n## F02 — Offline use\\n\\n- Goal: work offline.\\n' >>docs/roadmap.md"

# The planner decides read-only; after approval the decisions are recorded and
# a write session revises exactly the adopted findings.
repo="$(setup_repo revise)"
MOCK_WRITE_ACTION="$add_offline_feature" run_revise "$repo" y --review "$review" || {
  cat "$repo.out" >&2
  fail "revising the planning failed"
}
[[ -f "$repo/$revision.json" && -f "$repo/$revision.md" ]] || fail "the revision and its report were not recorded"
[[ "$(jq -c '[.schema, .review_round, (.decisions | map(.decision))]' "$repo/$revision.json")" == \
  '["revision/v1",1,["ADOPT","REJECT","ESCALATE"]]' ]] || fail "the recorded decisions are wrong"
grep -Fq -- "--tools Read,Glob,Grep" "$repo.log" || fail "the planner did not decide read-only"
grep -Fq -- "--json-schema" "$repo.log" || fail "the planner was not given the revision schema"
[[ "$(write_sessions "$repo")" -eq 1 ]] || fail "exactly one write session was expected"
grep -Fq "M1. Offline use is unplanned" "$repo.log" || fail "the adopted finding was not passed to the planner"
if grep -Fq "Feature name is vague" "$repo.log" || grep -Fq "Consider sharing" "$repo.log"; then
  fail "a finding that was not adopted was passed to the write session"
fi
grep -Fq "F02 — Offline use" "$repo/docs/roadmap.md" || fail "the revision did not reach the roadmap"
grep -Fq "Escalated findings need your decision" "$repo.out" || fail "the escalated finding was not reported"
status=0
(cd "$repo" && ./scripts/check-review.sh "$review" >/dev/null) || status=$?
[[ "$status" -eq 1 ]] || fail "the planning review is not stale after the revision"

# A revised review cannot be revised again; the next step is a new review.
if run_revise "$repo" y --review "$review"; then
  fail "an already revised review was revised again"
fi
grep -Fq "review-planning.sh" "$repo.out" || fail "the next review round was not suggested"

# A revision is decided by you, so it cannot run unattended.
repo="$(setup_repo unattended)"
if run_revise "$repo" y --review "$review" --unattended; then fail "a revision ran unattended"; fi
grep -Fq "cannot run with --unattended" "$repo.out" || fail "the refusal of an unattended revision gave no reason"
[[ ! -e "$repo.log" ]] || fail "an agent started for an unattended revision"

# Declining records nothing and changes nothing.
repo="$(setup_repo decline)"
run_revise "$repo" n --review "$review" || fail "declining returned an error"
[[ ! -e "$repo/$revision.json" ]] || fail "declined decisions were recorded"
[[ "$(write_sessions "$repo")" -eq 0 ]] || fail "a write session started after declining"

# Invalid decisions are retried once and then rejected before anything is recorded.
# One invalid result per rule, each derived from the valid decisions.
for invalid in \
  "not json" \
  '{"decisions": {}}' \
  "$(jq '.decisions[0].decision = "REJECT"' <<<"$valid_decisions")" \
  "$(jq '.decisions[0].decision = "DEFER"' <<<"$valid_decisions")" \
  "$(jq 'del(.decisions[2])' <<<"$valid_decisions")" \
  "$(jq '.decisions += [.decisions[1]]' <<<"$valid_decisions")" \
  "$(jq '.decisions[1].finding_id = "MIN9"' <<<"$valid_decisions")" \
  "$(jq '.decisions[1].decision = "LATER"' <<<"$valid_decisions")" \
  "$(jq '.decisions[1].rationale = ""' <<<"$valid_decisions")" \
  "$(jq '.decisions[1].severity = "minor"' <<<"$valid_decisions")"; do
  repo="$(setup_repo "invalid-$(grep -c . "$tmp/invalid-count" 2>/dev/null || true)")"
  echo x >>"$tmp/invalid-count"
  if MOCK_OUTPUT="$invalid" run_revise "$repo" y --review "$review"; then
    fail "invalid revision decisions were accepted"
  fi
  [[ ! -e "$repo/$revision.json" ]] || fail "invalid decisions were recorded"
  [[ "$(grep -c '^AGENT=' "$repo.log")" -eq 2 ]] || fail "invalid decisions were not retried exactly once"
done

# The write session may change only the architecture, roadmap, and ADRs.
for action in \
  "printf 'changed\\n' >>docs/PROJECT_REQUIREMENTS.md" \
  "printf 'changed\\n' >>AGENTS.md" \
  "printf 'x\\n' >.env" \
  "printf 'x\\n' >>$revision.json" \
  "printf 'x\\n' >docs/decisions/tool.sh" \
  "git add -A && git commit -qm 'Agent must not commit'"; do
  repo="$(setup_repo "scope-$(grep -c . "$tmp/scope-count" 2>/dev/null || true)")"
  echo x >>"$tmp/scope-count"
  if MOCK_WRITE_ACTION="$add_offline_feature; $action" run_revise "$repo" y --review "$review"; then
    fail "an out-of-scope change was accepted: $action"
  fi
  grep -Fq "preserved" "$repo.out" || fail "a scope violation did not preserve the worktree: $action"
done

# A minor finding may be deferred.
repo="$(setup_repo defer)"
MOCK_OUTPUT="$(jq '.decisions[1].decision = "DEFER"' <<<"$valid_decisions")" \
  MOCK_WRITE_ACTION="$add_offline_feature" run_revise "$repo" y --review "$review" || {
  cat "$repo.out" >&2
  fail "deferring a minor finding was rejected"
}

# A write session that changes nothing does not count as a revision; the
# approved decisions stay for a retry.
repo="$(setup_repo no-op)"
if run_revise "$repo" y --review "$review"; then
  fail "a write session without changes was reported as a revision"
fi
grep -Fq "changed no planning document" "$repo.out" || fail "an empty revision was not reported"
[[ -f "$repo/$revision.json" ]] || fail "the approved decisions were lost after an empty revision"

# A failed write session keeps the approved decisions; while the review is
# still current, a re-run applies them without deciding again.
repo="$(setup_repo resume)"
if MOCK_WRITE_EXIT=5 run_revise "$repo" y --review "$review"; then
  fail "a failed planner returned success"
fi
[[ -f "$repo/$revision.json" ]] || fail "the approved decisions were lost after a failed write session"
rm "$repo.log"
MOCK_WRITE_ACTION="$add_offline_feature" run_revise "$repo" y --review "$review" || {
  cat "$repo.out" >&2
  fail "resuming the revision failed"
}
[[ "$(grep -c '^AGENT=' "$repo.log")" -eq 1 ]] || fail "resuming decided again instead of applying the recorded decisions"

# Without adopted findings no document is changed.
repo="$(setup_repo nothing-adopted)"
MOCK_OUTPUT="$(jq '.decisions[0].decision = "ESCALATE"' <<<"$valid_decisions")" run_revise "$repo" y --review "$review" || {
  cat "$repo.out" >&2
  fail "a revision without adopted findings failed"
}
[[ "$(write_sessions "$repo")" -eq 0 ]] || fail "a write session started without adopted findings"

# A stale review is refused even when it has no findings.
repo="$(setup_repo stale-empty)"
jq '.verdict = "PASS" | .findings = []' "$repo/$review" >"$repo/$review.tmp"
mv "$repo/$review.tmp" "$repo/$review"
printf '\nChanged.\n' >>"$repo/docs/roadmap.md"
if run_revise "$repo" y --review "$review"; then
  fail "a stale review without findings was accepted"
fi

# Stale, foreign, and misplaced reviews fail before an agent starts.
repo="$(setup_repo stale)"
printf '\nChanged.\n' >>"$repo/docs/architecture.md"
if run_revise "$repo" y --review "$review"; then
  fail "a stale planning review was revised"
fi
[[ ! -e "$repo.log" ]] || fail "an agent started for a stale review"

repo="$(setup_repo feature-review)"
jq '.kind = "feature" | .issue = 3 | .reviewed_paths = null' "$repo/$review" >"$repo/$review.tmp"
mv "$repo/$review.tmp" "$repo/$review"
if run_revise "$repo" y --review "$review"; then
  fail "a feature review was revised as planning"
fi

repo="$(setup_repo not-planning)"
git -C "$repo" switch -q -c feature/1-x
if run_revise "$repo" y --review "$review"; then
  fail "revision ran outside a planning worktree"
fi
[[ ! -e "$repo.log" ]] || fail "an agent started despite failed preconditions"

echo "revise-planning tests passed"
