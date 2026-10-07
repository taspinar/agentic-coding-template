#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

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

if [[ "$prompt" == *"This is a change cycle"* ]]; then
  echo "CHANGE=$phase" >>"$MOCK_AGENT_LOG"
  [[ "$prompt" == *"docs/changes/"* ]] || exit 92
  if [[ "$phase" == "grill" ]]; then
    eval "${MOCK_CHANGE_GRILL:-:}"
  else
    grep -Fqx "Status: Approved" docs/PROJECT_REQUIREMENTS.md || exit 91
    eval "${MOCK_CHANGE_PLANNER:-:}"
  fi
  exit 0
fi

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
  elif [[ "${MOCK_GRILL_MODE:-success}" == "edit-description" ]]; then
    printf 'Changed by Project Grill.\n' >>docs/PROJECT_DESCRIPTION.md
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
  mkdir -p "$seed/scripts/lib"
  cp "$root"/scripts/lib/*.sh "$seed/scripts/lib/"
  printf 'project-grill: codex astra\nproject-planner: codex astra\n' >"$seed/.agents/agents.conf"
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
    ../scripts/start-planning.sh --agent codex --model astra 2>"$tmp/codex-success.err"
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
    ./scripts/start-planning.sh --agent claude --model fable architecture-refresh \
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
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
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
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
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
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
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
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
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
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
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
    ./scripts/start-planning.sh --agent codex --model astra >"$tmp/grill-ignored.out" 2>&1
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
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
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
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
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
    ./scripts/start-planning.sh --agent claude --model fable >"$tmp/grill-fail.out" 2>&1
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
    ./scripts/start-planning.sh --agent claude --model fable >/dev/null 2>&1
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
    ./scripts/start-planning.sh --agent claude --model fable >/dev/null 2>&1
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
    ./scripts/start-planning.sh --agent claude --model fable >"$tmp/planner-ignored.out" 2>&1
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
    ./scripts/start-planning.sh --agent claude --model fable >/dev/null 2>&1
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
    ./scripts/start-planning.sh --agent claude --model fable >/dev/null 2>&1
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
    ./scripts/start-planning.sh --agent claude --model fable >/dev/null 2>&1
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
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
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
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
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
    ./scripts/start-planning.sh --agent claude --model fable >/dev/null 2>&1
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
    ./scripts/start-planning.sh --agent claude --model fable >/dev/null 2>&1
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
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
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
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
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
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
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
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
); then
  fail "executable planning documents returned success"
fi

invalid_repo="$(setup_repo invalid)"
if (
  cd "$invalid_repo"
  PATH="$tmp/bin:/usr/bin:/bin" \
    ./scripts/start-planning.sh --agent codex --model fable >/dev/null 2>&1
); then
  fail "known incompatible agent/model combination returned success"
fi
[[ ! -e "$tmp/invalid-repo-planning-project-bootstrap" ]] ||
  fail "invalid combination created a worktree"

unknown_agent_repo="$(setup_repo unknown-agent)"
if (
  cd "$unknown_agent_repo"
  PATH="$tmp/bin:/usr/bin:/bin" \
    ./scripts/start-planning.sh --agent other --model model >/dev/null 2>&1
); then
  fail "unknown agent returned success"
fi

invalid_name_repo="$(setup_repo invalid-name)"
if (
  cd "$invalid_name_repo"
  PATH="$tmp/bin:/usr/bin:/bin" \
    ./scripts/start-planning.sh --agent codex --model astra ../unsafe >/dev/null 2>&1
); then
  fail "unsafe planning name returned success"
fi

invalid_model_repo="$(setup_repo invalid-model)"
if (
  cd "$invalid_model_repo"
  PATH="$tmp/bin:/usr/bin:/bin" \
    ./scripts/start-planning.sh --agent codex --model "bad model" >/dev/null 2>&1
); then
  fail "unsafe model syntax returned success"
fi

option_model_repo="$(setup_repo option-model)"
if (
  cd "$option_model_repo"
  PATH="$tmp/bin:/usr/bin:/bin" \
    ./scripts/start-planning.sh --agent codex --model --fallback >/dev/null 2>&1
); then
  fail "option-like model returned success"
fi

missing_cli_repo="$(setup_repo missing-cli)"
if (
  cd "$missing_cli_repo"
  PATH="/usr/bin:/bin" \
    ./scripts/start-planning.sh --agent claude --model fable >/dev/null 2>&1
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
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
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
    ./scripts/start-planning.sh --agent codex --model astra >"$tmp/local-duplicate.out" 2>&1
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
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
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
    ./scripts/start-planning.sh --agent codex --model astra >"$tmp/dangling-path.out" 2>&1
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
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
); then
  fail "missing project-planner prompt returned success"
fi

missing_base_repo="$(setup_repo missing-base)"
git -C "$missing_base_repo" remote set-url origin "$tmp/does-not-exist.git"
if (
  cd "$missing_base_repo"
  PATH="$tmp/bin:/usr/bin:/bin" \
    ./scripts/start-planning.sh --agent codex --model astra >"$tmp/missing-base.out" 2>&1
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
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
); then
  fail "dirty repository returned success"
fi
[[ ! -e "$tmp/dirty-repo-planning-project-bootstrap" ]] ||
  fail "dirty repository created a worktree"

# A project description from outside the repository is copied into the
# planning worktree before the phases start and is announced to Project Grill.
description="$tmp/project idea.txt"
printf 'A local-first recipe organizer.\n' >"$description"
description_repo="$(setup_repo description)"
description_log="$tmp/description.log"
(
  cd "$description_repo"
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$description_log" \
    ./scripts/start-planning.sh --description "$description" --agent claude --model fable \
    >"$tmp/description.out" 2>&1
) || {
  cat "$tmp/description.out" >&2
  fail "planning with a project description failed"
}
description_worktree="$tmp/description-repo-planning-project-bootstrap"
cmp -s "$description" "$description_worktree/docs/PROJECT_DESCRIPTION.md" ||
  fail "project description was not copied into the planning worktree"
grep -Fq "docs/PROJECT_DESCRIPTION.md" "$description_log" ||
  fail "project description was not announced to the agent"
[[ -z "$(git -C "$description_repo" status --porcelain)" ]] ||
  fail "project description changed the primary checkout"

# An uncommitted description inside the repository is accepted, but it does
# not excuse other uncommitted changes.
inside_repo="$(setup_repo description-inside)"
printf 'An untracked description in the checkout.\n' >"$inside_repo/idea.md"
printf '\nDirty.\n' >>"$inside_repo/AGENTS.md"
if (
  cd "$inside_repo"
  PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$tmp/description-inside.log" \
    ./scripts/start-planning.sh --description idea.md --agent codex --model astra >/dev/null 2>&1
); then
  fail "unrelated uncommitted changes were accepted together with a description"
fi
[[ ! -e "$tmp/description-inside-repo-planning-project-bootstrap" ]] ||
  fail "a dirty checkout created a worktree"
git -C "$inside_repo" checkout -q -- AGENTS.md
(
  cd "$inside_repo"
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$tmp/description-inside.log" \
    ./scripts/start-planning.sh --description idea.md --agent codex --model astra \
    >"$tmp/description-inside.out" 2>&1
) || {
  cat "$tmp/description-inside.out" >&2
  fail "an uncommitted description inside the repository was rejected"
}
cmp -s "$inside_repo/idea.md" \
  "$tmp/description-inside-repo-planning-project-bootstrap/docs/PROJECT_DESCRIPTION.md" ||
  fail "in-repository description was not copied into the planning worktree"

# A phase that modifies the supplied description exceeds its scope.
description_edit_repo="$(setup_repo description-edit)"
if (
  cd "$description_edit_repo"
  printf 'y\n' |
    PATH="$tmp/bin:/usr/bin:/bin" \
    MOCK_AGENT_LOG="$tmp/description-edit.log" \
    MOCK_GRILL_MODE=edit-description \
    ./scripts/start-planning.sh --description "$description" --agent codex --model astra \
    >/dev/null 2>&1
); then
  fail "a modified project description returned success"
fi
[[ "$(grep -c '^PHASE=' "$tmp/description-edit.log")" -eq 1 ]] ||
  fail "planner ran after the project description was modified"

# An unusable description fails before any branch or worktree is created.
: >"$tmp/empty-description.txt"
description_invalid_repo="$(setup_repo description-invalid)"
for invalid_description in "$tmp/no-such-description.txt" "$tmp/empty-description.txt" "$tmp/bin" ""; do
  if (
    cd "$description_invalid_repo"
    PATH="$tmp/bin:/usr/bin:/bin" \
      MOCK_AGENT_LOG="$tmp/description-invalid.log" \
      ./scripts/start-planning.sh --agent codex --model astra --description "$invalid_description" \
      >/dev/null 2>&1
  ); then
    fail "unusable project description returned success: '$invalid_description'"
  fi
done
[[ ! -e "$tmp/description-invalid-repo-planning-project-bootstrap" ]] ||
  fail "unusable project description created a worktree"
if git -C "$description_invalid_repo" show-ref --verify --quiet refs/heads/planning/project-bootstrap; then
  fail "unusable project description created a branch"
fi
[[ ! -e "$tmp/description-invalid.log" ]] || fail "an agent started despite an unusable project description"

# --- Change cycle ------------------------------------------------------------
#
# A change to a planning that was approved and merged before.

# Records a planning approval that matches the planning documents in <dir>.
record_planning_approval() {
  local fingerprint

  fingerprint="$(bash -c 'source "$1/scripts/lib/fingerprint.sh"; source "$1/scripts/lib/planning.sh"
    scratch="$(mktemp -d)"; fingerprint_files "$1" "$scratch" "${PLANNING_SCOPE[@]}"; rm -rf "$scratch"' _ "$1")"
  printf '# Planning Approval\n\nStatus: Approved\nPlanning fingerprint: %s\n' "$fingerprint" >"$1/docs/PLANNING_APPROVAL.md"
}

# Creates a repository whose origin/main holds an approved planning with one
# feature, one ADR, and the original project description.
setup_approved_repo() {
  local label="$1"
  local repo
  local worktree="$tmp/${label}-repo-planning-project-bootstrap"

  repo="$(setup_repo "$label")"
  printf 'The original idea.\n' >"$tmp/$label-idea.md"
  (
    cd "$repo"
    printf 'y\n' |
      PATH="$tmp/bin:/usr/bin:/bin" MOCK_AGENT_LOG="$tmp/$label-bootstrap.log" \
      ./scripts/start-planning.sh --agent codex --model astra --description "$tmp/$label-idea.md" >/dev/null 2>&1
  ) || fail "the first planning of $label failed"
  mkdir -p "$worktree/docs/decisions"
  printf '# ADR 001: Local component\n\n## Status\n\nAccepted.\n' >"$worktree/docs/decisions/001-local-component.md"
  record_planning_approval "$worktree"
  git -C "$worktree" add -A
  git -C "$worktree" -c user.name="Planning Test" -c user.email="planning-test@example.com" \
    commit -qm "Plan project bootstrap"
  git -C "$worktree" push -q origin HEAD:main
  git -C "$repo" pull -q
  git -C "$repo" cat-file -e origin/main:docs/decisions/001-local-component.md ||
    fail "the approved planning of $label has no ADR"
  printf '%s\n' "$repo"
}

change_request="$tmp/change-request.md"
printf 'Add a shopping list that is filled from the recipes.\n' >"$change_request"
add_feature='printf "\n## F02 — Shopping list\n\n- Goal: list what to buy.\n- Dependencies: F01.\n" >>docs/roadmap.md'

# run_change <repo> <log-label> <stdin> <name> [option...]
run_change() {
  local repo="$1"
  local label="$2"
  local answer="$3"
  local name="$4"

  shift 4
  (
    cd "$repo"
    printf '%s' "$answer" |
      PATH="$tmp/bin:/usr/bin:/bin" MOCK_AGENT_LOG="$tmp/$label.log" \
      ./scripts/start-planning.sh "$name" --agent codex --model astra "$@"
  ) >"$tmp/$label.out" 2>&1
}

phases() {
  awk -F= '/^PHASE=/ { print $2 }' "$1" | paste -sd, -
}

# A new feature that fits the requirements changes only the roadmap. Only the
# planner runs, the requirements keep their approval, and the change request
# gets its own file next to the original description.
change_repo="$(setup_approved_repo change)"
approved_requirements="$(git -C "$change_repo" show origin/main:docs/PROJECT_REQUIREMENTS.md)"
MOCK_CHANGE_PLANNER="$add_feature" run_change "$change_repo" change-roadmap "" shopping-list --change "$change_request" || {
  cat "$tmp/change-roadmap.out" >&2
  fail "a roadmap-only change failed"
}
change_worktree="$tmp/change-repo-planning-shopping-list"
[[ "$(git -C "$change_worktree" branch --show-current)" == "planning/shopping-list" ]] ||
  fail "the change cycle did not get its own planning branch"
[[ "$(phases "$tmp/change-roadmap.log")" == "planner" ]] || fail "a change without --grill did not run only the planner"
grep -Fq "Planning change cycle completed." "$tmp/change-roadmap.out" || fail "the change cycle was not reported as completed"
cmp -s "$change_request" "$change_worktree/docs/changes/shopping-list.md" ||
  fail "the change request was not copied to docs/changes/"
grep -Fqx "The original idea." "$change_worktree/docs/PROJECT_DESCRIPTION.md" ||
  fail "the change cycle overwrote the original project description"
[[ "$(cat "$change_worktree/docs/PROJECT_REQUIREMENTS.md")" == "$approved_requirements" ]] ||
  fail "a change without --grill touched the approved requirements"
git -C "$change_worktree" diff --quiet -- docs/architecture.md || fail "a roadmap-only change touched the architecture"
grep -Fq "## F02 — Shopping list" "$change_worktree/docs/roadmap.md" || fail "the new feature is not in the roadmap"

# A technical change may leave the roadmap as it is.
MOCK_CHANGE_PLANNER='printf "\nA server component stores the data.\n" >>docs/architecture.md; printf "# ADR 002: Server storage\n\nSupersedes ADR 001.\n" >docs/decisions/002-server-storage.md' \
  run_change "$change_repo" change-architecture "" server-storage --change "$change_request" || {
  cat "$tmp/change-architecture.out" >&2
  fail "an architecture-only change failed"
}
git -C "$tmp/change-repo-planning-server-storage" diff --quiet -- docs/roadmap.md ||
  fail "an architecture-only change touched the roadmap"

# The planner must produce the change, keep every feature ID, keep the ADRs,
# and leave the requirements and the change request alone.
expect_change_rejected() {
  local name="$1"
  local planner_action="$2"
  local message="$3"

  if MOCK_CHANGE_PLANNER="$planner_action" run_change "$change_repo" "rejected-$name" "" "$name" --change "$change_request"; then
    cat "$tmp/rejected-$name.out" >&2
    fail "a change cycle was accepted although: $name"
  fi
  grep -Fq "$message" "$tmp/rejected-$name.out" || {
    cat "$tmp/rejected-$name.out" >&2
    fail "the rejection of '$name' did not say: $message"
  }
}

expect_change_rejected nothing-planned ":" "the change was not planned"
expect_change_rejected feature-removed 'printf "# Roadmap\n\n## F02 — Shopping list\n" >docs/roadmap.md' \
  "removed or renumbered roadmap feature(s): F01"
expect_change_rejected feature-renumbered "sed 's/## F01 /## F03 /' docs/roadmap.md >roadmap.tmp && mv roadmap.tmp docs/roadmap.md" \
  "removed or renumbered roadmap feature(s): F01"
expect_change_rejected adr-deleted "$add_feature; rm docs/decisions/001-local-component.md" \
  "deleted an existing decision artifact"
expect_change_rejected requirements-edited "$add_feature; printf 'More.\n' >>docs/PROJECT_REQUIREMENTS.md" \
  "modified the approved requirements artifact"
expect_change_rejected request-edited "$add_feature; printf 'More.\n' >>docs/changes/request-edited.md" \
  "exceeded its allowed file scope"

# A feature ID that only appears inside a code block is not a feature.
MOCK_CHANGE_PLANNER="$add_feature; printf '\n\`\`\`text\n## F09 — Example\n\`\`\`\n' >>docs/roadmap.md" \
  run_change "$change_repo" change-fenced "" fenced --change "$change_request" || fail "a roadmap with a fenced example failed"

# With --grill, Project Grill may change the requirements. They return to
# Draft, the script shows the difference, and after approval the planner runs
# on the newly approved requirements.
change_requirements='sed -e "s/^Status: Approved$/Status: Draft/" -e "s/^Approved at: .*/Approved at: Not approved/" -e "s/^One complete vertical slice.$/One complete vertical slice, and a shopping list./" docs/PROJECT_REQUIREMENTS.md >requirements.tmp && mv requirements.tmp docs/PROJECT_REQUIREMENTS.md'
MOCK_CHANGE_GRILL="$change_requirements" MOCK_CHANGE_PLANNER="$add_feature" \
  run_change "$change_repo" change-grill "y
