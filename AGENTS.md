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

## Boundaries
- Never push directly to `main`.
- Never access or mutate production data, secrets, IAM, or production infrastructure without explicit human approval.
- Never broaden the task merely to make implementation easier.
- One writing agent per worktree. Parallel writers require separate worktrees/branches.
- After three materially different failed repair attempts, stop and create/update a diagnostic handoff.

## Context freshness
When resuming work, compare the plan/handoff base commit with current repository state. Revalidate assumptions before continuing and update stale artifacts.
