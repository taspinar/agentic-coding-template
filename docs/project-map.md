# Project map

What each part of the template is for. The workflow that connects them is in
`docs/workflow.md`.

## Where each topic is described

One place is authoritative for each topic; the others summarize it and link
to it. When a script changes, change the authoritative place, and check the
summaries. The files in the repository describe the version a project has;
the website describes the current template.

| Topic | Authoritative | Summarized in |
|---|---|---|
| What the template is, in short | `README.md` | The introduction of the website |
| GitHub settings: rulesets, required checks, code owners, permissions | `docs/repository-setup.md` | "Getting started" and "Configuration and security" on the website |
| Commands, options, and how to resume or recover | `docs/development.md` and the usage text of each script | Selected commands on the website and in the README |
| Steps, artifacts, approvals, and what stops a step | `docs/workflow.md` | The workflow page of the website |
| Principles: where state lives, roadmap versus Issues, plans versus Issues | "Principles" in `docs/workflow.md` | `AGENTS.md`, briefly |
| What makes a check or a review worth having | `docs/evaluation.md` | "Configuration and security" on the website |
| What each file is for | This file | The repository tree on the website |
| A complete run | `docs/example.md` | Linked, not repeated |
| Rules and boundaries for agents | `AGENTS.md`, `.agents/policies/`, `.agents/prompts/` | Never replaced by a page of the website |
| Reporting a security problem | `SECURITY.md` | Linked from the website |
| Research, history, and proposals | The website (`documentation/`) | Not repeated in `docs/` |
| Requirements, architecture, roadmap, and decisions of a project | The project's own `docs/` | The website explains only how they come about |

## Rules and configuration

| Path | Purpose |
|---|---|
| `AGENTS.md` | Durable working rules for every agent: source precedence, Definition of Done, boundaries, branch policy |
| `.agents/agents.conf` | Provider and model per workflow role, and per risk level of a feature for its roles |
| `.agents/attribution.conf` | Whether commits and pull requests may name an agent as a co-author or as the tool that generated them: `allowed` (the previous behaviour) or `disabled` (the shipped default), which the instructions, the Claude sessions the scripts start, and a check in `finish-feature.sh` and `publish-feature.sh` follow |
| `.agents/template.conf` | Where the workflow comes from, which files belong to it, and the template version the project has |
| `.agents/policies/` | Risk-based autonomy, execution limits, recovery, conflict resolution, and tool permissions |
| `.agents/policies/guardrails.conf` | The paths of the project that the merge approval gate protects or names to the reviewer |
| `.agents/policies/risk.conf` | The risk policy: the path classes `low`, `medium`, `high`, the `default`, the test files, the shared test fixtures (`test-fixtures`), and the manifests, from which the risk level of a feature is computed, and per level what the review rounds require (`verification: full` or `groups ...`, `review: full`, `delta`, or `none` for `low`), and the workflow profile (`profile: light` or `standard`) whose preset supplies the lines the file does not write |
| `scripts/verify.conf` | The required verification checks of the project |
| `scripts/verify-workflow.conf` | The self-tests of the workflow scripts and the workflow files they guard |
| `.github/` | CI workflow, Issue templates, PR template, and code owners |
| `CONTRIBUTING.md`, `SECURITY.md` | How to contribute and how to handle security-sensitive findings |

## Project documents

| Path | Purpose | Written by |
|---|---|---|
| `README.md` | What the project is and how to start | You |
| `docs/PROJECT_DESCRIPTION.md` | Your original project idea, unchanged | `start-planning.sh --description` |
| `docs/changes/` | One change request per later change to the approved planning, unchanged | `start-planning.sh <name> --change` |
| `docs/PROJECT_REQUIREMENTS.md` | The requirements you approved | Project Grill, approved by you |
| `docs/architecture.md` | The current system design | Project planner |
| `docs/roadmap.md` | Roadmap features with stable IDs (F01, F02, …) | Project planner |
| `docs/decisions/` | Architecture decision records | Project planner |
| `docs/PLANNING_APPROVAL.md` | Your approval of the reviewed planning, with its fingerprint | `finish-planning.sh` |
| `docs/repository-setup.md` | GitHub settings for a new repository | You |
| `docs/development.md` | Every command and its behaviour | Template |
| `docs/workflow.md` | The workflow in flow, artifact, reference, and principles views | Template |
| `docs/example.md` | A complete run with a sample project | Template |
| `docs/evaluation.md` | Review criteria, finding severities, and the testing principle | Template |
| `docs/deployment.md`, `docs/operations.md` | Deployment and operations of the project | You |

