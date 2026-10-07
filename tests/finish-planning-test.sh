#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/finish-planning-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "finish-planning test failed: $*" >&2
  exit 1
}

source "$source_root/tests/lib-fakes.sh"
make_fake_agents "$tmp/bin"

reviews=".agents/reviews"
counter=0

# Creates a planning repository. Review rounds are added with add_review.
setup_repo() {
  local repo="$tmp/$1"

  mkdir -p "$repo/docs/decisions" "$repo/$reviews"
  copy_workflow "$repo"
  printf '# Project Requirements\n\nStatus: Approved\nApproved at: 2026-01-01T00:00:00Z\n' >"$repo/docs/PROJECT_REQUIREMENTS.md"
  printf '# Architecture\n\nLocal storage.\n' >"$repo/docs/architecture.md"
  printf '# Roadmap\n\n## F01 — Recipes\n\n- Goal: list recipes.\n' >"$repo/docs/roadmap.md"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.name "Finish Test"
  git -C "$repo" config user.email "finish-test@example.com"
  git -C "$repo" add .
  git -C "$repo" commit -qm "Seed"
  git -C "$repo" switch -q -c planning/project-bootstrap

  printf '%s\n' "$repo"
}

# add_review <repo> <round> <verdict> <findings-json>
add_review() {
  local repo="$1"
  local review
  review="$repo/$reviews/planning-project-bootstrap-review-$(printf '%02d' "$2").json"

  jq -n --argjson round "$2" --arg verdict "$3" --argjson findings "$4" '{
    schema: "review/v1", kind: "planning", issue: null, round: $round,
    branch: "planning/project-bootstrap", base: "origin/main", merge_base: "aaaa", head: "bbbb",
    reviewed_tree: "", reviewed_paths: ["docs/PROJECT_DESCRIPTION.md", "docs/changes", "docs/PROJECT_REQUIREMENTS.md", "docs/architecture.md", "docs/roadmap.md", "docs/decisions"],
    reviewer: {agent: "codex", model: "model-r"}, created_at: "2026-01-01T00:00:00Z",
    verdict: $verdict, limitations: "", findings: $findings
  }' >"$review"
  record_reviewed_tree "$repo" "$review"
}

# add_revision <repo> <round> <decision-for-each-finding>
add_revision() {
  local repo="$1"
  local review="$repo/$reviews/planning-project-bootstrap-review-$(printf '%02d' "$2").json"

  jq --arg decision "$3" '{
    schema: "revision/v1",
    source_review: ".agents/reviews/planning-project-bootstrap-review-\(.round | tostring | if length == 1 then "0" + . else . end).json",
    branch, review_round: .round, reviewed_tree,
    planner: {agent: "claude", model: "model-p"},
    approved_at: "2026-01-02T00:00:00Z",
    decisions: [.findings[] | {finding_id: .id, severity, title, decision: $decision, rationale: "Considered."}]
  }' "$review" >"${review%.json}-revision.json"
}

finding() {
  printf '{"id": "%s", "severity": "%s", "title": "%s", "evidence": "docs/roadmap.md", "impact": "Impact.", "recommendation": "Change it."}' "$1" "$2" "$3"
}

run_finish() {
  local repo="$1"
  local answer="$2"
  shift 2

  (
    cd "$repo"
    printf '%s\n' "$answer" | PATH="$tmp/bin:/usr/bin:/bin" ./scripts/finish-planning.sh "$@"
  ) >"$repo.out" 2>&1
}

expect_refused() {
  local repo="$1"
  local description="$2"

  if run_finish "$repo" y; then
    cat "$repo.out" >&2
    fail "expected refusal: $description"
  fi
  [[ ! -e "$repo/docs/PLANNING_APPROVAL.md" ]] || fail "an approval was recorded although: $description"
}

check_status() {
  local status=0
  (cd "$1" && PATH="$tmp/bin:/usr/bin:/bin" ./scripts/finish-planning.sh --check >/dev/null 2>&1) || status=$?
  echo "$status"
}

# A planning whose latest round passed is approved after confirmation; the
# approval lists the rounds and the findings that were not adopted.
repo="$(setup_repo approve)"
add_review "$repo" 1 CHANGES_REQUIRED "[$(finding M1 major "Offline use is unplanned"), $(finding MIN1 minor "Vague name")]"
add_revision "$repo" 1 ADOPT
jq '.decisions[1].decision = "REJECT" | .decisions[1].rationale = "The name follows the requirements."' \
  "$repo/$reviews/planning-project-bootstrap-review-01-revision.json" >"$tmp/revision.tmp"
