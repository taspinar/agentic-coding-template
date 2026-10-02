# Agentic Coding Template

A lightweight, model-agnostic repository template for agentic software engineering. It applies the useful parts of GH-600 at individual/small-team scale: plan → act → evaluate, GitHub as control plane, isolated execution, explicit agent contracts, risk-based autonomy, evidence, independent review, CI, and human gates for high-risk actions.

## Start a new project
1. Create a repository from this GitHub template (or clone it and point it at a new remote).
   Then check that your machine has the required tools:

   ```bash
   ./scripts/doctor.sh
   ```
2. Record the initial project idea in `README.md`, complete
   `docs/repository-setup.md`, and configure the new remote. Set the agent and
   model of each workflow role in `.agents/agents.conf` to ones your accounts
   support.
3. Start the two-phase project bootstrap:

   ```bash
   ./scripts/start-planning.sh
   # or, with an existing project description:
   ./scripts/start-planning.sh --description path/to/description.md
   ```

   The script creates `planning/project-bootstrap` in a sibling worktree. The
   first interactive session runs Project Grill and drafts
   `docs/PROJECT_REQUIREMENTS.md`. After you explicitly approve those
   requirements, a separate project-planning session creates the architecture,
   necessary ADRs, and roadmap. The script does not commit or push.
4. In the planning worktree, review and revise the planning until the review
   passes, then approve it:

   ```bash
   ./scripts/review-planning.sh
   ./scripts/revise-planning.sh --review .agents/reviews/planning-project-bootstrap-review-01.json
   ./scripts/review-planning.sh
   ./scripts/finish-planning.sh
   ```

   Commit and push the planning branch as `finish-planning.sh` shows, then merge
   it through a PR before feature development.
5. Create a GitHub Issue only for the next actionable roadmap feature, from its
   block in `docs/roadmap.md`:

   ```bash
   ./scripts/create-feature-issue.sh F01
   ```

   For non-trivial work, create `.agents/plans/<issue>-<slug>.md` using
   `.agents/prompts/planner.md`.
6. Start the feature and implementation agent:

   ```bash
   ./scripts/start-feature.sh 12 player-movement
   ```

   This creates `feature/12-player-movement` in an isolated worktree and starts the configured implementation agent there.
7. In the feature worktree, verify and run an independent review when required by `.agents/policies/autonomy.md`:

   ```bash
   ./scripts/verify.sh
   ./scripts/review-feature.sh 12
   ./scripts/triage-review.sh \
     .agents/reviews/feature-12-player-movement-review-01.json
   ```

8. Approve the proposed triage and apply its `FIX_NOW` scope:

   ```bash
   ./scripts/apply-triage.sh \
     .agents/triage/feature-12-player-movement-review-01-triage.json
   ```

   The script starts a write-capable agent only after confirmation and verifies
   the resulting implementation.
   Approved `DEFER` findings become linked follow-up Issues; `ACCEPT` findings
   retain their rationale in the triage artifact.
9. After a new review round confirms the fixes, commit with the closing checks:

   ```bash
   ./scripts/finish-feature.sh 12 "Implement player movement"
   ```

   Then push and open a PR containing `Closes #12`. After CI and required gates pass, merge the PR and clean up the worktree.

See `docs/development.md` for commands, `docs/agentic-workflow.md` for the lifecycle, and `.agents/policies/` for boundaries.