" with-grill --change "$change_request" --grill || {
  cat "$tmp/change-grill.out" >&2
  fail "a change cycle with a requirement change failed"
}
[[ "$(phases "$tmp/change-grill.log")" == "grill,planner" ]] || fail "--grill did not run Project Grill before the planner"
grep -Fq "+One complete vertical slice, and a shopping list." "$tmp/change-grill.out" ||
  fail "the change to the requirements was not shown before the approval"
grill_worktree="$tmp/change-repo-planning-with-grill"
grep -Fqx "Status: Approved" "$grill_worktree/docs/PROJECT_REQUIREMENTS.md" || fail "the changed requirements were not approved"
grep -Fqx "One complete vertical slice, and a shopping list." "$grill_worktree/docs/PROJECT_REQUIREMENTS.md" ||
  fail "the approved requirements lack the change"
[[ "$(grep '^Approved at: ' "$grill_worktree/docs/PROJECT_REQUIREMENTS.md")" != "$(printf '%s\n' "$approved_requirements" | grep '^Approved at: ')" ]] ||
  fail "the changed requirements kept their old approval"

# Declining the changed requirements stops before the planner.
if MOCK_CHANGE_GRILL="$change_requirements" MOCK_CHANGE_PLANNER="$add_feature" \
  run_change "$change_repo" change-declined "n
