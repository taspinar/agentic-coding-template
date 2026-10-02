# Contributing

All non-trivial changes should originate from a GitHub Issue and use a feature branch. Follow `AGENTS.md` whether work is human-written, AI-assisted, or agent-generated. Keep PRs focused, include verification evidence, and do not bypass required CI or production gates.

## Changing the template itself

Everything committed to the template repository is inherited by every project
created from it. When developing the template:

- Do not commit the plans or handoffs of that work under `.agents/`. Keep the
  design in the GitHub Issue. Review and triage results are ignored by Git and
  published on the Issue, as in any project.
- Record design decisions about the template in the Issue and in the workflow
  documentation under `docs/`. `docs/decisions/` is reserved for the ADRs of
  projects that use the template.

Remove this section after creating a project from the template.
