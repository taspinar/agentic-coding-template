# Agentic Coding Template

A lightweight, model-agnostic repository template for agentic software engineering. It applies the useful parts of GH-600 at individual/small-team scale: plan → act → evaluate, GitHub as control plane, isolated execution, explicit agent contracts, risk-based autonomy, evidence, independent review, CI, and human gates for high-risk actions.

## Start a new project
1. Create a repository from this GitHub template (or clone it and point it at a new remote).
2. Record the initial project idea in `README.md`, complete
   `docs/repository-setup.md`, and configure the new remote.
3. Start the two-phase project bootstrap with an explicit agent and model:

   ```bash
   ./scripts/start-planning.sh codex astra
   # or
   ./scripts/start-planning.sh claude fable
   ```

   The script creates `planning/project-bootstrap` in a sibling worktree. The
   first interactive session runs Project Grill and drafts
   `docs/PROJECT_REQUIREMENTS.md`. After you explicitly approve those
   requirements, a separate project-planning session creates the architecture,
   necessary ADRs, and roadmap. The script does not commit or push.
4. Review the planning worktree, run `./scripts/verify.sh`, commit and push the
   planning branch, then merge it through a PR before feature development.
5. Create a GitHub Issue only for the next actionable roadmap feature. For
   non-trivial work, create `.agents/plans/<issue>-<slug>.md` using
   `.agents/prompts/planner.md`.
6. Start the feature and implementation agent:

   ```bash
   ./scripts/start-feature.sh 12 player-movement codex
   ```

   This creates `feature/12-player-movement` in an isolated worktree and starts the selected `codex` or `claude` agent there.
7. In the feature worktree, verify and run an independent review when required by `.agents/policies/autonomy.md`:

   ```bash
   ./scripts/verify.sh
   ./scripts/review-feature.sh 12 claude
   ./scripts/triage-review.sh \
     .agents/reviews/feature-12-player-movement-review-01.md \
     codex
   ```

8. Approve the proposed triage and apply its `FIX_NOW` scope:

   ```bash
   ./scripts/apply-triage.sh \
     .agents/triage/feature-12-player-movement-review-01-triage.md \
     codex
   ```

   The script starts a write-capable agent only after confirmation and verifies
   the resulting implementation.
   Approved `DEFER` findings become linked follow-up Issues; `ACCEPT` findings
   retain their rationale in the triage artifact.
9. Commit, push, and open a PR containing `Closes #12`. After CI and required gates pass, merge the PR and clean up the worktree.

See `docs/development.md` for commands, `docs/agentic-workflow.md` for the lifecycle, and `.agents/policies/` for boundaries.
