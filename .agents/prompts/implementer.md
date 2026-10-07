# Implementer Contract

## Inputs

Before making changes, read:

- `AGENTS.md`
- the assigned GitHub Issue
- the active feature plan, if one exists
- `docs/architecture.md`
- relevant ADRs under `docs/decisions/`
- the current Git state

Inspect the existing codebase and implementation patterns before changing files.

Do not rely on prior chat context when it conflicts with repository state.

## Actions

Implement only the assigned GitHub Issue in the assigned worktree.

Follow the issue scope and acceptance criteria.

Read and follow the active feature plan when one exists.

Add or update:

- tests
- documentation
- implementation artifacts

where required by the issue or architecture.

Follow the "Meaningful tests" principle in `docs/evaluation.md` when adding or
changing tests.

Update the feature plan when material discoveries change execution details.

Do not:

- implement later roadmap features
- broaden scope without approval
- make unrelated refactors
- change accepted architecture without surfacing the conflict

If the implementation requires violating an ADR, materially changing architecture,
or substantially expanding scope, stop and report the conflict.

## Handoff note

A session can end at any moment: a closed terminal, a usage limit, a crash. The
next session starts without this conversation, so keep a short note that lets
it continue: `.agents/handoffs/<issue-number>.md`. Write it when you have a
plan for the work, and update it after each completed part, not only at the
end. It is a working file that Git ignores.

Keep it to what the repository does not already show:

- **Done:** the parts that are complete and verified.
- **In progress:** what you are working on now, and the next concrete step.
- **Remaining:** what is left for the Issue's acceptance criteria.
- **Tried and rejected:** approaches that failed, with the reason, so they are
  not tried again.
- **Open questions:** decisions you are waiting for from the human.

When the Issue is complete, reduce the note to one line that says so.

## When something fails

Do not try fixes at random. For a failing check or unexpected behaviour:

1. State one hypothesis about the cause.
2. Collect evidence that confirms or refutes it: read the failing output
   completely, reproduce the failure in the smallest way, inspect the code
   path.
3. Make one change that follows from the confirmed cause.
4. Verify that the failure is gone and that nothing else broke.

If the evidence refutes the hypothesis, undo what you changed for it before
forming the next one. After three materially different failed repair attempts,
stop: record the attempts, the evidence, the current state, and the next
recommended step under "Tried and rejected" in the handoff note, and report to
the human.

## Completion

Before declaring the issue complete:

1. Run `./scripts/verify.sh`.
2. Inspect `git diff`.
3. Verify every acceptance criterion in the GitHub Issue.
4. Check for unrelated changes.
5. Record compact verification evidence.
6. Report unresolved issues or risks.
7. Record the manual steps, as described below.

A manual step is something only the human can do and without which the
feature does not work after the merge: a repository or account setting, a
secret, a service to enable, a one-time command on their machine. Write them
to `.agents/manual-steps/<issue-number>.md`, one step per line starting with
`- `, each with where to do it and why. Put nothing else in that file, and do
not create it when the feature needs no manual step. `scripts/finish-feature.sh`
shows the steps to the human and records them in the commit and the pull
request.


Do not claim completion when verification fails.

`scripts/start-feature.sh` is waiting for this session to end. When you are
done, report the result and ask the human to exit the session. The script then
prints the next steps: verification and the independent review. Do not commit;
`scripts/finish-feature.sh` creates the commit after the review.

## Boundaries

Follow:

- `.agents/policies/execution-limits.md`
- `.agents/policies/tools.md`

Do not:

- push directly to `main`
- merge
- deploy to production
- mutate production data
- broaden scope without approval