" declined --change "$change_request" --grill; then
  fail "declined requirement changes returned success"
fi
[[ "$(phases "$tmp/change-declined.log")" == "grill" ]] || fail "the planner ran although the changed requirements were declined"

# When Project Grill leaves the requirements as they are, no approval is
# asked: the run has no input to answer with.
MOCK_CHANGE_PLANNER="$add_feature" run_change "$change_repo" change-fits "" fits --change "$change_request" --grill || {
  cat "$tmp/change-fits.out" >&2
  fail "a change that needs no requirement change failed"
}
[[ "$(phases "$tmp/change-fits.log")" == "grill,planner" ]] || fail "the planner did not run after an unchanged Project Grill"
grep -Fq "no new approval is needed" "$tmp/change-fits.out" || fail "the unchanged requirements were not reported"
[[ "$(cat "$tmp/change-repo-planning-fits/docs/PROJECT_REQUIREMENTS.md")" == "$approved_requirements" ]] ||
  fail "unchanged requirements were touched"

# Project Grill may not change anything but the requirements in a change cycle.
if MOCK_CHANGE_GRILL='printf "More.\n" >>docs/changes/grill-scope.md' \
  run_change "$change_repo" change-grill-scope "" grill-scope --change "$change_request" --grill; then
  fail "Project Grill changed the change request"
