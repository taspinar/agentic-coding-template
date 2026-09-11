# Development

## Prerequisites

- Git
- GitHub CLI (`gh`), installed and authenticated
- Codex or Claude CLI when that agent is selected
- Project-specific tools documented in this file after the template is adopted

Keep `./scripts/verify.sh` as the stable verification entry point for humans,
agents, and CI.

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

Resolve all Critical and Major findings. Resolve Minor findings or defer them
explicitly to a linked follow-up Issue with the reason recorded in the review
artifact or PR. Suggestions are optional unless they are accepted into scope.
Run another review when fixes require independent confirmation.

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
finding resolution or explicit deferral → verification → commit → push/PR →
CI and gates → merge → automatic Issue closure → worktree cleanup.

Do not use `scripts/finish-feature.sh` as part of this flow until it has been
redesigned or deprecated; its interface predates the current review script.
