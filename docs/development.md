# Development

## Prerequisites

- Git
- GitHub CLI (`gh`), installed and authenticated
- Codex or Claude CLI when that agent is selected
- Project-specific tools documented in this file after the template is adopted

Keep `./scripts/verify.sh` as the stable verification entry point for humans,
agents, and CI.

## Project bootstrap workflow

Run project bootstrap from a clean checkout after recording the initial project
idea and completing `docs/repository-setup.md`:

```bash
./scripts/start-planning.sh codex astra
```

Or use Claude:

```bash
./scripts/start-planning.sh claude fable
```

The full interface is:

```text
./scripts/start-planning.sh <agent> <model> [name]
```

The optional name defaults to `project-bootstrap`. A custom planning cycle such
as:

```bash
./scripts/start-planning.sh codex astra architecture-refresh
```

creates `planning/architecture-refresh` in a sibling worktree named
`../<repository>-planning-architecture-refresh`.

The script fetches `origin/main` and creates the planning branch from that
remote ref without switching or modifying the primary checkout. It refuses a
dirty checkout, unsafe name, missing agent or prompt, unavailable base,
duplicate branch, or existing target path.

Bootstrap has two separate interactive agent sessions:

1. Project Grill reads the project context, asks only questions that materially
   affect product or technical direction, and refines
   `docs/PROJECT_REQUIREMENTS.md` in Draft state.
2. The script validates and displays the requirements. It records Approved
   status and a UTC timestamp only after explicit human confirmation.
3. A fresh project-planner session consumes the approved requirements and
   creates or updates `docs/architecture.md`, `docs/roadmap.md`, and only
   necessary ADRs under `docs/decisions/`.

Declining requirements approval or an agent failure stops the workflow and
leaves the planning worktree intact. Inspect or revise it there; the script
never substitutes another model or removes user work automatically.

After successful planning, review the artifacts and complete the process
manually:

```bash
cd ../<repository>-planning-project-bootstrap
./scripts/verify.sh
git add docs/PROJECT_REQUIREMENTS.md docs/architecture.md docs/roadmap.md docs/decisions
git commit -m "Plan project bootstrap"
git push -u origin planning/project-bootstrap
```

Open and merge a planning PR before creating Issues for actionable roadmap
features. The script never implements features, creates Issues, commits,
pushes, opens or merges a PR, or deploys.

## Canonical feature workflow

Start with an actionable GitHub Issue. Create a detailed implementation plan
under `.agents/plans/` for non-trivial work when warranted.

From a clean primary checkout, create the feature worktree and start the
implementation agent:

```bash
./scripts/start-feature.sh 12 player-movement codex
```

The full interface is:

```text
./scripts/start-feature.sh <issue> <slug> <agent> [base-branch] [model]
```

Supported agents are `codex` and `claude`. The script fetches the selected
remote base, creates `feature/<issue>-<slug>` in a sibling worktree, and starts
the agent inside that worktree. For Codex, it uses workspace-write mode and
disables interactive approval prompts. The optional model argument is currently
forwarded only to Codex:

```bash
./scripts/start-feature.sh 12 player-movement codex main gpt-5.6
```

After the implementation agent exits, enter the feature worktree and verify:

```bash
cd ../project-12-player-movement
./scripts/verify.sh
```

When independent review is required by `.agents/policies/autonomy.md`, run it
before committing so the reviewer includes the complete working-tree changes:

```bash
./scripts/review-feature.sh 12 claude
```

The full interface is:

```text
./scripts/review-feature.sh <issue> <agent> [base-branch] [model]
```

The review script must run from the matching feature worktree. It writes
numbered artifacts without overwriting earlier reviews:

```text
.agents/reviews/feature-12-player-movement-review-01.md
.agents/reviews/feature-12-player-movement-review-02.md
```

Triage an explicit review artifact with an agent independent from the
implementation:

```bash
./scripts/triage-review.sh \
  .agents/reviews/feature-12-player-movement-review-01.md \
  codex
```

The full interface is:

```text
./scripts/triage-review.sh <review-file> <agent> [model]
```

The triage agent classifies every finding as:

- `FIX_NOW`: resolve before the feature proceeds. Critical and Major findings
  always use this category.
- `DEFER`: valid non-blocking work proposed as a separate follow-up Issue.
- `ACCEPT`: consciously take no action, with an explicit rationale.

The script displays the complete proposal before side effects. Only after
interactive approval does it create one GitHub Issue per `DEFER` finding and
write a persistent, uniquely named artifact such as:

```text
.agents/triage/feature-12-player-movement-review-01-triage.md
```

That artifact maps the source review findings to their decisions and any
created Issue numbers. Declining the proposal creates neither an artifact nor
Issues. The source review remains unchanged. A separate `create-followups.sh`
is therefore not needed.

Deferred follow-up Issue titles include deterministic provenance:

```text
[F02][R01][S9] Concise follow-up title
```

The script obtains the feature ID from the source Issue title, the review round
from the review filename, and the finding ID from the review. When no feature
ID is available, it falls back to the source Issue number:

```text
[#12][R01][S9] Concise follow-up title
```

Apply the approved `FIX_NOW` set from the same feature worktree:

```bash
./scripts/apply-triage.sh \
  .agents/triage/feature-12-player-movement-review-01-triage.md \
  codex
```

The full interface is:

```text
./scripts/apply-triage.sh <triage-file> <agent> [model]
```

The helper validates the approved artifact and source review, shows the exact
`FIX_NOW` scope, and asks for confirmation before starting a write-capable
agent. It never passes `DEFER` or `ACCEPT` findings to that agent. After the
agent exits, it verifies that the review and triage artifacts are unchanged and
runs `./scripts/verify.sh`.

The helper does not commit, push, merge, deploy, or create/close Issues. Inspect
the resulting diff and run another independent review and triage when fixes
require confirmation.

Verify again after review fixes, then commit and push:

```bash
./scripts/verify.sh
git add .
git commit -m "Implement player movement"
git push -u origin feature/12-player-movement
```

Open a PR containing `Closes #12`. After CI and required human gates pass,
merge it; GitHub then closes the linked Issue. From the primary checkout,
remove the merged worktree:

```bash
./scripts/cleanup-worktree.sh ../project-12-player-movement
```

## Linking a feature plan

To add or update the plan reference in an existing Issue:

```bash
./scripts/update-issue-with-plan.sh 12 .agents/plans/12-player-movement.md
```

The helper manages one delimited plan block in the Issue body. Re-running it
updates that block instead of appending duplicates. It stores only the
repository-relative plan path; the detailed plan remains in `.agents/plans/`.

## Lifecycle summary

Roadmap item → GitHub Issue → optional implementation plan → isolated feature
worktree → implementation → verification → independent review when required →
triage → apply approved `FIX_NOW` findings → verification/re-review when needed
→ commit → push/PR → CI and gates → merge → automatic Issue closure → worktree
cleanup.

Do not use `scripts/finish-feature.sh` as part of this flow until it has been
redesigned or deprecated; its interface predates the current review script.
