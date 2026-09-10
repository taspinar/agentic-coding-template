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