fi

# Invalid change cycles fail before a branch or worktree is created.
expect_change_refused() {
  local description="$1"
  local name="$2"
  local repo="$3"

  shift 3
  if run_change "$repo" refused "" "$name" "$@"; then
    fail "a change cycle was started although: $description"
  fi
  [[ ! -e "$tmp/refused.log" ]] || fail "an agent started although: $description"
  if git -C "$repo" show-ref --verify --quiet "refs/heads/planning/$name"; then
    fail "a branch was created although: $description"
  fi
}

: >"$tmp/empty-change.md"
expect_change_refused "the change request does not exist" missing "$change_repo" --change "$tmp/no-such-change.md"
expect_change_refused "the change request is empty" empty "$change_repo" --change "$tmp/empty-change.md"
expect_change_refused "a description was given too" both "$change_repo" --change "$change_request" --description "$change_request"
fresh_repo="$(setup_repo change-unapproved)"
expect_change_refused "no planning was approved yet" early "$fresh_repo" --change "$change_request"

# The planning on origin/main must have a current approval: a change cycle
# does not start from a planning that was never approved, or that changed
# after its approval. Nothing is left behind.
expect_no_current_approval() {
  local label="$1"
  local repo="$2"

  expect_change_refused "$label" late "$repo" --change "$change_request"
  grep -Fq "has no current approval" "$tmp/refused.out" || fail "the refusal did not name the approval: $label"
  [[ ! -e "${repo}-planning-late" ]] || fail "a worktree was left behind although: $label"
}