## Workflow scripts

| Script | Purpose |
|---|---|
| `scripts/doctor.sh` | Checks the local prerequisites: the tools, the agent configuration, the Git commit identity, whether a Codex role with write access can write the runtime directories under `.agents/` inside its sandbox (one real `codex exec` session in a scratch repository), and reports the attribution preference and whether the clients can be made to follow it |
| `scripts/check-docs.sh` | Checks that the tracked Markdown files name files that exist: relative links, and paths in backticks into a tracked directory. `--later` names paths that come later. The template runs it in its verification; a project can add it to `scripts/verify.conf` |
| `scripts/verify.sh` | Runs the checks in `scripts/verify.conf`, and the workflow self-tests when a workflow file changed or with `--all`; records a pass and skips a repeated run with `--reuse`; used by humans, agents, and CI. `--only <group>` runs the checks of named groups for a CI with parallel jobs; such a partial run records nothing. A check declared as a budget (`<name> [<group>] budget: <command>`) is a measurement: over its target it is `BUDGET`, with its output, not `FAIL`, and the verification still passes. Times every check and records the durations; `budget-seconds: <n>` in either file is a target for the duration of its checks, shown as `BUDGET` with the slowest checks when exceeded |
| `scripts/start-planning.sh` | Project Grill, requirements approval, and project planning in a planning worktree |
| `scripts/review-planning.sh` | Independent, read-only review of the planning documents |
| `scripts/revise-planning.sh` | The planner's decision per planning finding, then the revision |
| `scripts/finish-planning.sh` | Checks and records your approval of the planning; `--check` tests it |
| `scripts/create-feature-issue.sh` | Creates the Issue of one roadmap feature |
| `scripts/start-feature.sh` | Creates the feature worktree and starts the implementer |
| `scripts/review-feature.sh` | Independent, read-only review of the complete feature diff, or with `--changes` of what changed since the previous round |
| `scripts/triage-review.sh` | Classifies review findings, creates follow-up Issues, and publishes the reports on the Issue |
| `scripts/apply-triage.sh` | Lets an implementer resolve only the `FIX_NOW` findings |
| `scripts/finish-feature.sh` | Checks the feature, including the completion gate and a review of the complete feature, and creates the commit; prints the content tree next to the commit SHA, and writes the approval request when only the owner may merge; `--partial` commits unfinished work as your choice |
| `scripts/run-feature.sh` | Runs a feature from `start-feature.sh` to `publish-feature.sh` without questions: resumes the implementer until the completion gate passes, then at most five review rounds, the last of the complete feature; never merges and never removes a worktree |
| `scripts/record-post-merge.sh` | After the merge, records the evidence of a pending `post_merge` criterion as an Issue comment and closes the Issue when none is left |
| `scripts/publish-feature.sh` | Pushes the feature branch and opens its pull request, which closes the Issue only for a complete feature (or one whose only pending evidence is before the merge) and is a draft for incomplete work; names the content tree of the finish commit next to its SHA and displays the approval request; with `--wait` stays until CI finishes; with `--summary` posts the totals of the run records on the Issue; never merges |
| `scripts/show-experience.sh` | Shows the experience records of a feature, with an invalid record marked as such |
| `scripts/analyze-runs.sh` | Analyses several feature runs with a read-only agent and proposes improvements, each with its place; changes nothing |
| `scripts/report-runs.sh` | Reports on the run records of features and planning cycles, in Markdown or JSON, without the network |
| `scripts/check-guardrails.sh` | The merge approval gate: reports which changes of a feature need the owner's approval, by the rules of its base; recomputes the content tree of the commit with the exclusion list of the base and refuses an approval request that names another one or has a field its schema does not name |
| `scripts/check-risk.sh` | The risk level of a feature, `low`, `medium`, or `high`, with every reason and what the level requires of the review rounds, by the risk policy of its base; exits 0, 1, or 2 for the level |
| `scripts/check-review.sh` | Reports whether a review still matches what it covers |
| `scripts/update-issue-with-plan.sh` | Links an optional feature plan to its Issue |
| `scripts/cleanup-worktree.sh` | Removes a merged worktree and its branch and updates `main` |
| `scripts/sync-template.sh` | Takes over the template's changes since the version the project has; never commits |
| `scripts/worktree-setup.sh` | Optional, written by the project: prepares a new feature worktree before the agent starts, for example by copying a dependency cache |

