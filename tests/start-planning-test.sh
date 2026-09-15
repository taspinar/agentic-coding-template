#!/usr/bin/env bash

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
script_source="$root/scripts/start-planning.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/start-planning-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "start-planning test failed: $*" >&2
  exit 1
}

mkdir -p "$tmp/bin"

cat >"$tmp/bin/codex" <<'AGENT'
#!/usr/bin/env bash
set -euo pipefail

agent="$(basename "$0")"
prompt="${!#}"

if [[ "$prompt" == *"Project Grill phase"* ]]; then
  phase="grill"
elif [[ "$prompt" == *"project planning phase"* ]]; then
  phase="planner"
else
  echo "Unknown phase prompt" >&2
  exit 90
fi

{
  echo "AGENT=$agent"
  echo "PHASE=$phase"
  echo "PWD=$PWD"
  echo "ARGS=$*"
} >>"$MOCK_AGENT_LOG"

if [[ "$phase" == "grill" ]]; then
  if [[ "${MOCK_GRILL_MODE:-success}" == "fail" ]]; then
    exit 41
  fi

  if [[ "${MOCK_GRILL_MODE:-success}" == "malformed" ]]; then
    printf '# Project Requirements\n\nStatus: Draft\n' >docs/PROJECT_REQUIREMENTS.md
    exit 0
  fi

  cat >docs/PROJECT_REQUIREMENTS.md <<'REQUIREMENTS'
# Project Requirements

Status: Draft
Approved at: Not approved

## Project goal

Ship a focused test product.

## Target users

Test users.

## Primary use cases and journeys

Complete the primary test journey.

## MVP scope

One complete vertical slice.

## Non-goals

Production deployment.

## UX expectations

Clear keyboard-accessible interactions.

## Data and persistence

Local ephemeral data.

## Authentication and authorization

None.

## External integrations

None.

## Runtime and deployment constraints

Run locally.

## Security and privacy constraints

Do not process sensitive data.

## Major product decisions

Keep the MVP local and single-user.

## Unresolved questions

None.
REQUIREMENTS
  if [[ "${MOCK_GRILL_MODE:-success}" == "extra" ]]; then
    printf 'Out-of-scope Grill change.\n' >README.md
  elif [[ "${MOCK_GRILL_MODE:-success}" == "ignored" ]]; then
    printf 'IGNORED_SECRET=test\n' >.env
  elif [[ "${MOCK_GRILL_MODE:-success}" == "weird-paths" ]]; then
    printf 'Tab path.\n' >$'docs/PROJECT_REQUIREMENTS.md\textra'
    printf 'Newline path.\n' >$'unexpected\nfile'
  elif [[ "${MOCK_GRILL_MODE:-success}" == "empty-section" ]]; then
    awk '
      /^## Project goal$/ {
        print
        getline
        getline
        next
      }
      { print }
    ' docs/PROJECT_REQUIREMENTS.md >docs/PROJECT_REQUIREMENTS.tmp
    mv docs/PROJECT_REQUIREMENTS.tmp docs/PROJECT_REQUIREMENTS.md
  elif [[ "${MOCK_GRILL_MODE:-success}" == "duplicate-section" ]]; then
    printf '\n## Project goal\n\nDuplicate goal.\n' >>docs/PROJECT_REQUIREMENTS.md
  elif [[ "${MOCK_GRILL_MODE:-success}" == "commit-extra" ]]; then
    printf 'Committed out-of-scope Grill change.\n' >README.md
    git add docs/PROJECT_REQUIREMENTS.md README.md
    git commit -qm "Agent must not commit"
  fi
  exit 0
fi

grep -Fqx "Status: Approved" docs/PROJECT_REQUIREMENTS.md ||
  exit 91

if [[ "${MOCK_PLANNER_MODE:-success}" == "fail" ]]; then
  exit 42
fi

if [[ "${MOCK_PLANNER_MODE:-success}" != "only-roadmap" && "${MOCK_PLANNER_MODE:-success}" != "mode-only" ]]; then
  cat >docs/architecture.md <<'ARCHITECTURE'
# Architecture

The approved test product uses one local component.
ARCHITECTURE
fi