mv "$tmp/revision.tmp" "$repo/$reviews/planning-project-bootstrap-review-01-revision.json"
printf '\n## F02 — Offline use\n' >>"$repo/docs/roadmap.md"
add_review "$repo" 2 PASS "[]"
run_finish "$repo" y || {
  cat "$repo.out" >&2
  fail "approving a passed planning failed"
}
approval="$repo/docs/PLANNING_APPROVAL.md"
grep -Fqx "Status: Approved" "$approval" || fail "the approval was not recorded"
grep -Eq '^Planning fingerprint: [0-9a-f]{40}$' "$approval" || fail "the approval lacks the planning fingerprint"
grep -Fq "Round 1, REJECT: MIN1 [minor] Vague name" "$approval" || fail "the approval lacks a rejected finding"
grep -Fq "Round 2: PASS" "$approval" || fail "the approval lacks the final round"
grep -Fq "Vague name" "$repo.out" || fail "a rejected finding was not shown before approval"
grep -Fq "git add docs/PROJECT_REQUIREMENTS.md docs/architecture.md docs/roadmap.md docs/decisions docs/PLANNING_APPROVAL.md" "$repo.out" ||
  fail "the commit step does not list the existing planning documents"

# --check reports a current approval, and a stale one after any planning change.
[[ "$(check_status "$repo")" -eq 0 ]] || fail "a fresh approval is not current"
printf 'Unrelated.\n' >"$repo/notes.txt"
[[ "$(check_status "$repo")" -eq 0 ]] || fail "an unrelated change invalidated the approval"
printf '# ADR 001: Storage\n' >"$repo/docs/decisions/001-storage.md"
[[ "$(check_status "$repo")" -eq 1 ]] || fail "a new ADR did not invalidate the approval"
rm "$repo/docs/decisions/001-storage.md"
printf 'Changed.\n' >>"$repo/docs/architecture.md"
[[ "$(check_status "$repo")" -eq 1 ]] || fail "an architecture change did not invalidate the approval"
repo_without="$(setup_repo no-approval)"
[[ "$(check_status "$repo_without")" -eq 1 ]] || fail "a missing approval was not reported"

# Minor findings that were all rejected or deferred can be approved.
repo="$(setup_repo minor-handled)"
add_review "$repo" 1 PASS_WITH_MINOR_FINDINGS "[$(finding MIN1 minor "Vague name"), $(finding S1 suggestion "Sharing")]"
add_revision "$repo" 1 DEFER
run_finish "$repo" y || {
  cat "$repo.out" >&2
  fail "approving with deferred minor findings failed"
}

# Declining records nothing.
repo="$(setup_repo decline)"
add_review "$repo" 1 PASS "[]"
run_finish "$repo" n || fail "declining returned an error"
[[ ! -e "$repo/docs/PLANNING_APPROVAL.md" ]] || fail "a declined approval was recorded"

# Refusals.
repo="$(setup_repo no-review)"
expect_refused "$repo" "there is no planning review"

repo="$(setup_repo stale)"
add_review "$repo" 1 PASS "[]"
printf 'Changed.\n' >>"$repo/docs/roadmap.md"
expect_refused "$repo" "the latest review is stale"

repo="$(setup_repo blocking)"
add_review "$repo" 1 CHANGES_REQUIRED "[$(finding M1 major "Offline use is unplanned")]"
add_revision "$repo" 1 ESCALATE
expect_refused "$repo" "the latest review has a major finding"

repo="$(setup_repo undecided)"
add_review "$repo" 1 PASS_WITH_MINOR_FINDINGS "[$(finding MIN1 minor "Vague name")]"
expect_refused "$repo" "a minor finding has no revision decision"

repo="$(setup_repo not-applied)"
add_review "$repo" 1 PASS_WITH_MINOR_FINDINGS "[$(finding MIN1 minor "Vague name")]"
add_revision "$repo" 1 ADOPT
expect_refused "$repo" "an adopted finding is not applied"

repo="$(setup_repo escalated)"
add_review "$repo" 1 PASS_WITH_MINOR_FINDINGS "[$(finding MIN1 minor "Vague name")]"
add_revision "$repo" 1 ESCALATE
expect_refused "$repo" "a finding is escalated"
grep -Fq "Round 1, ESCALATE: MIN1 [minor] Vague name" "$repo.out" || fail "a refusal did not show the escalated finding"
grep -Fq "Rationale: Considered." "$repo.out" || fail "a refusal did not show the rationale"

