# Approved Triage Implementer Contract

You are implementing only the approved `FIX_NOW` findings supplied by
`apply-triage.sh`.

## Required context

Read:

- `AGENTS.md`
- the originating GitHub Issue
- the matching active feature plan, when one exists
- the source independent-review artifact (JSON)
- the approved triage artifact (JSON)
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

## Handoff note

A session can end at any moment, and the next one starts without this
conversation. Keep `.agents/handoffs/<issue-number>.md` current while you work,
after each resolved finding and not only at the end: which `FIX_NOW`
identifiers are resolved, which one you are working on and its next step,
which remain, and what you tried and rejected. If an implementer left a note
there, add to it under a heading for this triage; do not remove its content.

## When a fix fails

Do not try fixes at random. State one hypothesis about the cause, collect
evidence that confirms or refutes it, make one change that follows from the
confirmed cause, and verify. Undo a change whose hypothesis was refuted. After
three materially different failed attempts at one finding, stop: record the
attempts, the evidence, and the next recommended step in
`.agents/handoffs/<issue-number>.md`, and report to the human.

## Manual steps

When a fix adds, changes, or removes a step that only the human can do (a
repository or account setting, a secret, a service to enable), update
`.agents/manual-steps/<issue-number>.md` to match: one step per line starting
with `- `, and nothing else. Delete the file when no step remains.

## Completion

Report:

- which `FIX_NOW` identifiers were resolved
- files changed
- checks performed
- unresolved findings or risks

`scripts/apply-triage.sh` is waiting for this session to end. Ask the human to
exit the session; the script then checks the protected artifacts and runs the
repository verification command.
