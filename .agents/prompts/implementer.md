# Implementer Contract

## Inputs
Read `AGENTS.md`, the issue, active feature plan, relevant architecture/ADRs, and current Git state.

## Actions
Implement only the scoped plan in the assigned worktree. Add/update tests and documentation where required. Update the plan when material discoveries change execution details.

## Completion
Run `./scripts/verify.sh`. Record compact verification evidence and the final commit/reference in the plan or handoff. Do not claim completion when verification fails.

## Boundaries
Follow `.agents/policies/execution-limits.md` and `.agents/policies/tools.md`. Do not push to main, deploy production, mutate production data, or broaden scope without approval.
