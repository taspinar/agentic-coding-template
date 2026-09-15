# Issue #21 — Project bootstrap planning workflow

## Goal

Upgrade `scripts/start-planning.sh` into the canonical project-bootstrap
entrypoint. It must create an isolated planning worktree, run an interactive
Project Grill with an explicitly selected agent and model, persist and validate
project requirements, require human approval, and only then run a separate
project-planning session that produces architecture, necessary ADRs, and a
roadmap.

The implementation must not perform feature implementation, create roadmap
Issues, commit, push, open a PR, merge, or deploy.

## Acceptance criteria

Use the acceptance criteria in GitHub Issue #21 as authoritative. In
particular:

- `scripts/start-planning.sh` is executable and supports
  `start-planning.sh <agent> <model> [name]`.
- `codex` and `claude` are supported with explicit model forwarding; the
  primary combinations are `codex astra` and `claude fable`.
- the script creates `planning/<name>` in a sibling worktree from the fetched
  `origin/main`, without changing the primary checkout;
- dirty state, invalid names/options, missing tools/prompts, duplicate
  branches/paths, unavailable base refs, and agent failures produce actionable
  failures without destructive cleanup;
- Project Grill runs first and creates or refines
  `docs/PROJECT_REQUIREMENTS.md`;
- requirements are structurally validated, displayed, and explicitly approved
  before the project planner can start;
- declining approval or a failed phase leaves the worktree available for
  inspection or continuation;
- the second session consumes the approved requirements and may update only the
  project-level planning artifacts;
- Codex and Claude receive equivalent phase contracts;
- automated integration tests cover creation, dispatch, ordering, approval,
  and representative failure paths;
- bootstrap documentation is synchronized, existing feature workflows remain
  unchanged, and `./scripts/verify.sh` passes.

## Current-state findings

- Base commit: `3f2c9b8` (`Add approved review triage application workflow
  (#14)`), matching `origin/main` when this plan was created.
- The existing `scripts/start-planning.sh` only checks for a clean tree,
  switches the primary checkout to `main`, pulls, and creates
  `planning/<name>` in that same checkout.
- The script is mode `100644`, accepts only an optional name, creates no
  worktree, launches no agent, and has no Grill, requirements gate, tests, or
  recovery guidance.
- `.agents/prompts/planner.md` covers both roadmap and feature planning. Its
  broad contract is useful background but does not define Project Grill or the
  approved-requirements boundary. Dedicated prompts are needed.
- `docs/architecture.md` is intentionally still a project template and there
  are no accepted project ADRs beyond `docs/decisions/README.md`.
- `docs/agentic-workflow.md` starts bootstrap directly at
  architecture/roadmap generation. `docs/development.md` documents the feature
  workflow but not concrete bootstrap commands.
- `scripts/start-feature.sh` already demonstrates sibling-worktree creation,
  explicit agent selection, argument-array construction for Codex, and
  non-destructive duplicate checks. The new planning script should use the
  same conventions without changing feature behavior.
- The installed Codex CLI accepts `--model`, `--sandbox`, `--ask-for-approval`,
  and `--cd`. The installed Claude CLI accepts `--model` and starts
  interactively by default. Claude documents `fable` as a model alias. Model
  availability ultimately depends on each authenticated CLI, so the script can
  validate syntax and known cross-provider combinations up front while the CLI
  remains authoritative for runtime availability.
- Existing verification syntax-checks all scripts and runs the review-triage
  integration tests. A new executable planning integration test can be added
  to that stable entrypoint.

## Affected components

- `scripts/start-planning.sh`
- `.agents/prompts/project-grill.md`
- `.agents/prompts/project-planner.md`
- `docs/PROJECT_REQUIREMENTS.md`
- `tests/start-planning-test.sh`
- `tests/apply-triage-test.sh` (test-isolation fix only)
- `scripts/verify.sh`
- `README.md`
- `docs/development.md`
- `docs/agentic-workflow.md`
- potentially `docs/repository-setup.md` where its bootstrap sequence needs the
  same requirements gate

No application code, feature-planning behavior, review/triage production
tooling, or GitHub Issue-generation scripts are in scope. The existing
apply-triage test receives only the branch-isolation repair required for the
stable verifier to run outside Issue #13's former feature branch.

## Constraints and design decisions

### Repository and worktree safety

