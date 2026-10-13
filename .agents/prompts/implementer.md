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

Some changes only the human may approve, and a script checks the diff for
them: any ADR that is added, changed, or removed, the CI workflows, the files
of the workflow itself, a changed or removed check in `scripts/verify.conf`,
and the paths listed as protected in `.agents/policies/guardrails.conf`. Make
such a change only when the Issue asks for it. A new ADR gets the status
`Proposed`; the human accepts it by merging. Do not change the gate's
configuration or scripts to get a change through.

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

When the Issue is complete, reduce the note to one line that says so. The
scripts read the note: as long as it lists work under "Remaining", the feature
does not count as complete (see "Completion").

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

A session that ends is not an Issue that is complete. The scripts that follow
decide from what you record, not from the fact that you stopped: they go on to
the review, the commit, and the pull request only when your completion record
says `complete`, and a pull request closes the Issue only then.

**Write the completion record before you end, every session**, also when you
stop partway, run out of time, or are blocked:
`.agents/completion/<issue-number>.json`. Git ignores the file.

```json
{
  "schema": "completion/v1",
  "status": "partial",
  "criteria": [
    {"criterion": "Recipes can be searched by ingredient",
     "status": "met",
     "evidence": "tests/test_search.py::test_search_by_ingredient passes"},
    {"criterion": "The search page works without JavaScript",
     "status": "not_met",
     "evidence": "not started; plan step 4"}
  ],
  "remaining": ["Plan steps 4 to 6: the page without JavaScript, the documentation"]
}
```

- `criteria`: one entry for every acceptance criterion of the Issue, in its
  words, and for every step of the feature plan that no criterion covers.
  `status` is `met`, `not_met`, or `not_applicable`. `evidence` names what
  shows it: a test, a file and what it holds, a command and its result. For
  `not_met` say where the work stands; for `not_applicable` say why.
- `status`:
  - `complete`: every criterion is met or not applicable, and nothing
    remains. Claim it only for what the code and the tests show: an
    independent reviewer checks every criterion against the diff, and an
    unsupported claim comes back as a finding.
  - `partial`: work remains, whatever the reason. Say what in `remaining`.
    This is the honest answer when a session ends early; the implementer is
    then started again and continues from your handoff note.
  - `blocked`: you cannot complete the Issue without a decision of the
    human. Say why in `remaining`, record the question under "Open
    questions" in the handoff note, and in an unattended session end with
    the `BLOCKED:` line.
- `remaining`: what is left, empty only for `complete`.

Keep the handoff note in agreement with it: remaining work listed there
counts as not complete, whatever the record says.

Before declaring the issue complete:

1. Inspect `git diff`.
2. Verify every acceptance criterion in the GitHub Issue, and every step of
   the plan.
3. Check for unrelated changes.
4. Record the manual steps, the summary of the changes, and the completion
   record with status `complete`, as described here and below.
5. Finish every edit to a file that Git tracks, including the plan.
6. Run `./scripts/verify.sh` as the last thing that touches the repository.
7. Report the result, with compact verification evidence and unresolved
   issues or risks, in your final message.

The order of the last steps matters. A pass is recorded for exactly the
content it verified, and the scripts that follow reuse it instead of running
every check again. Any later change to a tracked file, also a note in the
plan about the verification itself, makes the record stale and costs another
full run. Evidence of the final run therefore belongs in your final message
or in the handoff note, which Git ignores, not in a tracked file. While you
work, run the single checks you need; the full run is for the end.

A manual step is something only the human can do and without which the
feature does not work after the merge: a repository or account setting, a
secret, a service to enable, a one-time command on their machine. Write them
to `.agents/manual-steps/<issue-number>.md`, one step per line starting with
`- `, each with where to do it and why. Put nothing else in that file, and do
not create it when the feature needs no manual step. `scripts/finish-feature.sh`
shows the steps to the human and records them in the commit and the pull
request.


Do not claim completion when verification fails.

The summary of the changes goes into the commit message. Write it to
`.agents/summaries/<issue-number>.md`: two to six lines that each start with
`- ` and say what changed and why it matters, in plain words, not a list of
files. Git ignores the file, so writing it does not change what was verified.

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