if [[ "${MOCK_PLANNER_MODE:-success}" != "only-architecture" && "${MOCK_PLANNER_MODE:-success}" != "mode-only" ]]; then
  cat >docs/roadmap.md <<'ROADMAP'
# Roadmap

## F01 — Test vertical slice

- Goal: deliver the primary journey.
- Dependencies: none.
- Acceptance criteria: the journey works locally.
- Risk: low.
- Detailed plan: expected when activated.
ROADMAP
fi

if [[ "${MOCK_PLANNER_MODE:-success}" == "extra" ]]; then
  printf 'Out-of-scope planner change.\n' >application.txt
elif [[ "${MOCK_PLANNER_MODE:-success}" == "ignored" ]]; then
  printf 'IGNORED_SECRET=test\n' >.env
elif [[ "${MOCK_PLANNER_MODE:-success}" == "weird-paths" ]]; then
  printf 'Tab path.\n' >$'docs/architecture.md\textra'
  printf 'Newline path.\n' >$'docs/roadmap.md\nextra'
elif [[ "${MOCK_PLANNER_MODE:-success}" == "commit-extra" ]]; then
  printf 'Committed out-of-scope planner change.\n' >application.txt
  git add docs/architecture.md docs/roadmap.md application.txt
  git commit -qm "Agent must not commit"
elif [[ "${MOCK_PLANNER_MODE:-success}" == "requirements-mode" ]]; then
  chmod 600 docs/PROJECT_REQUIREMENTS.md
elif [[ "${MOCK_PLANNER_MODE:-success}" == "architecture-directory" ]]; then
  rm docs/architecture.md
  mkdir docs/architecture.md
elif [[ "${MOCK_PLANNER_MODE:-success}" == "roadmap-symlink" ]]; then
  cp docs/roadmap.md "$MOCK_AGENT_LOG.roadmap"
  rm docs/roadmap.md
  ln -s "$MOCK_AGENT_LOG.roadmap" docs/roadmap.md
elif [[ "${MOCK_PLANNER_MODE:-success}" == "adr-non-markdown" ]]; then
  printf '#!/usr/bin/env bash\n' >docs/decisions/tool.sh
elif [[ "${MOCK_PLANNER_MODE:-success}" == "adr-nested" ]]; then
  mkdir -p docs/decisions/nested
  printf '# Nested decision\n' >docs/decisions/nested/decision.md
elif [[ "${MOCK_PLANNER_MODE:-success}" == "mode-only" ]]; then
  chmod 600 docs/architecture.md docs/roadmap.md
elif [[ "${MOCK_PLANNER_MODE:-success}" == "executable-docs" ]]; then
  chmod 755 docs/architecture.md docs/roadmap.md
fi
AGENT

cp "$tmp/bin/codex" "$tmp/bin/claude"
chmod +x "$tmp/bin/codex" "$tmp/bin/claude"

setup_repo() {
  local label="$1"
  local seed="$tmp/${label}-seed"
  local remote="$tmp/${label}-remote.git"
  local repo="$tmp/${label}-repo"

  mkdir -p \
    "$seed/scripts" \
    "$seed/tests" \
    "$seed/.agents/prompts" \
    "$seed/docs/decisions"

  cp "$script_source" "$seed/scripts/start-planning.sh"
  cp "$root/.agents/prompts/project-grill.md" "$seed/.agents/prompts/project-grill.md"
  cp "$root/.agents/prompts/project-planner.md" "$seed/.agents/prompts/project-planner.md"
  cp "$root/docs/PROJECT_REQUIREMENTS.md" "$seed/docs/PROJECT_REQUIREMENTS.md"
  cp "$root/.gitignore" "$seed/.gitignore"

  printf '# Agents\n' >"$seed/AGENTS.md"
  printf '# Repository setup\n' >"$seed/docs/repository-setup.md"
  printf '# Architecture\n\nTemplate.\n' >"$seed/docs/architecture.md"
  printf '# Roadmap\n\nTemplate.\n' >"$seed/docs/roadmap.md"

  git -C "$seed" init -q -b main
  git -C "$seed" config user.name "Planning Test"
  git -C "$seed" config user.email "planning-test@example.com"
  git -C "$seed" add .
  git -C "$seed" commit -qm "Seed project"

  git init -q --bare -b main "$remote"
  git -C "$seed" remote add origin "$remote"
  git -C "$seed" push -q -u origin main
  git clone -q "$remote" "$repo"
  git -C "$repo" config user.name "Planning Test"
  git -C "$repo" config user.email "planning-test@example.com"

  printf '%s\n' "$repo"
}

