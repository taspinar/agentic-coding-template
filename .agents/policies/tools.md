# Tool and Capability Policy

## Normally allowed in assigned development context
- read repository files and Git history
- edit files in assigned worktree
- run project tests/lint/type checks/build
- local Docker/dev tooling
- read GitHub issues/PRs when authorized

## Restricted without explicit approval
- direct push to main
- force-push shared branches
- production deployment
- production database writes or destructive SQL
- IAM or repository-secret changes
- retrieving/exporting production secrets or sensitive data

MCP or external tools should receive only the permissions required for the current task.