# An escalation of an earlier round is not resolved by a newer review alone:
# the human confirms its resolution, and the approval records that.
repo="$(setup_repo earlier-escalation)"
add_review "$repo" 1 PASS_WITH_MINOR_FINDINGS "[$(finding MIN1 minor "Sharing scope is open")]"
add_revision "$repo" 1 ESCALATE
printf 'Sharing is out of scope.\n' >>"$repo/docs/PROJECT_REQUIREMENTS.md"
add_review "$repo" 2 PASS "[]"
if run_finish "$repo" $'n\ny'; then
  fail "an earlier escalation that was not confirmed as resolved was approved"
fi
[[ ! -e "$repo/docs/PLANNING_APPROVAL.md" ]] || fail "an approval was recorded with an unresolved earlier escalation"
run_finish "$repo" $'y\ny' || {
  cat "$repo.out" >&2
  fail "approving after confirming an earlier escalation failed"
}
grep -Fq "## Escalations confirmed as resolved" "$repo/docs/PLANNING_APPROVAL.md" ||
  fail "the confirmed resolution of an earlier escalation was not recorded"

# A planning document that changes while the approval question waits is not approved.
repo="$(setup_repo changes-during-approval)"
add_review "$repo" 1 PASS "[]"
mkfifo "$tmp/answer"
(
  cd "$repo"
  PATH="$tmp/bin:/usr/bin:/bin" ./scripts/finish-planning.sh <"$tmp/answer"
) >"$repo.out" 2>&1 &
finisher=$!
exec 3>"$tmp/answer"
for _ in $(seq 1 100); do
  grep -Fq "Approve this planning?" "$repo.out" 2>/dev/null && break
  sleep 0.1
done
printf 'Changed while deciding.\n' >>"$repo/docs/roadmap.md"
echo y >&3
exec 3>&-
status=0
wait "$finisher" || status=$?
[[ "$status" -ne 0 ]] || fail "a planning that changed during the approval question was approved"
[[ ! -e "$repo/docs/PLANNING_APPROVAL.md" ]] || fail "an approval was recorded for a changed planning"

repo="$(setup_repo unapproved-requirements)"
add_review "$repo" 1 PASS "[]"
printf '# Project Requirements\n\nStatus: Draft\n' >"$repo/docs/PROJECT_REQUIREMENTS.md"
expect_refused "$repo" "the requirements are not approved"

repo="$(setup_repo not-planning)"
add_review "$repo" 1 PASS "[]"
git -C "$repo" switch -q -c feature/1-x
expect_refused "$repo" "the branch is not a planning branch"

# The approval of a change cycle records its change request, covers it, and
# names the commit after the change.
repo="$(setup_repo change-cycle)"
mkdir -p "$repo/docs/changes"
printf 'Add a shopping list.\n' >"$repo/docs/changes/project-bootstrap.md"
printf '\n## F02 — Shopping list\n' >>"$repo/docs/roadmap.md"
add_review "$repo" 1 PASS "[]"
run_finish "$repo" y || {
  cat "$repo.out" >&2
  fail "approving a change cycle failed"
}
grep -Fqx "Change request: docs/changes/project-bootstrap.md" "$repo/docs/PLANNING_APPROVAL.md" ||
  fail "the approval does not record the change request"
grep -Fq 'git commit -m "Plan change: project-bootstrap"' "$repo.out" || fail "the commit is not named after the change"
grep -Fq "docs/changes" "$repo.out" || fail "the commit step does not include the change request"
[[ "$(check_status "$repo")" -eq 0 ]] || fail "a fresh change approval is not current"
printf 'More.\n' >>"$repo/docs/changes/project-bootstrap.md"
[[ "$(check_status "$repo")" -eq 1 ]] || fail "changing the change request did not invalidate the approval"

# --- Amendment ---------------------------------------------------------------
#
# A small technical change to a planning that was approved before: only the
# architecture and the ADRs, approved without a review round.

# Creates a repository whose main holds an approved planning, on a new
# planning branch.
setup_approved() {
  local repo
  local fingerprint

  repo="$(setup_repo "$1")"
  git -C "$repo" switch -q main
  printf '# ADR 001: Local storage\n\n## Status\n\nAccepted.\n' >"$repo/docs/decisions/001-local-storage.md"
  fingerprint="$(bash -c 'source "$1/scripts/lib/fingerprint.sh"; source "$1/scripts/lib/planning.sh"
    scratch="$(mktemp -d)"; fingerprint_files "$1" "$scratch" "${PLANNING_SCOPE[@]}"; rm -rf "$scratch"' _ "$repo")"
  printf '# Planning Approval\n\nStatus: Approved\nApproved at: 2026-01-03T00:00:00Z\nFinal review: round 2, PASS, by codex (model-p)\nPlanning fingerprint: %s\n\n## Review rounds\n\n- Round 2: PASS\n' \
    "$fingerprint" >"$repo/docs/PLANNING_APPROVAL.md"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "Approved planning" >/dev/null
  git -C "$repo" switch -q -c "planning/$1"
  printf '%s\n' "$repo"
}