codex_repo="$(setup_repo codex)"
codex_log="$tmp/codex.log"
codex_output="$(
  cd "$codex_repo/docs"
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$codex_log" \
    ../scripts/start-planning.sh codex astra 2>"$tmp/codex-success.err"
)"
codex_worktree="$tmp/codex-repo-planning-project-bootstrap"

[[ -d "$codex_worktree" ]] || fail "Codex worktree was not created"
[[ "$(git -C "$codex_worktree" branch --show-current)" == "planning/project-bootstrap" ]] ||
  fail "Codex planning branch is incorrect"
[[ "$(git -C "$codex_worktree" rev-parse HEAD)" == "$(git -C "$codex_repo" rev-parse origin/main)" ]] ||
  fail "planning branch did not start at origin/main"
[[ "$(grep -c '^PHASE=' "$codex_log")" -eq 2 ]] ||
  fail "Codex did not run exactly two phases"
[[ "$(awk -F= '/^PHASE=/ { print $2 }' "$codex_log" | paste -sd, -)" == "grill,planner" ]] ||
  fail "Codex phases ran out of order"
grep -Fq -- "--model astra" "$codex_log" ||
  fail "Codex model was not forwarded"
grep -Fq -- "--sandbox workspace-write" "$codex_log" ||
  fail "Codex workspace sandbox was not configured"
grep -Fqx "Status: Approved" "$codex_worktree/docs/PROJECT_REQUIREMENTS.md" ||
  fail "approval status was not persisted"
grep -Eq '^Approved at: [0-9]{4}-[0-9]{2}-[0-9]{2}T' "$codex_worktree/docs/PROJECT_REQUIREMENTS.md" ||
  fail "approval timestamp was not persisted"
[[ "$codex_output" == *"Project bootstrap planning completed."* ]] ||
  fail "success guidance was not printed"
if grep -Fq "No such file or directory" "$tmp/codex-success.err"; then
  fail "Codex happy path emitted a missing optional ADR directory error"
fi

claude_repo="$(setup_repo claude)"
claude_log="$tmp/claude.log"
(
  cd "$claude_repo"
  printf 'yes\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$claude_log" \
    ./scripts/start-planning.sh claude fable architecture-refresh \
    >/dev/null 2>"$tmp/claude-success.err"
)
claude_worktree="$tmp/claude-repo-planning-architecture-refresh"

[[ "$(git -C "$claude_worktree" branch --show-current)" == "planning/architecture-refresh" ]] ||
  fail "custom Claude planning branch is incorrect"
[[ "$(grep -c '^PHASE=' "$claude_log")" -eq 2 ]] ||
  fail "Claude did not run exactly two phases"
grep -Fq -- "--model fable" "$claude_log" ||
  fail "Claude model was not forwarded"
if grep -Fq -- "--sandbox" "$claude_log"; then
  fail "Codex-only flags were forwarded to Claude"
fi
if grep -Fq "No such file or directory" "$tmp/claude-success.err"; then
  fail "Claude happy path emitted a missing optional ADR directory error"
fi

decline_repo="$(setup_repo decline)"
decline_log="$tmp/decline.log"
if (
  cd "$decline_repo"
  printf 'n\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$decline_log" \
    ./scripts/start-planning.sh codex astra >/dev/null 2>&1
); then
  fail "declined requirements returned success"
fi
decline_worktree="$tmp/decline-repo-planning-project-bootstrap"
[[ -d "$decline_worktree" ]] || fail "declined worktree was removed"
[[ "$(grep -c '^PHASE=' "$decline_log")" -eq 1 ]] ||
  fail "planner ran after declined requirements"
grep -Fqx "Status: Draft" "$decline_worktree/docs/PROJECT_REQUIREMENTS.md" ||
  fail "declined requirements did not remain Draft"

malformed_repo="$(setup_repo malformed)"
malformed_log="$tmp/malformed.log"
if (
  cd "$malformed_repo"
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$malformed_log" \
    MOCK_GRILL_MODE=malformed \
    ./scripts/start-planning.sh codex astra >/dev/null 2>&1
); then
  fail "malformed requirements returned success"