## Script libraries

| Path | Purpose |
|---|---|
| `scripts/lib/agent.sh` | Role configuration, `--agent`/`--model` overrides, and starting agents with the `write`, `unattended`, or `read-only` profile; for Codex, the runtime directories under `.agents/` that a write session may write (`AGENT_CODEX_WRITABLE_DIRS`), opened as writable roots of its sandbox and created before the session; `tests/agent-sandbox-test.sh` checks that with the real Codex CLI |
| `scripts/lib/attribution.sh` | The attribution preference of `.agents/attribution.conf`, and the check of commits and texts for agent `Co-authored-by` trailers and generated attribution text |
| `scripts/lib/review-data.sh` | Validation and rendering of review, triage, and revision JSON; the decisions of the earlier rounds of a feature, against which the predecessor of a finding (`previous`) is checked |
| `scripts/lib/review-run.sh` | Running a read-only agent with one retry, and storing a review |
| `scripts/lib/github.sh` | Questions about the repository on GitHub, such as whether a branch requires a status check |
| `scripts/lib/issue-comments.sh` | The comments of a feature Issue that are passed on to the implementer, the reviewer, and the triage agent: those of the owner, members, and collaborators, without the workflow's own reports, bounded in size |
| `scripts/lib/fingerprint.sh` | Content fingerprints of a working tree, a commit, or a set of files, with the one fixed list of what is left out: the metadata the workflow writes about the content and the approval requests; a feature review's fingerprint also covers the completion record and the handoff note of its Issue |
| `scripts/lib/verification.sh` | The record of the last passed verification of a working tree, the durations of its checks, and the results of its budget checks, with their report for the reviewer, the handoff note, the commit, and the run record |
| `scripts/lib/records.sh` | The run records: duration and token usage per run, step, and agent call, and the copy per feature or planning |
| `scripts/lib/experience.sh` | The experience record of a feature run: what a script derives from the run, and the agent's optional notes once they are valid |
| `scripts/lib/report.jq` | The report of `report-runs.sh`: totals, comparisons, and the summary for GitHub, from numeric fields only |
| `scripts/lib/completion.sh` | The completion gate: validation of the implementer's completion record, the remaining work a handoff note lists, and the decision the scripts act on |
| `scripts/lib/guardrails.sh` | The merge approval gate: the protected and sensitive paths on the diff, by the rules of the base, the decision with the reviewer's classification, the approval requests (writing, validation against their schema, display), and the finish commit of a branch that merged its base afterwards |
| `scripts/lib/risk.sh` | The risk level of a feature: the path classes of `.agents/policies/risk.conf` on the diff, the fixed escalations, and what the agents recorded, of which the highest counts; and what a level requires of the review rounds, by the same policy; the presets of the workflow profiles `light` and `standard` |
| `scripts/lib/scope.sh` | File-scope enforcement for write sessions: a snapshot of the worktree before and after, which leaves out the directories Git ignores as a whole |
| `scripts/lib/planning.sh` | The planning scope and the planning approval check |

## Agent contracts and schemas

| Path | Used by |
|---|---|
| `.agents/prompts/project-grill.md` | Project Grill in `start-planning.sh` |
| `.agents/prompts/project-planner.md` | The project planner in `start-planning.sh` |
| `.agents/prompts/planning-reviewer.md` | `review-planning.sh` |
| `.agents/prompts/planning-reviser.md` | `revise-planning.sh` |
| `.agents/prompts/planner.md` | Optional feature plans in `.agents/plans/` |
| `.agents/prompts/implementer.md` | `start-feature.sh` |
| `.agents/prompts/reviewer.md` | `review-feature.sh` |
| `.agents/prompts/triage-reviewer.md` | `triage-review.sh` |
| `.agents/prompts/triage-implementer.md` | `apply-triage.sh` |
| `.agents/prompts/analyst.md` | `analyze-runs.sh` |
| `.agents/schemas/review.schema.json` | Results of planning reviews |
| `.agents/schemas/feature-review.schema.json` | Results of feature reviews: the same, with the reviewer's classification of the impact on the architecture |
| `.agents/schemas/triage.schema.json` | Triage decisions |
| `.agents/schemas/analysis.schema.json` | The result of an analysis of runs |
| `.agents/schemas/approval-request.schema.json` | An approval request: references and an explanation only; `check-guardrails.sh` refuses a request with any other field |
| `.agents/schemas/revision.schema.json` | Planning revision decisions |

