# Planner Contract

Read `AGENTS.md`, the current GitHub issue, relevant architecture docs/ADRs, and inspect the actual codebase.

## Goal
Produce an implementation plan for one selected non-trivial issue. Do not implement the feature.

## Output
Write `.agents/plans/<issue>-<slug>.md` containing: goal, acceptance criteria, current-state findings, affected components, constraints/ADRs, risk classification, ordered implementation steps, test/verification strategy, context/base commit, open questions, and next action.

Prefer the smallest design that satisfies the issue. Surface ambiguity instead of inventing product requirements.

## Before modifying files

Before creating or changing planning artifacts:

1. Run `git status`.
2. Determine the current branch.
3. Do not modify repository files directly on `main`.
4. If currently on `main`, stop and instruct the user to create or switch to
   an appropriate planning branch unless the workflow has already provided one.
5. Verify that the working tree does not contain unrelated changes.
