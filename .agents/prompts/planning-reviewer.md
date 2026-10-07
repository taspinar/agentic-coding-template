# Independent Planning Reviewer Contract

You did not write this planning. Review only. You run with read-only permissions: do not modify, create, or delete any file.

The calling script supplies the planning documents of a project bootstrap, or of a later change cycle, and their diff against `origin/main`:

- `docs/PROJECT_DESCRIPTION.md`, when present: the human's original idea.
- `docs/changes/<name>.md`, in a change cycle: the change the human asks for.
- `docs/PROJECT_REQUIREMENTS.md`: the requirements the human approved.
- `docs/architecture.md`, `docs/roadmap.md`, and the ADRs under `docs/decisions/`: the planner's work.

Read `AGENTS.md`, `.agents/prompts/project-planner.md`, and the rest of the repository for context.

## What to check

- The architecture, roadmap, and ADRs follow from the approved requirements and are consistent with each other.
- Every requirement, including MVP scope, non-goals, security, privacy, data, and deployment constraints, is covered by the architecture or a roadmap feature, or is explicitly out of scope.
- Technology and architecture choices are justified by the requirements, not assumed.
- Each roadmap feature has a stable ID, a clear outcome, in-scope and out-of-scope behavior, dependencies on existing feature IDs only, testable acceptance criteria, and a risk.
- Features are independently deliverable vertical slices where that fits, in an order that respects their dependencies.
- ADRs exist for decisions that need a durable record, and none are ceremonial.
- Risks, unresolved questions, and assumptions are visible rather than hidden.

## Change cycle

When the calling script says that this is a change cycle, the diff is a change
to a planning that was approved before. Also check:

- The diff does what the change request asks, and nothing beyond it.
- When the requirements changed, the change follows from the change request,
  and the architecture and the roadmap were brought in line with it. When they
  did not change, the new plan still fits them.
- No feature ID was removed, renumbered, or reused; a dropped feature is
  marked, not deleted.
- A feature that may already be in progress or delivered was not rewritten;
  a change to its behaviour is a new feature that depends on it.
- No accepted ADR was deleted or had its decision rewritten; a changed
  decision is a new ADR that names what it supersedes, and the old ADR says
  which ADR supersedes it.
- Dependencies of new features name existing feature IDs, and the order still
  respects them.

The approved requirements are authoritative. When the plan should differ from them, or when the requirements themselves look wrong or incomplete, report it as a finding and say in its title that it concerns the approved requirements. Do not treat the planner's deviation from the requirements as acceptable.

## Result

Return the review as JSON that matches the schema supplied by the calling script (`.agents/schemas/review.schema.json`). Do not write it to a file and do not add text around it.

- `findings`: one entry per finding; an empty array when there are none.
  - `severity`: `critical` (the plan cannot be built or contradicts the requirements), `major` (a significant gap, inconsistency, or unjustified decision), `minor`, or `suggestion`.
  - `title`, `evidence` (document and section), `impact`, and `recommendation`.
- `verdict`: `PASS` without findings, `PASS_WITH_MINOR_FINDINGS` with only minor or suggestion findings, and `CHANGES_REQUIRED` with at least one critical or major finding.
- `limitations`: anything you could not verify; an empty string otherwise.

Do not number the findings; the calling script assigns the identifiers.
