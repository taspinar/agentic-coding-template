# Workflow

How a project goes from an idea to merged features, in four views:

1. [Flow](#flow): the steps and the loops between them.
2. [Artifacts](#artifacts): what each step produces and where it lives.
3. [Reference](#reference): per step, who acts, where you approve, and what is
   written and committed.
4. [Principles](#principles): why the review comes before the commit, where
   each kind of state lives, and how the roadmap, Issues, and plans relate.

The commands and their options are described in `docs/development.md`. A
complete run with a sample project is in `docs/example.md`. What each file in
the repository is for is in `docs/project-map.md`.

## Flow

### Overview

The project planning happens once. Every roadmap feature then goes through its
own Issue, feature work, and pull request. A later change to the planning goes
through a change cycle, described under "Changing an approved planning".

```mermaid
flowchart TD
  idea["Project idea<br/>PROJECT_DESCRIPTION.md"]
  planning["Project planning<br/>start-planning.sh … finish-planning.sh"]
  planpr["Planning PR merged<br/>docs/ and PLANNING_APPROVAL.md"]
  issue["Feature Issue<br/>create-feature-issue.sh F01"]
  feature["Feature work<br/>start-feature.sh … publish-feature.sh"]
  featurepr["Feature PR merged<br/>Closes the feature Issue"]

  idea --> planning --> planpr --> issue --> feature --> featurepr
  featurepr -- next roadmap feature --> issue
  featurepr -. the planning changes .-> planning

  classDef plan fill:#E1F5EE,stroke:#0F6E56,color:#085041
  classDef feat fill:#EEEDFE,stroke:#534AB7,color:#3C3489
  classDef neutral fill:#F1EFE8,stroke:#5F5E5A,color:#444441
  class planning plan
  class issue,feature feat
  class idea,planpr,featurepr neutral
```

### Planning phase

All planning steps run in the planning worktree (`planning/<name>`).

```mermaid
flowchart TD
  start["start-planning.sh<br/>Project Grill, your approval, planner"]
  review["review-planning.sh<br/>independent review, read-only"]
  revise["revise-planning.sh<br/>decisions, your approval, revision"]
  finish["finish-planning.sh<br/>checks, your final approval"]

  start --> review
  review -- findings --> revise
  revise -- review again --> review
  review -- no findings --> finish
  revise -- nothing adopted --> finish

  classDef plan fill:#E1F5EE,stroke:#0F6E56,color:#085041
  class start,review,revise,finish plan
```

- A revision that adopts findings changes the planning documents, so the
  review becomes stale and the next step is a new review round.
- When the planner rejects or defers every finding, nothing changes and you
  can finish directly.
- A finding that the planner escalates needs your decision: either it does not
  apply, or the approved requirements must change. There is no script yet that
  runs Project Grill again in an existing planning worktree, and
  `start-planning.sh` always starts a fresh planning branch. To change the
  requirements, edit `docs/PROJECT_REQUIREMENTS.md` in the planning worktree,
  or start a Project Grill session there by hand with
  `.agents/prompts/project-grill.md`, and run a new review round. The planning
  review covers the requirements, and `finish-planning.sh` records your
  approval of exactly the reviewed documents. It refuses while an escalation
  of the latest round is unresolved and asks you to confirm earlier ones.

### Changing an approved planning

A planning that is approved and merged changes through a change cycle: the
same loop as above, started from a change request instead of a project idea.

```mermaid
flowchart TD
  request["Change request<br/>a short file in your own words"]
  start["start-planning.sh NAME --change FILE<br/>planner changes only what is needed"]
  grill["--grill: Project Grill asks about the change<br/>you approve changed requirements"]
  loop["review-planning.sh, revise-planning.sh<br/>until the review passes"]
  finish["finish-planning.sh<br/>approval records the change request"]
  merged["Planning PR merged<br/>create-feature-issue.sh for a new feature"]

  request --> start
  start -. a requirement changes .-> grill
  grill --> loop
  start --> loop
  loop --> finish --> merged

  classDef plan fill:#E1F5EE,stroke:#0F6E56,color:#085041
  class request,start,grill,loop,finish,merged plan
```

| Kind of change | What changes | Project Grill |
|---|---|---|
| Fits a feature that is not built yet | Only the feature Issue | No change cycle |
| New feature within the approved requirements | Roadmap | No |
| New or changed requirement | Requirements, and usually architecture, roadmap, and ADRs | Yes: `--grill`, about the change only |
| Technical change only | Architecture and an ADR that supersedes the old one | No |
| Small technical amendment | Architecture and ADRs only | No change cycle: `finish-planning.sh --amend`, your approval without a review |

- The change request is kept as `docs/changes/<name>.md`; the original
  description is not touched.
- Feature IDs stay stable, a feature that has an Issue is not rewritten, and
  an ADR is superseded by a new one instead of removed. The script refuses a
  removed feature ID and a deleted ADR; the reviewer checks the rest.
- Between the change and its merged approval no new feature Issue can be
  created. Features in progress continue.

### Feature phase

All feature steps run in the feature worktree (`feature/<issue>-<slug>`).

```mermaid
flowchart TD
  start["start-feature.sh<br/>own worktree, implementer writes"]
  review["review-feature.sh<br/>independent review, read-only"]
  triage["triage-review.sh<br/>your approval, report on the Issue"]
  apply["apply-triage.sh<br/>fix only FIX_NOW findings"]
  finish["finish-feature.sh<br/>checks, commit in your editor"]
  publish["publish-feature.sh<br/>push and pull request"]

  start --> review
  review -- findings --> triage
  triage --> apply
  apply -- review again --> review
  review -- no findings --> finish
  triage -- no FIX_NOW --> finish
  finish --> publish
  publish -- a check fails: fix --> review

  classDef feat fill:#EEEDFE,stroke:#534AB7,color:#3C3489
  class start,review,triage,apply,finish,publish feat
```

- Fixes change the code, so the review becomes stale and the next step is a new
  review round. A passed newer round confirms the fixes of earlier rounds. A
  round reviews the complete feature; after a small fix,
  `review-feature.sh <issue> --changes` reviews only what changed since the
  previous round. The round a feature is committed on always covers the
  complete feature: it is what establishes that the Issue is done.
- A session that ends is not a feature that is complete. The implementer
  records where the work stands in a completion record; the commit and a
  pull request that closes the Issue need a record that says complete, which
  the reviewer of the complete feature checks against the code.
- When the triage has no `FIX_NOW` findings, only deferred and accepted ones,
  you can finish directly.
- `publish-feature.sh` pushes the branch and opens the pull request that
  closes the Issue. Follow its checks on the pull request and merge it
  yourself, after they passed. When `main` requires a passing check, GitHub
  enforces that; otherwise the script warns that nothing does. A failed check
  means a fix in the worktree and another round: review, finish, publish.
- After the merge, remove the worktree and its branch with
  `cleanup-worktree.sh <issue>`.
- `run-feature.sh <issue>` runs all of these steps except the merge and the
  cleanup with one command and without questions: the agents run unattended,
  the triage is approved without you, and at most five review rounds are
  used. It stops, and says how to continue, when a step fails or an agent
  needs your decision. `docs/development.md` describes what you hand over
  with it.

## Artifacts

Every step writes to one of three places:

- **Repository**: committed with the planning or feature pull request.
- **Working file**: under `.agents/`, read by the scripts and ignored by Git:
  reviews, triage, the handoff note and the manual steps of a feature, and the
  record of the last passed verification.
- **GitHub**: Issues, comments, and pull requests.

### Planning phase

```mermaid
flowchart LR
  sp["start-planning.sh"] --> docs["PROJECT_DESCRIPTION.md or changes/NAME.md<br/>PROJECT_REQUIREMENTS.md<br/>architecture.md, roadmap.md, ADRs"]
  rp["review-planning.sh"] --> prv["planning-NAME-review-NN.json and .md"]
  rv["revise-planning.sh"] --> rvd["…-review-NN-revision.json and .md"]
  rv --> rdocs["architecture.md, roadmap.md, ADRs<br/>for adopted findings"]
  fp["finish-planning.sh"] --> appr["PLANNING_APPROVAL.md"]
  cfi["create-feature-issue.sh F01"] --> fi["Feature Issue"]

  classDef repo fill:#E1F5EE,stroke:#0F6E56,color:#085041
  classDef local fill:#F1EFE8,stroke:#5F5E5A,color:#444441
  classDef github fill:#FAECE7,stroke:#993C1D,color:#712B13
  class docs,rdocs,appr repo
  class prv,rvd local
  class fi github
  classDef step fill:#FFFFFF,stroke:#888780,color:#2C2C2A
  class sp,rp,rv,fp,cfi step
```

Green is committed, grey is a working file, orange is on GitHub. Because
review and revision files are not committed, `PLANNING_APPROVAL.md` records
the review rounds and every finding that was not adopted; use it for the
planning PR description.

### Feature phase

```mermaid
flowchart LR
  sf["start-feature.sh"] --> code["code and tests"]
  sf --> notes["handoff note, manual steps,<br/>summary of the changes,<br/>verification record"]
  rf["review-feature.sh"] --> rev["feature-ISSUE-SLUG-review-NN.json and .md"]
  tr["triage-review.sh"] --> tri["…-review-NN-triage.json and .md"]
  tr --> gh["follow-up Issues for DEFER<br/>comment with both reports"]
  at["apply-triage.sh<br/>verifies the result"] --> fixes["fixes for FIX_NOW"]
  ff["finish-feature.sh<br/>verifies the result"] --> commit["commit with the changes, review round,<br/>manual steps, and a reference to the Issue"]
  pr["publish-feature.sh<br/>CI runs verify.sh"] --> prgh["pull request that closes the Issue"]

  classDef repo fill:#E1F5EE,stroke:#0F6E56,color:#085041
  classDef local fill:#F1EFE8,stroke:#5F5E5A,color:#444441
  classDef github fill:#FAECE7,stroke:#993C1D,color:#712B13
  class code,fixes,commit repo
  class rev,tri,notes local
  class gh,prgh github
  classDef step fill:#FFFFFF,stroke:#888780,color:#2C2C2A
  class sf,rf,tr,at,ff,pr step
```

Code, tests, and fixes stay uncommitted until `finish-feature.sh`, so every
review covers the complete change. A step that verifies the result reuses a
pass that was recorded for exactly that content, also one from the agent's own
run, instead of running every check again. The lasting record of each review round is
the comment on the feature Issue and the follow-up Issues, each of which names
its source finding.

## Reference

Agent roles and models come from `.agents/agents.conf`; every agent script
accepts `--agent` and `--model` to override them for one run. Profiles are
described in `docs/development.md`: `write` sessions may change files in their
worktree, `read-only` sessions cannot and get no MCP servers or other remote
tools. A third profile, `unattended`, has the reach of `write` without a
terminal and without those tools. A feature step uses it when it is run with
`--unattended`, which also answers the step's own question: the triage is
approved, the fixes start, and the commit message is not opened in an editor.
A session that needs your decision ends with a `BLOCKED:` line, and the step
exits with status 3.

### Steps

| Step | Agent: role (profile) | Your decision | Writes | Committed | `verify.sh` |
|---|---|---|---|---|---|
| `start-planning.sh` | `project-grill` (write), then `project-planner` (write) | Approve the requirements | Description, requirements, architecture, roadmap, ADRs | Yes, with the planning PR | No |
| `start-planning.sh <name> --change <file>` | `project-planner` (write); with `--grill` first `project-grill` (write) | Approve changed requirements, with `--grill` | The change request; the roadmap, architecture, or ADRs; with `--grill` the requirements | Yes, with the planning PR | No |
| `review-planning.sh` | `planning-reviewer` (read-only) | None | Planning review JSON and report | No | No |
| `revise-planning.sh` | `project-planner` (read-only, then write) | Approve the decisions | Revision JSON and report; architecture, roadmap, ADRs | Documents yes, revision no | No |
| `finish-planning.sh` | None | Confirm earlier escalations; approve the planning | `docs/PLANNING_APPROVAL.md` | Yes | No |
| `create-feature-issue.sh` | None | Create the Issue | Feature Issue on GitHub | Not applicable | No |
| `start-feature.sh` | `implementer` (write) | None | Code and tests; the handoff note, manual steps, summary of the changes, and completion record as working files | Code and tests, by `finish-feature.sh` | By the agent, after its last change |
| `review-feature.sh` | `reviewer` (read-only) | None | Review JSON and report | No | Yes, unless it already passed for this content |
| `triage-review.sh` | `triage` (read-only) | Approve the triage | Triage JSON and report; follow-up Issues and a comment on GitHub | No | No |
| `apply-triage.sh` | `triage-implementer` (write) | Start the fixes | Fixes for `FIX_NOW` findings | Yes, by `finish-feature.sh` | Yes, unless it already passed for this content |
| `finish-feature.sh` | None | Edit and confirm the commit message | The commit | Yes | Yes, unless it already passed for this content |
| `publish-feature.sh` | None | Merge after the checks passed, which you follow on the pull request | The pushed branch and the pull request | Not applicable | Yes, in CI |

### Checks that stop a step

| Step | Refuses when |
|---|---|
| `start-planning.sh` | The checkout is dirty (except an uncommitted description or change request), the planning branch or worktree exists, or an agent leaves its file scope or commits |
| `start-planning.sh --change` | Also: `origin/main` has no approved planning, the change request name is taken, the planner changed nothing, removed or renumbered a feature ID, or deleted an ADR |
| `review-planning.sh` | Not on a planning branch, a planning document is missing, or the requirements are not approved |
| `revise-planning.sh` | The planning review is stale, or the planner leaves its file scope, commits, or changes nothing for adopted findings |
| `finish-planning.sh` | No current review, a critical or major finding in the latest round, an undecided or unapplied finding, or an unresolved escalation |
| `finish-planning.sh --amend` | Anything but the architecture and the ADRs changed, an ADR was deleted, the planning on `main` has no current approval, the branch lacks the latest `main`, or a required planning document is missing |
| `create-feature-issue.sh` | The planning approval is missing or stale, the feature ID is unknown, duplicated, or empty, or the feature already has an Issue |
| `start-feature.sh` | Tracked files in the checkout are modified, or the feature branch or worktree exists. With `--resume`: no worktree, or more than one, is on a branch of the Issue |
| `review-feature.sh` | Not on `feature/<issue>-*`, nothing to review, or verification fails (unless `--unverified "<reason>"` is given) |
| `review-feature.sh --changes` | Also: there is no previous round, nothing changed since it, the base of the branch changed, or the content of the previous round is no longer known |
| `triage-review.sh` | The review is stale or invalid, or it is a planning review |
| `apply-triage.sh` | The triage is unapproved, invalid, or does not match its review, or the review is stale |
| `finish-feature.sh` | Verification fails, the latest review is stale or has a critical or major finding, a round with findings has no published triage, `FIX_NOW` findings are left, or a latest review of changes only does not build on the round before it, or the feature changes the roadmap, the requirements, the description, or a change request, which only a planning cycle may change |
| `publish-feature.sh` | There are uncommitted changes or the branch belongs to another Issue. With `--wait` it exits non-zero when a check fails |
| `run-feature.sh` | A step fails or is refused as described above, an agent needs your decision (status 3), five review rounds are used while a finding must still be fixed, or the fixes changed nothing |
| `check-guardrails.sh` | Nothing stops: it reports `protected` when the feature changes an ADR, a file of the workflow, a changed or removed check, or a path the project protects. `finish-feature.sh` then records that only you may merge |

### Helper scripts

| Script | When to use it |
|---|---|
| `doctor.sh` | Once after creating a repository from the template, and whenever a tool may be missing |
| `check-docs.sh` | To check that the Markdown files name files that exist; add it to `scripts/verify.conf` to run it with every verification |
| `verify.sh` | Any time; runs the checks in `scripts/verify.conf`, and is run by `review-feature.sh`, `apply-triage.sh`, `finish-feature.sh`, and CI. A pass is recorded for the content it verified, and `verify.sh --reuse` skips a second run on identical content. The workflow self-tests run only when a workflow file changed; `verify.sh --all`, which CI uses, always runs them |
| `check-review.sh <review-json>` | To see whether a review still matches the content it covers |
| `finish-planning.sh --check` | To see whether the planning approval still matches the planning documents |
| `finish-planning.sh --amend "<reason>"` | To approve a change to the architecture and the ADRs only, on a `planning/<name>` branch, without a review round. Refuses any other planning change and a planning without a current approval |
| `triage-review.sh --publish <triage-json>` | To repeat a failed publication of the review and triage reports |
| `start-feature.sh <issue> --resume` | To continue a feature whose session ended early: a new implementer session in the existing worktree, which reads the handoff note and the state of the worktree |
| `sync-template.sh` | To take over changes of the workflow template: replaces unchanged files, merges changed ones, reports conflicts, and records the template version |
| `update-issue-with-plan.sh <issue> <plan>` | To link an optional feature plan in `.agents/plans/` to its Issue |
| `cleanup-worktree.sh <issue>`, `planning/<name>`, or `--merged` | After a merge, from the primary checkout: removes the worktree and its branch once GitHub reports the pull request as merged, and updates `main` |

## Principles

### Review before the commit

Independent review happens before the implementation commit so it can include
uncommitted working-tree changes. Reviewers run read-only; their results are
validated JSON, and the reports of each feature review round are published on
the feature Issue. Critical and major findings must be fixed and confirmed by
a newer review round before a feature or the planning can be finished. A
review starts only on content that passes verification, and a later round may
be limited to the changes since the previous one.

### Where state lives

Each kind of state has one place:

- GitHub Issue: what/why, acceptance criteria, priority/status.
- `AGENTS.md`: durable working rules.
- `docs/architecture.md`: current system design.
- ADRs: why significant architecture decisions were made.
- `.agents/plans/`: active implementation state for complex work.
- `.agents/handoffs/`: per Issue, the implementer's continuation note for a
  session that resumes the work. A working file, ignored by Git.
- `.agents/manual-steps/`: per Issue, the steps a feature needs from the
  human; copied into the commit message and the pull request. Working files.
- `.agents/summaries/`: per Issue, the implementer's summary of the changes,
  which becomes the list of changes in the commit message. Working files.
- `.agents/completion/`: per Issue, the implementer's completion record:
  complete, partial, or blocked, with evidence per acceptance criterion. The
  scripts commit and close the Issue only on `complete`. Working files.
- `.agents/run/`: the final messages of agents that ran unattended. Working
  files.
- `.agents/verification/`: the record of the last passed verification of the
  working tree. A working file.
- `docs/changes/`: one change request per change cycle of the approved
  planning.
- `.agents/reviews/`: independent-review results as validated JSON, each with a
  generated Markdown report. Working files, ignored by Git.
- `.agents/triage/`: approved finding decisions and deferred-Issue traceability
  as validated JSON, each with a generated Markdown report. Working files,
  ignored by Git.
- Feature Issue comments: the published review and triage reports of each
  round.
- `.agents/schemas/`: the schemas of those results.
- `.agents/lessons/`: recurring failure lessons awaiting/promoting durable rules.
- Git history: what actually changed.
- PR + CI: review discussion and deterministic evidence.

### Roadmap to GitHub Issues

`docs/roadmap.md` describes the intended project direction and contains
roadmap features such as F01, F02, F03, etc.

Do not automatically create GitHub Issues for every roadmap feature.

GitHub Issues should normally be created only when a feature is about to
enter the active development workflow.

Recommended approach:

- current feature: GitHub Issue exists
- next 1–2 likely features: optional
- later roadmap items: remain only in `docs/roadmap.md`

This prevents the GitHub backlog from becoming stale when the roadmap changes.

Example:

```text
Roadmap:
F01
F02
F03
F04
F05
...

GitHub Issues:
#1 F01 — active
#2 F02 — optional next
```

Before starting F03, review the roadmap again and only then create its Issue
with `./scripts/create-feature-issue.sh F03`, which copies the F03 block from
the roadmap into the Issue after your approval.

GitHub Issues are the actionable source of truth once created.
The roadmap remains the higher-level planning document.

### Feature plans versus GitHub Issues

A GitHub Issue defines:

- what must be delivered
- scope
- acceptance criteria
- dependencies
- risk

A feature implementation plan defines:

- how the feature will be implemented
- technical steps
- affected components
- discoveries
- verification approach
- current implementation status

Plan steps must not automatically become separate GitHub Issues.

Create another Issue only if a plan step becomes a substantial independent
work item with its own scope, acceptance criteria or lifecycle.
