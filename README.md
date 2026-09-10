# Agentic Coding Template

A lightweight, model-agnostic repository template for agentic software engineering. It applies the useful parts of GH-600 at individual/small-team scale: plan → act → evaluate, GitHub as control plane, isolated execution, explicit agent contracts, risk-based autonomy, evidence, independent review, CI, and human gates for high-risk actions.

## Start a new project
1. Create a repository from this GitHub template (or clone it and point it at a new remote).
2. Replace placeholder project information in `README.md`, `docs/architecture.md`, and `.env.example`.
3. Ask a planning agent to inspect the repo and create `docs/roadmap.md`, update `docs/architecture.md`, and propose only necessary ADRs. Do **not** create detailed plans for every future feature.
4. Create GitHub Issues for actionable features.
5. For a selected non-trivial issue, create `.agents/plans/<issue>-<slug>.md` using `.agents/prompts/planner.md`.
6. Run `./scripts/start-feature.sh <issue> <slug>` to create an isolated worktree.
7. Start an implementation agent in that worktree using `.agents/prompts/implementer.md`.
8. Run `./scripts/verify.sh`, commit a stable implementation, then run an independent review using `.agents/prompts/reviewer.md` (or configure `review-feature.sh`).
9. Address findings, verify again, push, open a PR, let GitHub Actions run, then merge after the appropriate human gate.

See `docs/agentic-workflow.md` for the lifecycle and `.agents/policies/` for boundaries.