## Working directories

| Path | Contents | Committed |
|---|---|---|
| `.agents/reviews/` | Review and revision results (JSON and generated reports) | No |
| `.agents/triage/` | Approved triage results (JSON and generated reports) | No |
| `.agents/verification/` | The record of the last passed verification, the durations of its checks, and the results of its budget checks, written by `verify.sh` | No |
| `.agents/manual-steps/` | Per Issue, the steps a feature needs from you, written by the implementer; copied into the commit message and the pull request | No |
| `.agents/summaries/` | Per Issue, the implementer's summary of the changes; becomes the list of changes in the commit message | No |
| `.agents/completion/` | Per Issue, the implementer's completion record: `complete`, `partial`, or `blocked`, with evidence per acceptance criterion. The gate before the commit and before a pull request that closes the Issue | No |
| `.agents/records/` | Per feature and per planning, its run records together: how long every step took and how many tokens its agents used. The run files themselves are in `.agents/run/records/` | No |
| `.agents/run/` | The final messages, and for Codex the session logs, of agents that ran with `--unattended`; the mark of `run-feature.sh` that the implementation was completed, its log of interruptions (`<issue>-log`), and the output of a failed verification. Never part of a content fingerprint | No |
| `.agents/plans/` | Optional feature plans; part of the content fingerprint, since a plan can change what a feature has to do | Yes |
| `.agents/approval-requests/` | Per Issue, what the owner is asked to approve and why, written by `finish-feature.sh` when only the owner may merge: references and an explanation, never part of the content fingerprint, never an instruction, grants nothing | Yes |
| `.agents/handoffs/` | Per Issue, the implementer's continuation note for a session that resumes the work (`start-feature.sh <issue> --resume`) | No |
| `.agents/lessons/` | Recurring agent failures and the rules learned from them | Yes |
| `tests/` | Integration tests of the workflow scripts, run by `verify.sh` when a workflow file changed, and always in CI | Yes |

A Codex session with write access (the `write` and the `unattended` profile)
may write only `.agents/completion/`, `.agents/handoffs/`,
`.agents/summaries/`, `.agents/manual-steps/`, and `.agents/experience/` of
these: Codex 0.164 and later mount `.agents/` read-only in the sandbox, and
`scripts/lib/agent.sh` opens exactly the directories that the implementer and
the triage-implementer have to write, all ignored by Git. The policies, the
prompts, the schemas, the plans, the reviews, the triage, `.agents/run/`,
`.agents/verification/`, `.git/`, and `.codex/` stay read-only for the
agent. See "Codex and `.agents/`" in `docs/development.md`.
| `documentation/` | The documentation site of the template, published on GitHub Pages: an Astro project with static output. `site.config.ts` holds the name, the repository and the address, with the site URL and base path from `SITE_URL` and `BASE_PATH`; `src/` holds the pages, the layout and components, the style sheet with the design tokens, and the Markdown and MDX content of the documentation; `public/` the self-hosted fonts and their licence; `design/` the approved design, a reference that is not built; `integrations/search.mjs` builds the static search index from rendered page content (article content on Docs pages); `content-migration.md` maps the migrated content and corrections; `.nvmrc` the Node version; `check.sh`, which checks that the style sheet sets every colour, font and spacing value by a design token, builds the site under the project path and under the root and checks the output: its links (repository links must name `main`), the repository files and scripts it names (including qualified script paths), and its metadata. With `--build`, it also runs `search-test.mjs` to test search and navigation and compare documented configuration examples with the shipped `agents.conf` and `risk.conf`; `check-test.sh`, the test of `check.sh`. A feature that changes behavior the site describes updates it in the same pull request, as the Definition of Done in `AGENTS.md` asks; a project without the site skips this. The template's own; not synced to a project | Delete in a project |
| `.github/workflows/pages.yml` | Builds `documentation/` with Node and `npm ci`, checks it, and publishes the output and nothing else, only in a repository that sets the variable `PUBLISH_DOCUMENTATION` to `true`. The template's own; not synced to a project | Delete in a project |
