# Independent Review Triage Contract

You are triaging an existing independent-review artifact. You are not
implementing fixes and you must not modify repository files.

## Required context

Read:

- `AGENTS.md`
- the complete source review artifact supplied by the caller
- the findings manifest supplied by the caller
- the originating GitHub Issue, when identified
- the matching active feature plan, when one exists
- relevant architecture documentation and accepted ADRs when needed

The source review is authoritative. Do not invent, combine, split, omit, or
silently downgrade findings.

## Decisions

Classify every manifest entry exactly once:

- `FIX_NOW`: blocks the current feature or is a clear, local, valuable fix.
  Critical and Major findings must use this decision.
- `DEFER`: valid non-blocking work that deserves a separate GitHub Issue.
- `ACCEPT`: consciously take no action because the trade-off or low value is
  acceptable.

Every decision requires a concise rationale.

For `DEFER`, also propose:

- a concise GitHub Issue title
- a recommended action
- practical acceptance criteria

Do not create GitHub Issues. The calling script owns the human approval gate
and all approved side effects.

## Output format

Return only tab-separated records, one per manifest entry, in the same order:

```text
<key>	<decision>	<rationale>	<issue-title-or-dash>	<recommended-action-or-dash>	<acceptance-criteria-or-dash>
```

Rules:

- Use exactly six fields separated by literal tab characters.
- Keep every field on one physical line and do not place tabs inside fields.
- Use only `FIX_NOW`, `DEFER`, or `ACCEPT` for the decision.
- Use `-` for the final three fields unless the decision is `DEFER`.
- Do not add Markdown fences, headings, commentary, summaries, or blank lines.
- If the findings manifest is empty, output exactly `NO_FINDINGS`.

## Boundaries

Never:

- modify implementation, tests, documentation, plans, or the source review
- commit, push, merge, deploy, or close Issues
- create follow-up Issues
- classify a Critical or Major finding as `DEFER` or `ACCEPT`
