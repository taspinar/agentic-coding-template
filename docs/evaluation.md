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