fi
[[ "$(grep -c '^PHASE=' "$malformed_log")" -eq 1 ]] ||
  fail "planner ran after malformed requirements"

empty_section_repo="$(setup_repo empty-section)"
empty_section_log="$tmp/empty-section.log"
if (
  cd "$empty_section_repo"
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$empty_section_log" \
    MOCK_GRILL_MODE=empty-section \
    ./scripts/start-planning.sh codex astra >/dev/null 2>&1
); then
  fail "empty required section returned success"
fi
[[ "$(grep -c '^PHASE=' "$empty_section_log")" -eq 1 ]] ||
  fail "planner ran after an empty requirements section"

duplicate_section_repo="$(setup_repo duplicate-section)"
duplicate_section_log="$tmp/duplicate-section.log"
if (
  cd "$duplicate_section_repo"
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$duplicate_section_log" \
    MOCK_GRILL_MODE=duplicate-section \
    ./scripts/start-planning.sh codex astra >/dev/null 2>&1
); then
  fail "duplicate required section returned success"
fi
[[ "$(grep -c '^PHASE=' "$duplicate_section_log")" -eq 1 ]] ||
  fail "planner ran after a duplicate requirements section"

grill_scope_repo="$(setup_repo grill-scope)"
grill_scope_log="$tmp/grill-scope.log"
if (
  cd "$grill_scope_repo"
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$grill_scope_log" \
    MOCK_GRILL_MODE=extra \
    ./scripts/start-planning.sh codex astra >/dev/null 2>&1
); then
  fail "out-of-scope Project Grill change returned success"
fi
[[ "$(grep -c '^PHASE=' "$grill_scope_log")" -eq 1 ]] ||
  fail "planner ran after an out-of-scope Grill change"

grill_ignored_repo="$(setup_repo grill-ignored)"
grill_ignored_log="$tmp/grill-ignored.log"
if (
  cd "$grill_ignored_repo"
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$grill_ignored_log" \
    MOCK_GRILL_MODE=ignored \
    ./scripts/start-planning.sh codex astra >"$tmp/grill-ignored.out" 2>&1
); then
  fail "ignored Project Grill file returned success"
fi
grep -Fq ".env" "$tmp/grill-ignored.out" ||
  fail "ignored Project Grill diagnostic did not identify .env"
grep -Fq "Planning worktree preserved at:" "$tmp/grill-ignored.out" ||
  fail "ignored Project Grill diagnostic omitted preservation guidance"

grill_weird_repo="$(setup_repo grill-weird)"
grill_weird_log="$tmp/grill-weird.log"
if (
  cd "$grill_weird_repo"
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$grill_weird_log" \
    MOCK_GRILL_MODE=weird-paths \
    ./scripts/start-planning.sh codex astra >/dev/null 2>&1
); then
  fail "tab/newline Project Grill paths returned success"
fi

grill_commit_repo="$(setup_repo grill-commit)"
grill_commit_log="$tmp/grill-commit.log"
if (
  cd "$grill_commit_repo"
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$grill_commit_log" \
    MOCK_GRILL_MODE=commit-extra \
    ./scripts/start-planning.sh codex astra >/dev/null 2>&1
); then
  fail "Project Grill commit returned success"
fi
[[ "$(grep -c '^PHASE=' "$grill_commit_log")" -eq 1 ]] ||
  fail "planner ran after a Project Grill commit"

grill_fail_repo="$(setup_repo grill-fail)"
grill_fail_log="$tmp/grill-fail.log"
set +e
(
  cd "$grill_fail_repo"
  PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$grill_fail_log" \
    MOCK_GRILL_MODE=fail \
    ./scripts/start-planning.sh claude fable >"$tmp/grill-fail.out" 2>&1
)
grill_status=$?
set -e
[[ "$grill_status" -eq 41 ]] ||
  fail "Project Grill failure status was not preserved: $grill_status"
[[ -d "$tmp/grill-fail-repo-planning-project-bootstrap" ]] ||
  fail "Project Grill failure removed the worktree"