- Resolve the repository root with `git rev-parse --show-toplevel`; do not
  assume the script is called from the root.
- Require a clean primary worktree before creating planning resources.
- Fetch `origin main` and branch directly from `origin/main`; do not switch,
  pull, or mutate the checked-out primary branch.
- Default the name to `project-bootstrap`. Accept a conservative lowercase
  slug (`[a-z0-9][a-z0-9-]*`) so names cannot become ref/path injection.
- Use `planning/<name>` and
  `../<repository-name>-planning-<name>`.
- Check the local branch and target path before `git worktree add`.
- Do not automatically delete a created worktree after decline or failure.
  The final message must state its location and the safe next action.

### Agent and model dispatch

- Require both agent and model arguments. Reject option-like model values and
  known cross-provider aliases such as `codex fable` and `claude astra`.
- Forward other explicit model identifiers unchanged. If the CLI rejects an
  unavailable identifier, preserve its status and report which phase,
  agent/model, and worktree failed; never retry with a fallback.
- Centralize provider-specific argument arrays in one launch function:
  - Codex: interactive session in the worktree with `--model`,
    `--sandbox workspace-write`, `--ask-for-approval never`, and `--cd`.
  - Claude: interactive session started from the worktree with `--model`.
- Build one phase-specific prompt string and pass the same substantive
  contract to either provider. A fresh session is used for project planning;
  approved requirements are the durable handoff between phases.

### Requirements artifact and approval

- Add `docs/PROJECT_REQUIREMENTS.md` as a reusable template with stable required
  headings and explicit metadata:
  - `Status: Draft`
  - `Approved at: Not approved`
- Required sections cover goal, users, use cases/journeys, MVP, non-goals, UX,
  data/persistence, auth, integrations, runtime/deployment, security/privacy,
  major decisions, and unresolved questions.
- The Grill prompt must preserve existing content, ask only material questions,
  and leave the artifact in Draft state whenever it creates or substantively
  changes it.
- After the Grill exits, validate one Draft status and all required headings.
  Display the complete artifact (and a focused Git diff when useful) before
  prompting. Only an explicit `y` or `yes` approves.
- On approval, the script changes the two metadata lines to `Status: Approved`
  and a UTC ISO-8601 timestamp. Use a temporary file and atomic move; reject
  duplicate or malformed metadata rather than guessing.
- On decline, leave Draft metadata unchanged and do not launch the planner.
- Before launching the planner, validate Approved status, timestamp, and
  required headings again.

### Project-planner boundary

- The planner prompt must require reading `docs/PROJECT_REQUIREMENTS.md`,
  `AGENTS.md`, current architecture, accepted ADRs, repository setup, and the
  actual repository.
- It may create/update only `docs/architecture.md`, `docs/roadmap.md`, and
  necessary `docs/decisions/*.md` planning artifacts.
- It must use stable roadmap IDs, state scope/dependencies/acceptance criteria/
  risk, avoid detailed plans for all future features, and surface conflicts
  instead of overriding approved requirements.
- It must not implement features, create Issues, commit, push, open PRs, merge,
  deploy, or modify the approved requirements artifact.

## Risk classification

**High workflow risk, low product risk.**

The change is shell orchestration that creates branches/worktrees and launches
write-capable interactive agents. Incorrect path/ref handling could mutate the
wrong checkout; weak phase validation could start architecture planning before
requirements approval; model fallback could violate explicit user choice.
Risk is reduced through conservative inputs, argument arrays, branch-from-
remote behavior, persistent failure state, artifact validation, and isolated
integration tests with fake agent executables.

## Ordered implementation steps

1. Add a failing `tests/start-planning-test.sh` harness using temporary local
   repositories/remotes and fake `codex`/`claude` executables. Capture arguments,
   working directories, invocation order, and controlled artifact writes
   without contacting model providers.
2. Replace `scripts/start-planning.sh` with a function-oriented implementation:
   usage/input checks, repository/CLI/prompt checks, clean-state and duplicate
   checks, `origin/main` fetch, sibling worktree creation, phase dispatch,
   actionable failure reporting, and no automatic cleanup.
3. Add `.agents/prompts/project-grill.md` with the material-question policy,
   required artifact structure, preservation rules, Draft status contract,
   scope boundaries, and a clear instruction to finish by writing the artifact.
4. Add the reusable `docs/PROJECT_REQUIREMENTS.md` template with stable
   metadata and all required sections.
