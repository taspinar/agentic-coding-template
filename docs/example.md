# Worked example

A complete run of the workflow with a small sample project: a recipe box that
a household shares. The repository is called `recipe-box`. Agent output
differs per run; the prompts, files, and checks shown here are what the
scripts produce.

The flow diagrams are in `docs/workflow.md`; every option is in
`docs/development.md`.

## 0. Prepare the repository

Create `recipe-box` from the template, complete `docs/repository-setup.md`,
and check your machine:

```bash
./scripts/doctor.sh
```

Every line should read `OK`. A missing agent CLI that `.agents/agents.conf`
assigns to a role is `FAILED`. Set each role to a provider and model your
accounts support, for example:

```text
project-grill: claude fable
project-planner: claude fable
planning-reviewer: codex gpt-6-astra
implementer: codex gpt-6-astra
reviewer: claude fable
triage: claude fable
triage-implementer: codex gpt-6-astra
```

Write the idea down, anywhere, in a few sentences:

```text
A web app where a household keeps its shared recipes and plans the meals for
the week. It should work on a phone in the kitchen.
```

## 1. Plan the project

```bash
./scripts/start-planning.sh --description ~/notes/recipe-box.md
```

The script creates the branch `planning/project-bootstrap` in
`../recipe-box-planning-project-bootstrap` and copies the idea to
`docs/PROJECT_DESCRIPTION.md` there.

**Project Grill** reads the idea and asks only what it leaves open, for example
whether members need accounts, whether the plan is shared live, and whether the
MVP needs offline use. It writes `docs/PROJECT_REQUIREMENTS.md` and the script
shows it:

```text
Approve these project requirements and continue to architecture planning? [y/N]
```

After `y`, the **project planner** writes `docs/architecture.md`,
`docs/roadmap.md` with features such as `F01 — Recipes` and
`F02 — Weekly meal plan`, and ADRs where a decision needs a record. The script
ends with:

```text
Project bootstrap planning completed.
Next, in the planning worktree, review the planning with an independent agent:
```

## 2. Review and revise the planning

```bash
cd ../recipe-box-planning-project-bootstrap
./scripts/review-planning.sh
```

The planning reviewer reads the documents read-only. The script reports the
verdict, for example `Review completed: CHANGES REQUIRED (2 findings)`, and the
report lists findings such as:

```text
M1 [major] Household access is required but no feature plans it
MIN1 [minor] F02 has no acceptance criterion for an empty week
```

They are stored in `.agents/reviews/planning-project-bootstrap-review-01.json`
and a readable `.md` report next to it. The script suggests the next step:

```bash
./scripts/revise-planning.sh --review .agents/reviews/planning-project-bootstrap-review-01.json
```

The planner first decides per finding, read-only, and you see:

```text
ADOPT
- M1 [major] Household access is required but no feature plans it — The requirements make access per household part of the MVP.
REJECT
- MIN1 [minor] F02 has no acceptance criterion for an empty week — An empty week is the default state and covered by F02's criteria.
...
Record these decisions and revise the planning for the adopted findings? [y/N]
```

After `y`, the decisions are recorded in `…-review-01-revision.json` and the
planner changes only the architecture, roadmap, and ADRs, for example by adding
`F03 — Household access`. The review is now stale, so run round 2:

```bash
./scripts/review-planning.sh
```

Repeat until a round passes, or until its remaining minor findings are
rejected or deferred.

## 3. Approve and merge the planning

```bash
./scripts/finish-planning.sh
```

The script checks that the latest round is current and resolved, shows every
finding that was not adopted with its rationale, and asks:

```text
Approve this planning? [y/N]
```

It records `docs/PLANNING_APPROVAL.md` and prints the commit steps:

```bash
./scripts/verify.sh
git add docs/PROJECT_DESCRIPTION.md docs/PROJECT_REQUIREMENTS.md docs/architecture.md docs/roadmap.md docs/decisions docs/PLANNING_APPROVAL.md
git commit -m "Plan project bootstrap"
git push -u origin planning/project-bootstrap
```

Open the planning PR, paste the summary from `docs/PLANNING_APPROVAL.md` into
its description, and merge it after CI. Remove the planning worktree from the
primary checkout:

```bash
./scripts/cleanup-worktree.sh planning/project-bootstrap
```

## 4. Start the first feature

In the primary checkout, on an up-to-date `main`:

```bash
./scripts/create-feature-issue.sh F01
```

The script checks that the planning approval still matches the roadmap, shows
the Issue it would create from the `F01` block, and asks
`Create this Issue? [y/N]`. Say the Issue is `#12`:

```bash
./scripts/start-feature.sh 12 recipes
```

This creates `feature/12-recipes` in `../recipe-box-12-recipes` and starts the
implementer there. It writes code and tests and does not commit.

## 5. Review, triage, and fix

In the feature worktree:

```bash
cd ../recipe-box-12-recipes
./scripts/review-feature.sh 12
```

The script first runs `./scripts/verify.sh` and starts the reviewer only when
it passes.

The reviewer receives the Issue and the complete diff, including uncommitted
files, and cannot change anything. The report of round 1 might list:

```text
M1 [major] Deleting a recipe removes it for other households
MIN1 [minor] Recipe titles are not trimmed
```

Triage the round:

```bash
./scripts/triage-review.sh .agents/reviews/feature-12-recipes-review-01.json
```

The triage agent proposes `FIX_NOW` for `M1` and, for example, `DEFER` for
`MIN1` with a follow-up Issue titled `[F01][R01][MIN1] Trim recipe titles`.
After `Proceed with this triage? [y/N]`, the script creates that follow-up
Issue and publishes the review and triage reports as one comment on `#12`.

Fix the approved scope:

```bash
./scripts/apply-triage.sh .agents/triage/feature-12-recipes-review-01-triage.json
```

After `Start a write-capable codex agent for this scope? [y/N]`, the
implementer resolves only `M1`, and the script runs `./scripts/verify.sh`. The
code changed, so review round 1 is stale; run round 2:

```bash
./scripts/review-feature.sh 12
```

When round 2 passes, there is nothing to triage.

## 6. Finish the feature

```bash
./scripts/finish-feature.sh 12 "Add recipes"
```

The script runs the verification and checks that round 2 is current and that
round 1's triage was published. Your editor opens with:

```text
Add recipes

Issue: #12

Changes:
- TODO: summarize the main changes

Verification:
- ./scripts/verify.sh passed

Manual steps:
- none

Review: round 2, PASS, by claude (fable); triage published on #12

Refs #12
```

Replace the TODO, save, and close the editor. Then:

```bash
./scripts/publish-feature.sh 12
```

It pushes the branch, opens a pull request that closes Issue #12, and waits
for CI. Merge the pull request when it reports that all checks passed. Remove
the worktree from the primary checkout:

```bash
./scripts/cleanup-worktree.sh 12
```

The next feature starts again at step 4 with `create-feature-issue.sh F02`.

## Where everything ended up

| Item | Where |
|---|---|
| Idea, requirements, architecture, roadmap, ADRs, planning approval | `docs/`, committed with the planning PR |
| Planning reviews and revisions | `.agents/reviews/` in the planning worktree, not committed; summarized in `PLANNING_APPROVAL.md` |
| Feature Issue `#12` and follow-up Issue for `MIN1` | GitHub |
| Feature reviews and triage | `.agents/` in the feature worktree, not committed; published as a comment on `#12` |
| Code, tests, and the fix for `M1` | The commit made by `finish-feature.sh`, merged with the feature PR |
