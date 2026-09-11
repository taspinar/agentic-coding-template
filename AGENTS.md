# Agent Instructions

This repository uses a plan → act → evaluate workflow. Git and GitHub are the system of record.

## Before non-trivial work
1. Read this file and relevant docs/architecture.md and accepted ADRs.
2. Read the GitHub issue and active `.agents/plans/<issue>-*.md`.
3. Inspect the repository; do not rely on stale chat context.
4. Work only in the assigned feature branch/worktree.

## Source precedence
1. Explicit current human instruction
2. Accepted ADRs
3. Current GitHub issue acceptance criteria
4. AGENTS.md
5. Current architecture documentation
6. Active feature plan
7. Handoff documents
8. Previous agent assumptions

If a material conflict remains, stop and report it.

## Definition of Done
- Acceptance criteria are satisfied.
- Tests are added/updated where appropriate.
- `./scripts/verify.sh` passes.
- No unrelated changes are included.
- Docs/ADRs are updated when architecture or behavior changed.
- Verification evidence is recorded in the active plan or PR.
- Required independent review is complete and no Critical or Major findings
  remain unresolved.
- Required review findings have an approved triage artifact.
- Deferred findings have a linked follow-up Issue; accepted findings have an
  explicit rationale.

## Boundaries
- Never push directly to `main`.
- Never access or mutate production data, secrets, IAM, or production infrastructure without explicit human approval.
- Never broaden the task merely to make implementation easier.
- One writing agent per worktree. Parallel writers require separate worktrees/branches.
- After three materially different failed repair attempts, stop and create/update a diagnostic handoff.

## Context freshness
When resuming work, compare the plan/handoff base commit with current repository state. Revalidate assumptions before continuing and update stale artifacts.

## Branch and worktree policy

Agents must not make repository changes directly on `main`.

This applies to:

- application code
- architecture documentation
- roadmap changes
- ADRs
- feature plans
- CI/CD configuration
- infrastructure configuration

Before modifying repository files, work on an appropriate branch.

Examples:

- `planning/project-bootstrap`
- `planning/issue-12-authentication`
- `feature/12-authentication`
- `fix/27-login-error`

For substantial implementation work, prefer a dedicated Git worktree.

If the current branch is `main`, do not modify files before creating or
switching to an appropriate branch.

## Roadmap, Issues and Plans

Use each artifact for its intended purpose:

- `docs/roadmap.md` — project direction and future features
- GitHub Issues — active actionable backlog items
- `.agents/plans/` — detailed technical execution plans

Do not duplicate detailed implementation plans into GitHub Issues.

Do not create separate Issues for every plan step.

Do not assume future roadmap items are still valid without reviewing the current
architecture and roadmap first.
