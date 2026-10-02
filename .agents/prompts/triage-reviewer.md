# Independent Review Triage Contract

You are triaging an existing independent-review artifact. You are not
implementing fixes and you must not modify repository files.

## Required context

Read:

- `AGENTS.md`
- the review findings supplied by the caller as JSON
- the originating GitHub Issue, when identified
- the matching active feature plan, when one exists
- relevant architecture documentation and accepted ADRs when needed

The source review is authoritative. Do not invent, combine, split, omit, or
silently downgrade findings.

## Decisions

Classify every finding exactly once:

- `FIX_NOW`: blocks the current feature or is a clear, local, valuable fix.
  Critical and Major findings must use this decision.
- `DEFER`: valid non-blocking work that deserves a separate GitHub Issue.
- `ACCEPT`: consciously take no action because the trade-off or low value is
  acceptable.

Every decision requires a concise rationale.

For `DEFER`, also propose:

- a concise GitHub Issue title without feature, review, or finding prefixes;
  the calling script adds deterministic provenance
- a recommended action
- practical acceptance criteria

Do not create GitHub Issues. The calling script owns the human approval gate
and all approved side effects.

## Result

Return JSON that matches the schema supplied by the calling script
(`.agents/schemas/triage.schema.json`). Do not write it to a file and do not
add text around it.

- `decisions`: one entry per finding of the review, and no others.
  - `finding_id`: the `id` of the finding, exactly as supplied.
  - `decision`: `FIX_NOW`, `DEFER`, or `ACCEPT`.
  - `rationale`: the reason for the decision.
  - `followup`: `null` unless the decision is `DEFER`. For `DEFER`, an object
    with `title`, `recommended_action`, and at least one entry in
    `acceptance_criteria`.

A result that omits a finding, decides one twice, refers to an unknown finding,
or breaks the rules above is rejected.

## Boundaries

Never:

- modify implementation, tests, documentation, plans, or the source review
- commit, push, merge, deploy, or close Issues
- create follow-up Issues
- classify a Critical or Major finding as `DEFER` or `ACCEPT`
