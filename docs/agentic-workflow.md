# Agentic Development Workflow

## Lifecycle

The steps, loops, artifacts, and approvals of project bootstrap and feature
development are described in `docs/workflow.md`. This document covers the
principles behind them.

Independent review happens before the implementation commit so it can include
uncommitted working-tree changes. Reviewers run read-only; their results are
validated JSON, and the reports of each feature review round are published on
the feature Issue. Critical and major findings must be fixed and confirmed by
a newer review round before a feature or the planning can be finished. A
review starts only on content that passes verification, and a later round may
be limited to the changes since the previous one.

## Persistent state
- GitHub Issue: what/why, acceptance criteria, priority/status.
- `AGENTS.md`: durable working rules.
- `docs/architecture.md`: current system design.
- ADRs: why significant architecture decisions were made.
- `.agents/plans/`: active implementation state for complex work.
- `.agents/handoffs/`: per Issue, the implementer's continuation note for a
  session that resumes the work. A working file, ignored by Git.
- `.agents/manual-steps/`: per Issue, the steps a feature needs from the
  human; copied into the commit message and the pull request. Working files.
- `.agents/summaries/`: per Issue, the implementer's summary of the changes,
  which becomes the list of changes in the commit message. Working files.
- `.agents/run/`: the final messages of agents that ran unattended. Working
  files.
- `.agents/verification/`: the record of the last passed verification of the
  working tree. A working file.
- `docs/changes/`: one change request per change cycle of the approved
  planning.
- `.agents/reviews/`: independent-review results as validated JSON, each with a
  generated Markdown report. Working files, ignored by Git.
- `.agents/triage/`: approved finding decisions and deferred-Issue traceability
  as validated JSON, each with a generated Markdown report. Working files,
  ignored by Git.
- Feature Issue comments: the published review and triage reports of each
  round.
- `.agents/schemas/`: the schemas of those results.
- `.agents/lessons/`: recurring failure lessons awaiting/promoting durable rules.
- Git history: what actually changed.
- PR + CI: review discussion and deterministic evidence.

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

Before starting F03, review the roadmap again and only then create its Issue
with `./scripts/create-feature-issue.sh F03`, which copies the F03 block from
the roadmap into the Issue after your approval.

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
