# Agentic Development Workflow

## Project bootstrap
Template → architecture/roadmap → necessary ADRs → GitHub Issues.

## Feature lifecycle
Issue → feature plan (when warranted) → isolated branch/worktree → implementation → local verification → stable commit → independent review → fixes → verification → push/PR → CI → human gate where required → merge → cleanup.

## Persistent state
- GitHub Issue: what/why, acceptance criteria, priority/status.
- `AGENTS.md`: durable working rules.
- `docs/architecture.md`: current system design.
- ADRs: why significant architecture decisions were made.
- `.agents/plans/`: active implementation state for complex work.
- `.agents/handoffs/`: compressed continuation context.
- `.agents/reviews/`: temporary independent-review artifacts.
- `.agents/lessons/`: recurring failure lessons awaiting/promoting durable rules.
- Git history: what actually changed.
- PR + CI: review discussion and deterministic evidence.

## Project bootstrap workflow

A newly created project should be bootstrapped before feature development
starts.

Recommended sequence:

1. Create the repository from this template.
2. Complete `docs/repository-setup.md`.
3. Create a branch:

   `planning/project-bootstrap`

4. Run the project planner.
5. The planner may create or update:
   - `docs/architecture.md`
   - `docs/roadmap.md`
   - required ADRs under `docs/decisions/`

6. Review the bootstrap artifacts.
7. Commit and push the planning branch.
8. Open a Pull Request.
9. Merge the approved bootstrap into `main`.
10. Convert roadmap items into GitHub Issues.
11. Start feature development.

Do not begin feature implementation during project bootstrap.

## Roadmap to GitHub Issues

`docs/roadmap.md` describes the intended project direction and contains
roadmap features such as F01, F02, F03, etc.

Do not automatically create GitHub Issues for every roadmap feature.

GitHub Issues should normally be created only when a feature is about to
enter the active development workflow.

Recommended approach:

- current feature: GitHub Issue exists
- next 1–2 likely features: optional
- later roadmap items: remain only in `docs/roadmap.md`

This prevents the GitHub backlog from becoming stale when the roadmap changes.

Example:

```text
Roadmap:
F01
F02
F03
F04
F05
...

GitHub Issues:
#1 F01 — active
#2 F02 — optional next
Before starting F03, review the roadmap again and only then create its Issue.

GitHub Issues are the actionable source of truth once created.
The roadmap remains the higher-level planning document.

## Feature plans versus GitHub Issues

A GitHub Issue defines:

- what must be delivered
- scope
- acceptance criteria
- dependencies
- risk

A feature implementation plan defines:

- how the feature will be implemented
- technical steps
- affected components
- discoveries
- verification approach
- current implementation status

Plan steps must not automatically become separate GitHub Issues.

Create another Issue only if a plan step becomes a substantial independent
work item with its own scope, acceptance criteria or lifecycle.