grep -Fq "Project Grill failed with status 41" "$tmp/grill-fail.out" ||
  fail "Project Grill failure diagnostic omitted its phase and status"
grep -Fq "Inspect it with: git -C" "$tmp/grill-fail.out" ||
  fail "Project Grill failure diagnostic omitted inspection guidance"

planner_fail_repo="$(setup_repo planner-fail)"
planner_fail_log="$tmp/planner-fail.log"
set +e
(
  cd "$planner_fail_repo"
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$planner_fail_log" \
    MOCK_PLANNER_MODE=fail \
    ./scripts/start-planning.sh claude fable >/dev/null 2>&1
)
planner_status=$?
set -e
[[ "$planner_status" -eq 42 ]] ||
  fail "planner failure status was not preserved: $planner_status"
[[ -d "$tmp/planner-fail-repo-planning-project-bootstrap" ]] ||
  fail "planner failure removed the worktree"

planner_scope_repo="$(setup_repo planner-scope)"
planner_scope_log="$tmp/planner-scope.log"
if (
  cd "$planner_scope_repo"
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$planner_scope_log" \
    MOCK_PLANNER_MODE=extra \
    ./scripts/start-planning.sh claude fable >/dev/null 2>&1
); then
  fail "out-of-scope project-planner change returned success"
fi
[[ "$(grep -c '^PHASE=' "$planner_scope_log")" -eq 2 ]] ||
  fail "planner-scope scenario did not run both phases"

planner_ignored_repo="$(setup_repo planner-ignored)"
planner_ignored_log="$tmp/planner-ignored.log"
if (
  cd "$planner_ignored_repo"
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$planner_ignored_log" \
    MOCK_PLANNER_MODE=ignored \
    ./scripts/start-planning.sh claude fable >"$tmp/planner-ignored.out" 2>&1
); then
  fail "ignored project-planner file returned success"
fi
grep -Fq ".env" "$tmp/planner-ignored.out" ||
  fail "ignored project-planner diagnostic did not identify .env"

planner_weird_repo="$(setup_repo planner-weird)"
planner_weird_log="$tmp/planner-weird.log"
if (
  cd "$planner_weird_repo"
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$planner_weird_log" \
    MOCK_PLANNER_MODE=weird-paths \
    ./scripts/start-planning.sh claude fable >/dev/null 2>&1
); then
  fail "tab/newline project-planner paths returned success"
fi

planner_commit_repo="$(setup_repo planner-commit)"
planner_commit_log="$tmp/planner-commit.log"
if (
  cd "$planner_commit_repo"
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$planner_commit_log" \
    MOCK_PLANNER_MODE=commit-extra \
    ./scripts/start-planning.sh claude fable >/dev/null 2>&1
); then
  fail "project-planner commit returned success"
fi

requirements_mode_repo="$(setup_repo requirements-mode)"
requirements_mode_log="$tmp/requirements-mode.log"
if (
  cd "$requirements_mode_repo"
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$requirements_mode_log" \
    MOCK_PLANNER_MODE=requirements-mode \
    ./scripts/start-planning.sh claude fable >/dev/null 2>&1
); then
  fail "requirements mode change returned success"
fi

architecture_directory_repo="$(setup_repo architecture-directory)"
architecture_directory_log="$tmp/architecture-directory.log"
if (
  cd "$architecture_directory_repo"
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$architecture_directory_log" \
    MOCK_PLANNER_MODE=architecture-directory \
    ./scripts/start-planning.sh codex astra >/dev/null 2>&1
); then
  fail "architecture directory returned success"
fi

roadmap_symlink_repo="$(setup_repo roadmap-symlink)"
roadmap_symlink_log="$tmp/roadmap-symlink.log"
if (
  cd "$roadmap_symlink_repo"
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$roadmap_symlink_log" \
    MOCK_PLANNER_MODE=roadmap-symlink \
    ./scripts/start-planning.sh codex astra >/dev/null 2>&1
); then
  fail "roadmap symlink returned success"
fi

adr_non_markdown_repo="$(setup_repo adr-non-markdown)"
adr_non_markdown_log="$tmp/adr-non-markdown.log"
if (
  cd "$adr_non_markdown_repo"
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$adr_non_markdown_log" \
    MOCK_PLANNER_MODE=adr-non-markdown \
    ./scripts/start-planning.sh claude fable >/dev/null 2>&1
); then
  fail "non-Markdown ADR artifact returned success"