run_amend() {
  local repo="$1"
  local answer="$2"

  shift 2
  (
    cd "$repo"
    printf '%s\n' "$answer" | PATH="$tmp/bin:/usr/bin:/bin" ./scripts/finish-planning.sh "$@"
  ) >"$repo.out" 2>&1
}

amend_adr() {
  printf '\n## Status\n\nAmended by ADR 002.\n' >>"$1/docs/decisions/001-local-storage.md"
  printf '# ADR 002: Cache\n\nAmends ADR 001.\n' >"$1/docs/decisions/002-cache.md"
  printf '\nA cache sits in front of the storage.\n' >>"$1/docs/architecture.md"
}

# An amendment of the architecture and the ADRs is shown, approved, and added
# to the existing approval, which is current again. No review is needed.
repo="$(setup_approved amend)"
approval="$repo/docs/PLANNING_APPROVAL.md"
fingerprint_before="$(grep '^Planning fingerprint: ' "$approval")"
amend_adr "$repo"
[[ "$(check_status "$repo")" -eq 1 ]] || fail "a changed ADR did not invalidate the approval"
run_amend "$repo" y --amend "Add a cache in front of the storage." || {
  cat "$repo.out" >&2
  fail "approving an amendment failed"
}
[[ "$(check_status "$repo")" -eq 0 ]] || fail "the approval is not current after an amendment"
[[ "$(grep '^Planning fingerprint: ' "$approval")" != "$fingerprint_before" ]] || fail "the amendment kept the old fingerprint"
[[ "$(grep -c '^Planning fingerprint: ' "$approval")" -eq 1 ]] || fail "the approval has more than one fingerprint"
grep -Fq "Final review: round 2, PASS, by codex (model-p)" "$approval" || fail "the amendment dropped the earlier approval record"
grep -Fqx "## Amendments after the approval" "$approval" || fail "the amendment was not listed"
grep -Eq '^- [0-9T:Z-]+, planning/amend: Add a cache in front of the storage\. \(changed: docs/architecture\.md, docs/decisions/001-local-storage\.md, docs/decisions/002-cache\.md\)\. .*without an independent planning review\.$' "$approval" ||
  fail "the amendment entry lacks the reason, the changed files, or the missing review"
grep -Fq "+A cache sits in front of the storage." "$repo.out" || fail "the amendment was not shown before the approval"
grep -Fq 'git commit -m "Amend planning: amend"' "$repo.out" || fail "the commit step was not printed"
[[ ! -e "$repo.log" ]] || fail "an agent ran for an amendment"

# A second amendment, after the first was merged, adds a second entry.
git -C "$repo" add -A
git -C "$repo" commit -qm "Amend planning"
git -C "$repo" switch -q main
git -C "$repo" merge -q --ff-only planning/amend
git -C "$repo" switch -q -c planning/amend-again
printf '\nThe cache is bounded.\n' >>"$repo/docs/architecture.md"
run_amend "$repo" y --amend "Bound the cache." || fail "a second amendment failed"
[[ "$(grep -c '^- .*without an independent planning review\.$' "$approval")" -eq 2 ]] || fail "the second amendment is not a second entry"
[[ "$(grep -c '^## Amendments after the approval$' "$approval")" -eq 1 ]] || fail "the amendments heading was repeated"
[[ "$(check_status "$repo")" -eq 0 ]] || fail "the approval is not current after a second amendment"

# Declining leaves the approval as it was.
repo="$(setup_approved amend-declined)"
amend_adr "$repo"
before="$(cat "$repo/docs/PLANNING_APPROVAL.md")"
run_amend "$repo" n --amend "Add a cache." || fail "declining an amendment failed"
[[ "$(cat "$repo/docs/PLANNING_APPROVAL.md")" == "$before" ]] || fail "a declined amendment changed the approval"
[[ "$(check_status "$repo")" -eq 1 ]] || fail "a declined amendment was approved"

# Anything beyond the architecture and the ADRs needs a review, and so does
# deleting an ADR. The approval is not changed.
expect_amend_refused() {
  local label="$1"
  local action="$2"
  local message="$3"
  local repo
  local before

  repo="$(setup_approved "refused-$label")"
  (cd "$repo" && eval "$action")
  before="$(cat "$repo/docs/PLANNING_APPROVAL.md" 2>/dev/null || true)"
  if run_amend "$repo" y --amend "A reason."; then
    cat "$repo.out" >&2
    fail "an amendment was approved although: $label"
  fi
  grep -Fq "$message" "$repo.out" || {
    cat "$repo.out" >&2
    fail "the refusal of '$label' did not say: $message"
  }
  [[ "$(cat "$repo/docs/PLANNING_APPROVAL.md" 2>/dev/null || true)" == "$before" ]] ||
    fail "the approval changed although: $label"
}

