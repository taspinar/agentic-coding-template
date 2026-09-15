# Agentic Development Workflow

## Project bootstrap
Template → Project Grill → draft project requirements → human approval →
architecture/roadmap and necessary ADRs → planning PR → GitHub Issues for
ready work.

## Feature lifecycle
Roadmap item → GitHub Issue → feature plan (when warranted) → isolated
branch/worktree → implementation → local verification → independent review
when required → review triage → approved fix-now application →
verification/re-review when needed → commit → push/PR → CI → human gate where
required → merge → automatic Issue closure → cleanup.

Independent review happens before the implementation commit so it can include
uncommitted working-tree changes. `triage-review.sh` classifies every finding as
`FIX_NOW`, `DEFER`, or `ACCEPT` and displays the proposal before side effects.
Critical and Major findings must be `FIX_NOW`. Human approval is required
before triage artifacts or provenance-prefixed deferred follow-up Issues are
created. `apply-triage.sh` requires the approved artifact explicitly and starts
a write-capable agent for only its `FIX_NOW` scope after a second confirmation.
See `docs/development.md` for the concrete commands.

## Persistent state
- GitHub Issue: what/why, acceptance criteria, priority/status.
- `AGENTS.md`: durable working rules.
- `docs/architecture.md`: current system design.
- ADRs: why significant architecture decisions were made.
- `.agents/plans/`: active implementation state for complex work.
- `.agents/handoffs/`: compressed continuation context.
- `.agents/reviews/`: temporary independent-review artifacts.
- `.agents/triage/`: approved finding decisions and deferred-Issue traceability.
- `.agents/lessons/`: recurring failure lessons awaiting/promoting durable rules.
- Git history: what actually changed.
- PR + CI: review discussion and deterministic evidence.

## Project bootstrap workflow

A newly created project should be bootstrapped before feature development
starts.

Recommended sequence:

1. Create the repository from this template.
2. Complete `docs/repository-setup.md`.
3. Run the bootstrap entrypoint with an explicit agent and model:

   `./scripts/start-planning.sh codex astra`

   or:

   `./scripts/start-planning.sh claude fable`

4. The script creates `planning/project-bootstrap` in an isolated sibling
   worktree from the current `origin/main`.
5. Project Grill asks material project-level questions and writes:

   - `docs/PROJECT_REQUIREMENTS.md`

6. Review the proposed requirements. The script records approval only after an
   explicit human confirmation.
7. A separate project-planner session may then create or update:
   - `docs/architecture.md`
   - `docs/roadmap.md`
   - required ADRs under `docs/decisions/`

8. Review and verify the bootstrap artifacts.
9. Commit and push the planning branch.
10. Open a Pull Request.
11. Merge the approved bootstrap into `main`.
12. Convert only ready roadmap items into GitHub Issues.
13. Start feature clarification and development.

Declining requirements approval or an agent failure preserves the worktree and
stops later phases. The script does not fall back to another model, implement
features, create Issues, commit, push, open or merge a PR, or deploy.

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
```

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
