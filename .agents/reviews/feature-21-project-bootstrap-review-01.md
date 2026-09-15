# Independent Review — feature/21-project-bootstrap

Issue: #21
Base: `origin/main` (`3f2c9b896f4e23b7ed5c250f51646398e8582886`)

## Critical

None.

## Major

### M1. Phase scope enforcement ignores commits made by an agent

`scripts/start-planning.sh:244-251` and `scripts/start-planning.sh:284-298` enforce the Grill and planner write boundaries only through `git status --porcelain`. The script never records or rechecks the planning branch HEAD. A write-capable agent can therefore commit an out-of-scope file, after which that file disappears from `git status`; as long as the planner also leaves one allowed planning change uncommitted, the workflow can report success. The same bypass permits the prohibited commit side effect itself.

This defeats the central no-commit and artifact-scope guarantees for both phases.

Recommended action: record HEAD immediately after worktree creation and require it to remain unchanged after each agent session. Validate the complete diff from that immutable base, including committed, staged, unstaged, untracked, renamed, and mode changes, against each phase's allowlist.

### M2. Approved-requirements integrity ignores file type and mode

`scripts/start-planning.sh:275-281` protects the approved requirements with `git hash-object`, which covers content only. The planner scope allowlist at `scripts/start-planning.sh:284-298` explicitly allows the requirements path. A planner can therefore change `docs/PROJECT_REQUIREMENTS.md` from a regular file to a symlink, or change its mode, while retaining identical content; the signature check passes and the allowed-path check does not reject it.

The planner contract says the approved artifact must not be modified, and approval integrity must include the complete Git object state, not only blob bytes.

Recommended action: require a regular non-symlink file, capture and compare its file type and mode as well as content, and reject any Git status/diff entry for the requirements path after planner launch.

### M3. Approval replacement is not atomic on common Linux layouts

`scripts/start-planning.sh:223-239` creates the approval temporary file under `${TMPDIR:-/tmp}` and then moves it into the worktree. On Linux, `/tmp` is commonly a separate filesystem (often `tmpfs`), so `mv` degrades to copy-and-delete rather than an atomic rename. An interruption can expose a partially replaced approved artifact, contrary to the plan's explicit atomic-update requirement.

Recommended action: create the temporary file in `docs/` beside `PROJECT_REQUIREMENTS.md`, install the desired mode, and rename it over the target on the same filesystem. Add cleanup for an interrupted or failed replacement.

### M4. Requirements validation accepts empty and duplicate sections

`scripts/start-planning.sh:180-216` checks only that each required heading occurs at least once and that the template marker is absent. A Grill result containing every heading with no content passes. Duplicate required headings also pass. The planner is then launched even though the Issue requires a structurally usable requirements artifact containing the required project-level information.

Recommended action: parse the document structure, require every heading exactly once, and require non-whitespace content before the next heading (allowing an explicit `None.` only where valid). Add empty-section and duplicate-heading integration cases.

### M5. Planner success can leave a required artifact as the untouched template

At `scripts/start-planning.sh:301-309`, the existing nonempty template satisfies the architecture or roadmap existence check, while `planning_changes` requires only one of architecture, roadmap, or ADRs to change. A planner that changes only `docs/roadmap.md` and leaves the placeholder `docs/architecture.md` untouched is reported as successful; the inverse is also accepted.

Issue #21 requires project planning to produce both architecture and roadmap artifacts from the approved requirements.

Recommended action: require both `docs/architecture.md` and `docs/roadmap.md` to be changed from the worktree's base and reject known template placeholders. Test each missing/untouched artifact independently.

### M6. The integration fixture depends on user-specific Git default-branch configuration

`tests/start-planning-test.sh:179-183` initializes a bare remote without `-b main`, pushes `main`, and immediately clones it. On systems whose default initial branch is `master`, the bare remote's HEAD still targets `refs/heads/master`; clone emits `remote HEAD refers to nonexistent ref` and creates no checkout. Running the test with system/global Git configuration disabled reproduced this failure at line 197.

This makes the advertised macOS/Linux verification path environment-dependent.

Recommended action: initialize the bare remote with `git init --bare -b main` or explicitly set its symbolic HEAD to `refs/heads/main` before cloning. Run this suite in CI with isolated Git configuration.

### M7. Safety-critical failure paths in the plan are not covered

The fake agent supports `MOCK_GRILL_MODE=fail` at `tests/start-planning-test.sh:44-47`, but no test invokes it. The suite also lacks the plan's promised cases for unknown agent, invalid name/option-like model, missing CLI, missing prompts, unavailable `origin/main`, duplicate local branch, and existing/dangling target path. Nevertheless, `.agents/plans/21-project-bootstrap.md:274-284` records the focused suite and verifier as complete evidence.

These are the preconditions intended to prevent unsafe branch/worktree creation and fallback or phase-ordering errors.

Recommended action: add isolated assertions for the promised safety paths, including exact exit status, absence/preservation of branch and worktree resources as appropriate, phase invocation count, and actionable diagnostics. Update verification evidence to match the tests actually run.

## Minor

### Minor 1. Several post-creation failures omit preservation and continuation guidance

The failures at `scripts/start-planning.sh:212-214` and `scripts/start-planning.sh:301-309` do not print the preserved worktree location or a safe next action. Agent failure and decline messages identify the location, but also stop short of explaining how to inspect or continue. This is inconsistent with the plan's actionable-failure requirement and the documentation's statement that users can inspect or revise preserved work.

Recommended action: centralize post-creation failure reporting so every path states the worktree location and concrete safe inspection/continuation steps.

### Minor 2. Model syntax validation is narrower than documented

`scripts/start-planning.sh:35-42` rejects only empty/option-like values and two known cross-provider aliases. Other whitespace or control-character model values are forwarded, despite the plan describing safe-syntax validation before provider dispatch.

Recommended action: define and enforce a conservative provider-neutral model identifier syntax while continuing to forward valid unknown identifiers unchanged.

## Suggestions

None.

## Verdict

CHANGES REQUIRED
