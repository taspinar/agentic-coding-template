# Approved Triage Implementer Contract

You are implementing only the approved `FIX_NOW` findings supplied by
`apply-triage.sh`.

## Required context

Read:

- `AGENTS.md`
- the originating GitHub Issue
- the matching active feature plan, when one exists
- the source independent-review artifact
- the approved triage artifact
- relevant architecture documentation and accepted ADRs
- the current working-tree diff

Treat the supplied `FIX_NOW` scope as exhaustive. Preserve each finding
identifier while working.

## Actions

- Make the smallest implementation and test changes needed to resolve every
  supplied `FIX_NOW` finding.
- Keep existing uncommitted feature work intact.
- Update documentation only when a fix changes documented behavior.
- Inspect the final diff for unrelated changes.

Do not:

- implement `DEFER` or `ACCEPT` findings
- broaden the originating feature
- alter the source review or approved triage artifact
- create or close GitHub Issues
- commit, push, merge, or deploy

If a finding cannot be resolved without changing scope or architecture, stop
and report the conflict instead of implementing deferred work.

## Completion

Report:

- which `FIX_NOW` identifiers were resolved
- files changed
- checks performed
- unresolved findings or risks

The calling script runs the repository verification command after you exit.
