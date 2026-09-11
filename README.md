# Agentic Coding Template

A lightweight, model-agnostic repository template for agentic software engineering. It applies the useful parts of GH-600 at individual/small-team scale: plan → act → evaluate, GitHub as control plane, isolated execution, explicit agent contracts, risk-based autonomy, evidence, independent review, CI, and human gates for high-risk actions.

## Start a new project
1. Create a repository from this GitHub template (or clone it and point it at a new remote).
2. Replace placeholder project information in `README.md`, `docs/architecture.md`, and `.env.example`.
3. Complete `docs/repository-setup.md`, create `planning/project-bootstrap`, and ask a planning agent to create the initial roadmap and architecture artifacts. Merge that planning work through a PR before feature development.
4. Create a GitHub Issue for the next actionable feature. For non-trivial work, create `.agents/plans/<issue>-<slug>.md` using `.agents/prompts/planner.md`.
5. Start the feature and implementation agent:

   ```bash
   ./scripts/start-feature.sh 12 player-movement codex
   ```

   This creates `feature/12-player-movement` in an isolated worktree and starts the selected `codex` or `claude` agent there.
6. In the feature worktree, verify and run an independent review when required by `.agents/policies/autonomy.md`:

   ```bash
   ./scripts/verify.sh
   ./scripts/review-feature.sh 12 claude
   ./scripts/triage-review.sh \
     .agents/reviews/feature-12-player-movement-review-01.md \
     codex
   ```

7. Approve the proposed triage, resolve `FIX_NOW` findings, and verify again.
   Approved `DEFER` findings become linked follow-up Issues; `ACCEPT` findings
   retain their rationale in the triage artifact.
8. Commit, push, and open a PR containing `Closes #12`. After CI and required gates pass, merge the PR and clean up the worktree.

See `docs/development.md` for commands, `docs/agentic-workflow.md` for the lifecycle, and `.agents/policies/` for boundaries.
