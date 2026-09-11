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

The approved `.agents/triage/` artifact is the source of truth for these
decisions. After resolving `FIX_NOW` findings, run `./scripts/verify.sh` again
before committing.
