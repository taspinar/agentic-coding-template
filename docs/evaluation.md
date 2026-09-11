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
before committing, including uncommitted working-tree changes.

- **Critical / Major:** resolve before merge and obtain a re-review when
  independent confirmation is needed.
- **Minor:** resolve before merge or defer to a linked follow-up Issue with an
  explicit reason in the review artifact or PR.
- **Suggestion:** optional unless explicitly accepted into the current scope.

After resolving findings, run `./scripts/verify.sh` again before committing.