fi

adr_nested_repo="$(setup_repo adr-nested)"
adr_nested_log="$tmp/adr-nested.log"
if (
  cd "$adr_nested_repo"
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$adr_nested_log" \
    MOCK_PLANNER_MODE=adr-nested \
    ./scripts/start-planning.sh claude fable >/dev/null 2>&1
); then
  fail "nested ADR artifact returned success"
fi

only_roadmap_repo="$(setup_repo only-roadmap)"
only_roadmap_log="$tmp/only-roadmap.log"
if (
  cd "$only_roadmap_repo"
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$only_roadmap_log" \
    MOCK_PLANNER_MODE=only-roadmap \
    ./scripts/start-planning.sh codex astra >/dev/null 2>&1
); then
  fail "unchanged architecture returned success"
fi

only_architecture_repo="$(setup_repo only-architecture)"
only_architecture_log="$tmp/only-architecture.log"
if (
  cd "$only_architecture_repo"
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$only_architecture_log" \
    MOCK_PLANNER_MODE=only-architecture \
    ./scripts/start-planning.sh codex astra >/dev/null 2>&1
); then
  fail "unchanged roadmap returned success"
fi

mode_only_repo="$(setup_repo mode-only)"
printf '# Architecture\n\nExisting populated architecture.\n' >"$mode_only_repo/docs/architecture.md"
printf '# Roadmap\n\n## F01 — Existing feature\n' >"$mode_only_repo/docs/roadmap.md"
git -C "$mode_only_repo" add docs/architecture.md docs/roadmap.md
git -C "$mode_only_repo" commit -qm "Populate planning documents"
git -C "$mode_only_repo" push -q origin main
mode_only_log="$tmp/mode-only.log"
if (
  cd "$mode_only_repo"
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$mode_only_log" \
    MOCK_PLANNER_MODE=mode-only \
    ./scripts/start-planning.sh codex astra >/dev/null 2>&1
); then
  fail "mode-only architecture and roadmap changes returned success"
fi

executable_docs_repo="$(setup_repo executable-docs)"
executable_docs_log="$tmp/executable-docs.log"
if (
  cd "$executable_docs_repo"
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$executable_docs_log" \
    MOCK_PLANNER_MODE=executable-docs \
    ./scripts/start-planning.sh codex astra >/dev/null 2>&1
); then
  fail "executable planning documents returned success"
fi

invalid_repo="$(setup_repo invalid)"
if (
  cd "$invalid_repo"
  PATH="$tmp/bin:/usr/bin:/bin" \
    ./scripts/start-planning.sh codex fable >/dev/null 2>&1
); then
  fail "known incompatible agent/model combination returned success"
fi
[[ ! -e "$tmp/invalid-repo-planning-project-bootstrap" ]] ||
  fail "invalid combination created a worktree"

unknown_agent_repo="$(setup_repo unknown-agent)"
if (
  cd "$unknown_agent_repo"
  PATH="$tmp/bin:/usr/bin:/bin" \
    ./scripts/start-planning.sh other model >/dev/null 2>&1
); then
  fail "unknown agent returned success"
fi

invalid_name_repo="$(setup_repo invalid-name)"
if (
  cd "$invalid_name_repo"
  PATH="$tmp/bin:/usr/bin:/bin" \
    ./scripts/start-planning.sh codex astra ../unsafe >/dev/null 2>&1
); then
  fail "unsafe planning name returned success"
fi

invalid_model_repo="$(setup_repo invalid-model)"
if (
  cd "$invalid_model_repo"
  PATH="$tmp/bin:/usr/bin:/bin" \
    ./scripts/start-planning.sh codex "bad model" >/dev/null 2>&1
); then
  fail "unsafe model syntax returned success"
fi

option_model_repo="$(setup_repo option-model)"
if (
  cd "$option_model_repo"
  PATH="$tmp/bin:/usr/bin:/bin" \
    ./scripts/start-planning.sh codex --fallback >/dev/null 2>&1
); then
  fail "option-like model returned success"
fi