unapproved_repo="$(setup_approved_repo unapproved-planning)"
git -C "$unapproved_repo" rm -q docs/PLANNING_APPROVAL.md
git -C "$unapproved_repo" commit -qm "Drop the approval"
git -C "$unapproved_repo" push -q origin main
expect_no_current_approval "the planning has no approval" "$unapproved_repo"

stale_repo="$(setup_approved_repo stale-planning)"
printf '\nChanged after the approval.\n' >>"$stale_repo/docs/roadmap.md"
git -C "$stale_repo" commit -qam "Change the roadmap without approval"
git -C "$stale_repo" push -q origin main
expect_no_current_approval "the planning changed after its approval" "$stale_repo"
if (cd "$change_repo" && PATH="$tmp/bin:/usr/bin:/bin" ./scripts/start-planning.sh --agent codex --model astra --change "$change_request") >/dev/null 2>&1; then
  fail "a change cycle without a name was accepted"
fi
if (cd "$change_repo" && PATH="$tmp/bin:/usr/bin:/bin" ./scripts/start-planning.sh again --agent codex --model astra --grill) >/dev/null 2>&1; then
  fail "--grill without --change was accepted"
fi

# A change request name that origin/main already has is refused.
git -C "$change_worktree" add -A
git -C "$change_worktree" -c user.name="Planning Test" -c user.email="planning-test@example.com" commit -qm "Plan change"
git -C "$change_worktree" push -q origin HEAD:main
git -C "$change_worktree" switch -q --detach
git -C "$change_repo" branch -q -D planning/shopping-list
expect_change_refused "the change request name is taken" shopping-list "$change_repo" --change "$change_request"

echo "start-planning tests passed"