expect_amend_refused roadmap 'printf "\n## F02 — More\n" >>docs/roadmap.md' "start-planning.sh <name> --change <file>"
expect_amend_refused requirements 'printf "\nMore.\n" >>docs/PROJECT_REQUIREMENTS.md' "M docs/PROJECT_REQUIREMENTS.md"
expect_amend_refused change-request 'mkdir -p docs/changes; printf "More.\n" >docs/changes/more.md; printf "\nMore.\n" >>docs/architecture.md' "A docs/changes/more.md"
expect_amend_refused adr-deleted 'rm docs/decisions/001-local-storage.md' "D docs/decisions/001-local-storage.md"
expect_amend_refused nested-adr 'mkdir -p docs/decisions/more; printf "# ADR\n" >docs/decisions/more/003.md' "A docs/decisions/more/003.md"
expect_amend_refused nothing ':' "there is nothing to amend"
expect_amend_refused approval-edited 'printf "\nMore.\n" >>docs/architecture.md; printf "edited\n" >>docs/PLANNING_APPROVAL.md' "restore it first"

# The required planning documents must still be there after an amendment.
expect_amend_refused architecture-deleted 'rm docs/architecture.md' "required planning document is missing or empty: docs/architecture.md"
expect_amend_refused architecture-empty ': >docs/architecture.md' "required planning document is missing or empty: docs/architecture.md"
expect_amend_refused architecture-linked 'mv docs/architecture.md elsewhere.md; ln -s ../elsewhere.md docs/architecture.md' \
  "required planning document is missing or empty: docs/architecture.md"

# The amendment is judged against the base branch as it is now: a branch
# that lacks later commits of main is refused, whatever those commits hold.
repo="$(setup_approved amend-behind)"
amend_adr "$repo"
git -C "$repo" stash -q -u
git -C "$repo" switch -q main
git -C "$repo" rm -q docs/PLANNING_APPROVAL.md
git -C "$repo" commit -qm "Main loses its approval after the branch was created"
git -C "$repo" switch -q planning/amend-behind
git -C "$repo" stash pop -q
if run_amend "$repo" y --amend "A reason."; then fail "an amendment was approved on a branch behind main"; fi
grep -Fq "does not contain the latest main" "$repo.out" || fail "the outdated branch was not reported"
[[ "$(check_status "$repo")" -eq 1 ]] || fail "an amendment on an outdated branch was recorded"

# An amendment does not repair a missing or stale approval of the base.
repo="$(setup_approved amend-no-approval)"
git -C "$repo" switch -q main
git -C "$repo" rm -q docs/PLANNING_APPROVAL.md
git -C "$repo" commit -qm "Drop the approval"
git -C "$repo" switch -q -c planning/amend-no-approval-2
printf '\nMore.\n' >>"$repo/docs/architecture.md"
if run_amend "$repo" y --amend "A reason."; then fail "an amendment created an approval that did not exist"; fi
grep -Fq "has no planning approval to amend" "$repo.out" || fail "the missing approval was not reported"
[[ ! -e "$repo/docs/PLANNING_APPROVAL.md" ]] || fail "an amendment created an approval file"

repo="$(setup_approved amend-stale-approval)"
git -C "$repo" switch -q main
printf '\n## F02 — Unapproved\n' >>"$repo/docs/roadmap.md"
git -C "$repo" commit -qam "Change the roadmap without approval"
git -C "$repo" switch -q -c planning/amend-stale-approval-2
printf '\nMore.\n' >>"$repo/docs/architecture.md"
if run_amend "$repo" y --amend "A reason."; then fail "an amendment renewed a stale approval"; fi
grep -Fq "changed after its approval" "$repo.out" || fail "the stale approval was not reported"

# A reason is required, and an amendment runs on a planning branch.
repo="$(setup_approved amend-arguments)"
amend_adr "$repo"
if run_amend "$repo" y --amend " "; then fail "an amendment without a reason was accepted"; fi
if run_amend "$repo" y --amend; then fail "--amend without a value was accepted"; fi
git -C "$repo" stash -q -u
git -C "$repo" switch -q main
if run_amend "$repo" y --amend "A reason."; then fail "an amendment on main was accepted"; fi

echo "finish-planning tests passed"
