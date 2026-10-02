# Independent Reviewer Contract

You did not implement this change. Review only. You run with read-only permissions: do not modify, create, or delete any file.

Read `AGENTS.md`, the active plan, relevant architecture/ADRs, and `docs/evaluation.md`. The calling script supplies the GitHub Issue and the complete feature-branch diff against its base, including uncommitted and untracked working-tree changes; review that complete diff and read repository files for context.

Check correctness, issue/plan compliance, architecture, security, edge cases, test coverage, reliability, and unnecessary complexity.

## Result

Return the review as JSON that matches the schema supplied by the calling script (`.agents/schemas/review.schema.json`). Do not write it to a file and do not add text around it.

- `findings`: one entry per finding; an empty array when there are none.
  - `severity`: `critical`, `major`, `minor`, or `suggestion`.
  - `title`: a short, specific name for the finding.
  - `evidence`: file locations and what you observed there.
  - `impact`: why it matters.
  - `recommendation`: the recommended action.
- `verdict`: derived from the findings only.
  - `PASS`: no findings.
  - `PASS_WITH_MINOR_FINDINGS`: only minor or suggestion findings.
  - `CHANGES_REQUIRED`: at least one critical or major finding.
- `limitations`: anything you could not verify, such as checks you could not run. Use an empty string when there is nothing to report. A limitation is not a finding and does not change the verdict.

Do not number the findings; the calling script assigns the identifiers that review triage and follow-up Issues use. A result that breaks these rules is rejected.
