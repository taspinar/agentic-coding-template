# Evaluation

Substantial changes are evaluated against:
- **Correctness:** acceptance criteria and expected behavior.
- **Tests:** appropriate unit/integration/e2e coverage.
- **Architecture:** boundaries and accepted ADRs remain intact.
- **Security:** authorization, validation, secrets, and least privilege.
- **Reliability:** failure paths, retries/timeouts where relevant.
- **Maintainability:** focused changes, reuse of established patterns, no unnecessary complexity.
- **Buildability:** `./scripts/verify.sh` passes.

Review depth should follow `.agents/policies/autonomy.md`.

## Meaningful tests

Tests exist to catch behavior that must not regress. Add or keep a test when it
protects:

- an approval or confirmation gate;
- a scope or permission boundary;
- the ordering of workflow phases;
- propagation of a failure to the caller;
- an acceptance criterion of the Issue.

Do not add tests that only pin message wording, formatting, or layout. Assert
on output text only as far as needed to tell one failure class from another.
A test that would still pass after the behavior it names is broken is not
meaningful; fix or remove it.

Reviewers apply the same principle: report missing coverage of the behaviors
above, and report tests that only fix wording as unnecessary.

## Review findings

When independent review is required, run it against the complete implementation
before committing, including uncommitted working-tree changes. Then run
`./scripts/triage-review.sh` against the explicit review artifact and approve or
decline the proposed decisions.

- **Critical / Major:** classify as `FIX_NOW`, resolve before merge, and obtain
  a re-review when independent confirmation is needed.
- **Minor:** classify as `FIX_NOW`, `DEFER`, or `ACCEPT`. Deferral creates a
  linked follow-up Issue after human approval.
- **Suggestion:** classify explicitly; it may be deferred when worthwhile or
  accepted with a rationale.

The approved `.agents/triage/*.json` artifact is the source of truth for these
decisions. Use `./scripts/apply-triage.sh` to hand only its `FIX_NOW` scope to a
write-capable implementation agent. The helper verifies the result but does not
commit it. The fixes make the review stale, so run a new review round before
committing: complete, or with `--changes` after a small, local fix.