missing_cli_repo="$(setup_repo missing-cli)"
if (
  cd "$missing_cli_repo"
  PATH="/usr/bin:/bin" \
    ./scripts/start-planning.sh claude fable >/dev/null 2>&1
); then
  fail "missing selected agent CLI returned success"
fi

remote_repo="$(setup_repo remote-duplicate)"
git -C "$remote_repo" branch planning/project-bootstrap
git -C "$remote_repo" push -q origin planning/project-bootstrap
git -C "$remote_repo" branch -D planning/project-bootstrap >/dev/null
if (
  cd "$remote_repo"
  PATH="$tmp/bin:/usr/bin:/bin" \
    ./scripts/start-planning.sh codex astra >/dev/null 2>&1
); then
  fail "existing remote planning branch returned success"
fi
[[ ! -e "$tmp/remote-duplicate-repo-planning-project-bootstrap" ]] ||
  fail "remote duplicate branch created a worktree"

local_repo="$(setup_repo local-duplicate)"
git -C "$local_repo" branch planning/project-bootstrap
if (
  cd "$local_repo"
  PATH="$tmp/bin:/usr/bin:/bin" \
    ./scripts/start-planning.sh codex astra >"$tmp/local-duplicate.out" 2>&1
); then
  fail "existing local planning branch returned success"
fi
grep -Fq "planning branch already exists" "$tmp/local-duplicate.out" ||
  fail "local branch collision diagnostic was not actionable"
[[ ! -e "$tmp/local-duplicate-repo-planning-project-bootstrap" ]] ||
  fail "local branch collision created a worktree path"

path_repo="$(setup_repo path-duplicate)"
mkdir "$tmp/path-duplicate-repo-planning-project-bootstrap"
if (
  cd "$path_repo"
  PATH="$tmp/bin:/usr/bin:/bin" \
    ./scripts/start-planning.sh codex astra >/dev/null 2>&1
); then
  fail "existing worktree path returned success"
fi
if git -C "$path_repo" show-ref --verify --quiet refs/heads/planning/project-bootstrap; then
  fail "existing worktree path created a planning branch"
fi

dangling_path_repo="$(setup_repo dangling-path)"
ln -s "$tmp/missing-worktree-target" "$tmp/dangling-path-repo-planning-project-bootstrap"
if (
  cd "$dangling_path_repo"
  PATH="$tmp/bin:/usr/bin:/bin" \
    ./scripts/start-planning.sh codex astra >"$tmp/dangling-path.out" 2>&1
); then
  fail "dangling worktree symlink returned success"
fi
grep -Fq "planning worktree path already exists" "$tmp/dangling-path.out" ||
  fail "dangling worktree diagnostic was not explicit"
if git -C "$dangling_path_repo" show-ref --verify --quiet refs/heads/planning/project-bootstrap; then
  fail "dangling worktree path created a planning branch"
fi

missing_prompt_repo="$(setup_repo missing-prompt)"
rm "$missing_prompt_repo/.agents/prompts/project-planner.md"
if (
  cd "$missing_prompt_repo"
  PATH="$tmp/bin:/usr/bin:/bin" \
    ./scripts/start-planning.sh codex astra >/dev/null 2>&1
); then
  fail "missing project-planner prompt returned success"
fi

missing_base_repo="$(setup_repo missing-base)"
git -C "$missing_base_repo" remote set-url origin "$tmp/does-not-exist.git"
if (
  cd "$missing_base_repo"
  PATH="$tmp/bin:/usr/bin:/bin" \
    ./scripts/start-planning.sh codex astra >"$tmp/missing-base.out" 2>&1
); then
  fail "unavailable origin/main returned success"
fi
grep -Fq "could not fetch origin/main" "$tmp/missing-base.out" ||
  fail "unavailable origin/main diagnostic was not actionable"

dirty_repo="$(setup_repo dirty)"
printf '\nDirty.\n' >>"$dirty_repo/AGENTS.md"
if (
  cd "$dirty_repo"
  PATH="$tmp/bin:/usr/bin:/bin" \
    ./scripts/start-planning.sh codex astra >/dev/null 2>&1
); then
  fail "dirty repository returned success"
fi
[[ ! -e "$tmp/dirty-repo-planning-project-bootstrap" ]] ||
  fail "dirty repository created a worktree"

echo "start-planning tests passed"