5. Add validation/display/approval helpers to the script. Atomically record
   Approved status and timestamp only after explicit confirmation, then
   revalidate the approved artifact.
6. Add `.agents/prompts/project-planner.md` with approved-requirements input,
   allowed outputs, architecture/ADR/roadmap expectations, conflict behavior,
   and prohibitions on implementation and external side effects.
7. Launch the separate project-planning session only after approval. Preserve
   exact provider exit codes and print manual verify/commit/push/PR guidance
   after success.
8. Complete integration coverage for the success path for both providers,
   custom/default naming, invocation from a subdirectory, dirty checkout,
   invalid inputs and combinations, missing CLI/prompt/base, duplicate
   branch/path, malformed/missing requirements, decline, Grill failure, and
   planner failure. Assert that declined/failed runs preserve their worktree and
   never invoke later phases.
9. Add the planning test to `scripts/verify.sh` without weakening its existing
   checks.
10. Synchronize `README.md`, `docs/development.md`,
    `docs/agentic-workflow.md`, and relevant repository-setup text with the
    exact interface, two-phase bootstrap lifecycle, persistent approval gate,
    worktree location, failure/resume behavior, and manual completion steps.
11. Run syntax checks, the focused planning integration test, and
    `./scripts/verify.sh`. Inspect the complete diff for unrelated changes and
    record verification evidence here before review.
12. Run the required independent review before commit, triage every finding,
    apply approved `FIX_NOW` findings, and re-run verification/re-review as
    warranted.

## Test and verification strategy

### Automated integration scenarios

- Codex/Astra happy path: Grill precedes approval, planner follows approval,
  both run inside the worktree, model and permission flags are exact, and the
  expected planning branch starts at `origin/main`.
- Claude/Fable happy path with equivalent prompts and working directory.
- Default and custom names produce predictable branch/worktree names.
- Invocation from below the repository root still resolves paths correctly.
- Decline leaves Draft requirements and worktree intact and never starts the
  planner.
- Missing/malformed requirements block approval and planner launch.
- Approval updates exactly one status/timestamp pair and planning sees Approved
  requirements.
- Dirty checkout, invalid name/agent/model, known incompatible combination,
  missing executable/prompt, unavailable `origin/main`, duplicate branch, and
  duplicate path all fail before unsafe actions.
- Grill and planner non-zero exits are reported distinctly; no model fallback
  occurs, and later phases do not run.
- No path executes commit, push, PR, Issue creation, merge, deployment, feature
  implementation, or destructive cleanup.

### Commands

```bash
bash -n scripts/start-planning.sh tests/start-planning-test.sh
./tests/start-planning-test.sh
./scripts/verify.sh
git diff --check
```

Independent review must inspect the complete branch and working-tree diff
against `main`, including executable modes and the worktree/ref safety paths.

## Context and base commit

- Issue: `#21`
- Branch: `feature/21-project-bootstrap`
- Worktree:
  `/Users/ataspinar/Documents/projects/agentic-coding-template-21-project-bootstrap`
- Base branch/ref: `main` / `origin/main`
- Base commit: `3f2c9b8`
- Plan created: 2026-09-15

## Open questions

No blocking product questions remain.

Model identifiers beyond the primary Astra/Fable aliases cannot be completely
validated offline. The implementation will therefore validate safe syntax and
known incompatible aliases, forward explicit identifiers without substitution,
and treat the selected provider CLI as authoritative for availability. This
preserves the Issue's no-fallback requirement while remaining extensible.

## Verification evidence

- `bash -n scripts/start-planning.sh tests/start-planning-test.sh` — passed on
  2026-09-15.
- `./tests/start-planning-test.sh` — passed on 2026-09-15, covering both
  providers, phase ordering, approval/decline, malformed output, scope
  violations, agent failure, invalid combinations, dirty state, custom naming,
  subdirectory invocation, and remote branch collisions.
- `./tests/apply-triage-test.sh` — passed on 2026-09-15 after isolating its
  fixture branch from the caller's real branch.
- `./scripts/verify.sh` — passed on 2026-09-15, including triage-review,
  apply-triage, and start-planning integration suites.
- `git diff --check` — passed on 2026-09-15.

## Next action

Run independent review against the complete working-tree diff, triage every
finding, and apply approved `FIX_NOW` work before committing.
