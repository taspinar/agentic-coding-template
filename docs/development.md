# Development

## Prerequisites

- Git
- GitHub CLI (`gh`), installed and authenticated
- `jq` 1.6 or later
- Codex or Claude CLI when that agent is selected
- Project-specific tools documented in this file after the template is adopted

Run `./scripts/doctor.sh` to check these prerequisites, including that you can
push to `origin` with the Git identity in use. It reports each check
as `OK`, `WARNING`, or `FAILED` with a fix hint, exits non-zero when a required
prerequisite is missing, and never modifies anything. A missing agent CLI
fails when `.agents/agents.conf` assigns it to a role and is a warning
otherwise. It also warns when a pull request into `main` can be merged while
its checks fail, because no ruleset or branch protection requires a status
check; see `docs/repository-setup.md`.

Keep `./scripts/verify.sh` as the stable verification entry point for humans,
agents, and CI.

## Configuring verification

`./scripts/verify.sh` runs the checks declared in `scripts/verify.conf`, one
per line:

```text
<name>: <command>
```

After adopting the template, replace the template checks with those of the
project's stack, for example:

```text
lint: ruff check .
tests: pytest
```

Every listed check is required. Each command runs with `bash -eo pipefail`
from the repository root, so a failing step in a pipeline or command sequence
fails the check. Its first word is the required tool. Verification fails
when that tool is missing or not executable, when a command exits non-zero, or
when the configuration is missing, empty, or malformed. All checks run even
after a failure, and a summary lists each check as `PASS` or `FAIL`.

There is no automatic stack detection and no optional check: remove a check
from `scripts/verify.conf` rather than letting it be skipped.

### Groups of checks

A check may name a group in square brackets after its name:

```text
lint [code]: ruff check .
unit-tests [code]: pytest tests/unit
site-build [build]: ./scripts/build-site.sh
tests-in-a-browser [e2e]: pytest tests/e2e
```

- `./scripts/verify.sh` runs every check, whatever its group. Nothing changes
  for the developer and for the workflow scripts.
- `./scripts/verify.sh --only code` runs the checks of one group, and
  `--only code,build` those of several, in the order of the file.
- `./scripts/verify.sh --groups` prints the groups that have a check.
- A check without a group is in the group `default`.
- An unknown group is an error, so a renamed group cannot pass unnoticed.

Groups exist for a CI that has outgrown one job: each job runs
`./scripts/verify.sh --all --only <group>`, and one job that needs all of them
is the required check. Every check stays declared in `scripts/verify.conf`
or `scripts/verify-workflow.conf`; none is declared in the workflow file.
Such a CI has to run **every** group, `default` included, or a check that is
added without a group runs on a laptop and never in CI. Compare the output of
`--groups` with the groups of the workflow file in a test of the project.

A partial run is never a verification. With `--only` nothing is recorded as
passed and `--reuse` is refused, so `review-feature.sh` and
`finish-feature.sh` still run every check. A failing partial run removes an
existing record, like any failing run. The workflow self-tests keep their own
rule with `--only`: they run when a workflow file changed, or with `--all`.

### Recorded verification

A run in which every check passed is recorded in `.agents/verification/passed`,
a working file that Git ignores, together with the fingerprint of the content
it verified. Any change to a file that Git does not ignore makes the record
stale, and a failing run removes it.

`./scripts/verify.sh --reuse` skips the run when the record matches the current
content exactly, and says so. `review-feature.sh`, `apply-triage.sh`, and
`finish-feature.sh` call it that way, so in a feature the checks run once per
version of the content instead of once per step: the agent verifies its final
result, and the scripts that follow reuse that pass. Plain
`./scripts/verify.sh` always runs every check.

Two limits:

- The fingerprint does not cover files that Git ignores. A check that depends
  on ignored state, such as an installed dependency or a build cache, is not
  run again when only that state changed. CI runs every check on a clean
  checkout.
- A run inside an agent session counts like any other. The implementer and
  the triage implementer run the verification after their last change, and
  the review, `apply-triage.sh`, and the commit that follow reuse that pass.
  An agent could write the record instead of running the checks; that is
  accepted, because CI runs every check on a clean checkout, and
  `publish-feature.sh` and a ruleset on `main` make it the gate before a
  merge.

A record made without the workflow self-tests does not stand in for a run that
needs them, such as `--reuse --all`.

### References in the documentation

`./scripts/check-docs.sh` checks that the tracked Markdown files name files
that exist: every relative link (inline, with or without a title, and the
definition of a reference link; also one that leaves the repository), and
every path in backticks that starts with
a tracked top-level directory and names a `.md`, `.sh`, `.conf`, `.json`,
`.yml`, or `.yaml` file. It does not check anchors or external links, it
skips a path with a placeholder and a path that Git ignores, and it does not
read links that are shown as an example in a fenced code block or in inline
code. Name the files
that come later, or a directory that will hold them, after `--later`:

```text
docs-references: ./scripts/check-docs.sh --later docs/PLANNING_APPROVAL.md docs/changes
```

The template has such a line in its own `scripts/verify.conf`. It catches a
document that one change still names after another change removed it.

### Workflow self-tests

The tests of the workflow scripts (`tests/*-test.sh`) are declared separately,
in `scripts/verify-workflow.conf`. They test the workflow, not the project, so
a feature can break them only by changing a workflow file. That file names
those files in its `paths:` entry, as Git pathspecs.

`./scripts/verify.sh` runs the self-tests only when one of those files differs
from the base branch (`origin/main`, or `main`), counting uncommitted and
untracked files, or when it cannot tell, for example outside a Git repository.
Otherwise the summary reports them as `SKIP`. `./scripts/verify.sh --all`
always runs them, and CI uses it, so every pull request runs the self-tests.

`scripts` is listed as a whole, so a new script is guarded until it is
excluded with an entry `:(exclude)<path>`. `scripts/verify.conf` is excluded:
a project adds its checks there, and no self-test reads it. Exclude a
project's own scripts the same way, after checking that no self-test reads or
copies them; a broader list only makes the self-tests run more often. Delete
`scripts/verify-workflow.conf` when the project removes the workflow scripts.

The self-tests start `jq`, `git`, and `bash` thousands of times. On an Apple
Silicon Mac an x86_64 `jq`, such as the one Anaconda installs, runs under
Rosetta and roughly doubles their duration; `file "$(command -v jq)"` shows
which one is first on your `PATH`.

## Configuring agents

`.agents/agents.conf` assigns a provider and model to each workflow role, one
per line:

```text
<role>: <provider> <model>
```

| Role | Used by |
|---|---|
| `project-grill`, `project-planner` | `start-planning.sh` |
| `planning-reviewer` | reserved for planning review |
| `implementer` | `start-feature.sh` |
| `reviewer` | `review-feature.sh` |
| `triage` | `triage-review.sh` |
| `triage-implementer` | `apply-triage.sh` |
| `analyst` | `analyze-runs.sh` (read-only) |

Supported providers are `codex` and `claude`. Set each model to one your
account supports, and use a different provider for a reviewing role than for
the role whose work it reviews.

Every workflow script accepts `--agent <agent>` and `--model <model>` to
override the configuration for one run. Overriding the provider requires a
model as well. The model is always passed to the provider, for Claude as well
as Codex, and is never replaced: an unknown provider, missing CLI, missing
model, or malformed configuration fails before the script creates a branch,
worktree, or file, and a model the provider rejects fails the run.

Agents run with one of three permission profiles. The profile follows from
the role and from how the script is run, not from the provider or model: a
reviewing role is always read-only; a writing role gets `write`, or
`unattended` when you run the step with `--unattended`, as described under
"Running feature steps without questions".

- `write`: an interactive session that may modify its worktree and use the
  network, for example to install dependencies and run builds. Anything beyond
  that needs your permission. Claude accepts edits automatically and asks you
  before it runs a shell command. Codex works without asking inside a
  workspace-write sandbox with network access and asks you when a command
  needs to leave that sandbox, for example to write outside the worktree;
  Codex has no setting that asks per command without a sandbox. Used for
  planning, implementation, and applying triage.
- `unattended`: the reach of `write` without a terminal. The session asks
  nothing and ends by itself, and the script stores its final message. What
  `write` would ask you is decided without you. Codex stays inside its
  workspace-write sandbox and is refused a command that leaves it. Claude runs
  in its `auto` permission mode, in which its own check allows or denies each
  action, and anything that would still prompt is denied. As in a read-only
  session, no MCP servers, apps, or other tools from your configuration are
  loaded, since they act outside the sandbox: Codex runs without your
  `config.toml` and with apps, browser use, and computer use disabled, and
  Claude without MCP configuration. An unattended agent runs commands on your
  machine while you are not watching: it is meant for work whose result you
  read afterwards.
- `read-only`: a non-interactive session that cannot modify files and gets no
  MCP servers, apps, or other tools from the user's configuration. Codex runs
  in a read-only sandbox without the user's `config.toml`, with apps, browser
  use, computer use, and web search disabled. Claude runs restricted: without user, project, or MCP
  configuration, with only its Read, Glob, and Grep tools, and without asking
  for any further permission. The script stores the agent's result. Used for
  review and triage.

A profile that a provider cannot enforce is an error; an agent is never started
with broader permissions instead.

**When a session fails.** A read-only or unattended session that fails says
why, as the provider said it: its error messages, which Codex writes as JSON
events, and its error output. A usage or rate limit is named as one ("This is
a usage limit of codex, not a defect"), and `run-feature.sh` writes it into
the log of the feature. Before anything is shown, what looks like a key or a
token is replaced by `[redacted]`, also a private key with its whole body; a
line of the prompt that the provider repeats is replaced by `[prompt]` (a line
of fewer than four characters only as a word of its own); and only the last
ten lines are shown. The ordinary answer of a failed session is not shown. A
`write` session runs in your terminal, where the agent shows its own messages
as it works: the script repeats nothing of them and says only that the
session ended with its status.

## Project bootstrap workflow

Run project bootstrap from a clean checkout after recording the initial project
idea and completing `docs/repository-setup.md`:

```bash
./scripts/start-planning.sh
```

The full interface is:

```text
./scripts/start-planning.sh [name] [--description <file>] [--agent <agent>] [--model <model>]
./scripts/start-planning.sh <name> --change <file> [--grill] [--agent <agent>] [--model <model>]
```

The second form changes a planning that is already approved; see "Changing an
approved planning" below.

If you already have a project description, pass it with `--description`:

```bash
./scripts/start-planning.sh --description ~/notes/project-idea.md
```

The file may be anywhere, including outside the repository. An uncommitted
description inside the repository is the one change the clean-checkout check
allows.
The script copies it to `docs/PROJECT_DESCRIPTION.md` in the planning worktree
before the first session. Project Grill reads it first and asks only about
what it leaves unresolved. Neither planning phase may modify it, and it is
committed with the planning branch as the recorded input. A missing, empty, or
non-regular file fails before a branch or worktree is created.

Project Grill uses role `project-grill` and the planning session uses role
`project-planner`; `--agent` and `--model` override both. The optional name
defaults to `project-bootstrap`. A custom planning cycle such as:

```bash
./scripts/start-planning.sh architecture-refresh
```

creates `planning/architecture-refresh` in a sibling worktree named
`../<repository>-planning-architecture-refresh`.

The script fetches `origin/main` and creates the planning branch from that
remote ref without switching or modifying the primary checkout. It refuses a
dirty checkout, unsafe name, missing agent or prompt, unavailable base,
duplicate branch, or existing target path.

Bootstrap has two separate interactive agent sessions:

1. Project Grill reads the project context, asks only questions that materially
   affect product or technical direction, and refines
   `docs/PROJECT_REQUIREMENTS.md` in Draft state.
2. The script validates and displays the requirements. It records Approved
   status and a UTC timestamp only after explicit human confirmation.
3. A fresh project-planner session consumes the approved requirements and
   creates or updates `docs/architecture.md`, `docs/roadmap.md`, and only
   necessary ADRs under `docs/decisions/`.

Declining requirements approval or an agent failure stops the workflow and
leaves the planning worktree intact. Inspect or revise it there; the script
never substitutes another model or removes user work automatically.

After successful planning, continue in the planning worktree with the planning
review, revision, and approval described below. `finish-planning.sh` prints
the exact commit and push commands.

### Planning review

Before committing the planning, let an independent agent review it from the
planning worktree:

```bash
./scripts/review-planning.sh
```

It uses role `planning-reviewer` with the `read-only` profile; configure a
different provider than for `project-planner`. The reviewed file set is the
planning documents: `docs/PROJECT_DESCRIPTION.md` when present,
`docs/PROJECT_REQUIREMENTS.md`, `docs/architecture.md`, `docs/roadmap.md`, and
the ADRs in `docs/decisions/`. The script supplies their contents and their
diff against `origin/main`. The requirements must be approved first.

Each round is stored as `.agents/reviews/planning-<name>-review-NN.json` with
a generated report, in the same format as feature reviews but without an Issue.
The review covers only the planning documents, so it becomes stale when one of
them is added, changed, or deleted, and stays current otherwise
(`./scripts/check-review.sh`). A planning review is not triaged; it is
revised.

### Planning revision

Let the original project planner handle the findings of a current planning
review:

```bash
./scripts/revise-planning.sh --review .agents/reviews/planning-project-bootstrap-review-01.json
```

It uses role `project-planner` in two phases:

1. **Decide.** Read-only, the planner returns one decision per finding with a
   rationale: `ADOPT`, `REJECT`, `DEFER` (belongs to a later feature), or
   `ESCALATE` (needs a human product decision or a change to the approved
   requirements). Critical and major findings may only be adopted or
   escalated. The decisions are validated like review results, shown to you,
   and recorded only after your approval, as
   `.agents/reviews/<review>-revision.json` with a generated report.
2. **Revise.** A write session resolves exactly the adopted findings. It may
   change only `docs/architecture.md`, `docs/roadmap.md`, and direct Markdown
   ADRs. Any other change, including to the requirements, the description, or
   a review artifact, and any commit fails the run and keeps the worktree for
   inspection.

The scripts find such a change by recording the files of the worktree before
the session and comparing them afterwards; they say when they do. The record
covers every file that Git does not ignore, every ignored file outside an
ignored directory (a `.env`, for example), and everything under `.agents/`.
It leaves out the directories that Git ignores as a whole, such as a Python
environment, `node_modules`, a build output, or a test cache: a session that
runs a command may create or change them, and they are never reviewed or
committed. A secret written into such a directory is therefore not reported.

Escalated findings are listed with the next step: change the requirements
through Project Grill and approve them again, or decide that the finding does
not apply. When the write session fails, the approved decisions stay recorded;
while the review is still current, running the script again applies them
without deciding again.

After a revision the review is stale by design. Run `review-planning.sh` for
the next round, and repeat until the review passes.

### Planning approval

When the latest review round is resolved, approve the planning:

```bash
./scripts/finish-planning.sh
```

The script refuses when a required document is missing, the requirements are
not approved, there is no planning review, the latest review is stale, the
latest round has a critical or major finding, a finding of the latest round
has no revision decision, an adopted finding is not applied yet, or a finding
of the latest round is escalated. It shows every rejected, deferred, and
escalated finding of all rounds, also before a refusal. A finding escalated in
an earlier round is not resolved by a newer review alone: you confirm that it
was resolved, and the approval records that. The approval covers exactly the
reviewed planning; a document that changes while the script waits for your
answer is refused.

The approval is recorded in `docs/PLANNING_APPROVAL.md`, which is committed with
the planning: the time, the planning branch, the final review round, the
review rounds, the findings that were not adopted, and the fingerprint of the
planning documents. Use it for the planning PR description, because review
and revision files are not committed.

Whether the approval is still current:

```bash
./scripts/finish-planning.sh --check
```

exits 0 when it is and 1 when it is missing or stale. `create-feature-issue.sh
<feature-id>` refuses to create a feature Issue from a roadmap without a
current approval.

What makes the approval stale depends on the document:

| Document | Changed after the approval |
|---|---|
| `docs/PROJECT_DESCRIPTION.md`, `docs/PROJECT_REQUIREMENTS.md`, `docs/roadmap.md`, `docs/changes/` | Stale. What the product is and which features it gets changes only through a planning cycle, with a review and your approval |
| `docs/architecture.md`, `docs/decisions/` | Still current. Features keep these up to date, as the Definition of Done asks, and the feature review covers the change. `--check` lists the commits that changed them since the approval |

So a feature that describes what it built in the architecture, or records a
decision in an ADR, does not stop the next feature. The approval file itself
is not touched by a feature, so features that run side by side cannot conflict
in it. The next approval or amendment covers those updates and names their
commits in the record, with the Issue and the review of each, under "Updates
by merged work" or with the amendment. A later approval keeps the entries of
the earlier ones. Until then `--check` lists them. A feature that changes the
roadmap or the requirements is refused by `finish-feature.sh` before its
commit, with the command of the change cycle.

The script finds the approved state from the commit that last changed
`docs/PLANNING_APPROVAL.md`: the planning documents in that commit must have
the recorded fingerprint. Change that file only through `finish-planning.sh`;
after a change by hand that does not match, any difference counts as stale.

Open and merge a planning PR before creating Issues for actionable roadmap
features. The script never implements features, creates Issues, commits,
pushes, opens or merges a PR, or deploys.

## Changing an approved planning

A project changes while it runs: a new feature, a requirement that turns out
different, another technical direction. A change to the planning documents
goes through the same review and approval as the first planning, in its own
planning worktree, while feature work continues in its own worktrees.

Which route a change needs:

| Kind of change | Example | What changes | Command |
|---|---|---|---|
| Fits a feature that is not built yet | Sorting within the recipe list of F03 | Only the feature Issue | None; edit the Issue |
| New feature within the approved requirements | A shopping list the requirements already allow | Roadmap | `--change` |
| New or changed requirement | Sharing between households when one household was agreed | Requirements, and usually architecture, roadmap, and ADRs | `--change --grill` |
| Technical change only | From local storage to a server database | Architecture and an ADR that supersedes the old one | `--change` |
| Small technical amendment | One ADR gets an addition | Architecture and ADRs only | `finish-planning.sh --amend`, without a review |

Write the change down in a short file, in your own words, and start the cycle
from a clean primary checkout:

```bash
./scripts/start-planning.sh shopping-list --change ~/notes/shopping-list.md
```

The name is required. It names the branch `planning/shopping-list` and the
change request, which the script copies to `docs/changes/shopping-list.md`.
The original `docs/PROJECT_DESCRIPTION.md` stays as it is. The script requires
that the planning on `origin/main` has a current approval
(`./scripts/finish-planning.sh --check`).

Without `--grill` the requirements keep their approval and only the planner
runs. It changes what the change requires: the roadmap, the architecture, an
ADR, or several of them. With `--grill`, Project Grill runs first and asks
about the change only. When it changes the requirements, the script shows the
difference and asks for your approval before the planner starts; when it finds
that the approved requirements already allow the change, it leaves them
untouched and no approval is asked.

A change keeps what exists:

- **Feature IDs are stable.** A new feature gets the next unused ID. The
  script refuses a result that removed or renumbered a feature; a feature that
  is no longer wanted stays in the roadmap, marked as dropped.
- **Features with an Issue are not rewritten.** They may be in progress or
  delivered. A change to their behaviour is a new feature that depends on
  them.
- **ADRs are superseded, not removed.** A changed decision is a new ADR that
  names what it supersedes; the old one only gets a status line that says so.
  The script refuses a deleted ADR.

After the session, continue as after the first planning, in the planning
worktree:

```bash
./scripts/review-planning.sh
./scripts/revise-planning.sh --review .agents/reviews/planning-shopping-list-review-01.json    # when the review has findings
./scripts/finish-planning.sh
```

The reviewer receives the change request and the complete planning with the
difference against `main`, and checks the rules above. The approval records
the change request and covers it. Commit, push, and merge the planning pull
request; `cleanup-worktree.sh planning/shopping-list` then removes the
worktree and an untracked original of the change request.

A change to the requirements, the roadmap, the description, or a change
request makes the planning approval stale until the new one is merged. In
between, `create-feature-issue.sh` creates no new Issue. A feature that is
already in progress is not affected.

### A small technical amendment

A change that touches only `docs/architecture.md` and the ADRs in
`docs/decisions/`, such as amending one decision, can be approved without an
agent and without a review round. Make the change by hand on a branch
`planning/<name>` and run:

```bash
git switch -c planning/cache-adr
# edit docs/architecture.md, add or edit an ADR
./scripts/finish-planning.sh --amend "Add a cache in front of the storage."
```

The script shows the difference against `main` and asks for your approval. It
then adds the amendment to the existing `docs/PLANNING_APPROVAL.md`, with the
date, the branch, your reason, and the changed files, and updates the
fingerprint, so the approval is current again. The earlier review rounds stay
in the record, and the entry says that no independent review took place.
Commit, push, and merge as the script prints.

Your approval is the only check here, so the route is narrow. The script
refuses, and points to the change cycle, when:

- the requirements, the roadmap, the project description, or a change request
  changed;
- an ADR was deleted, since a decision is superseded, not removed;
- the planning on `main` has no current approval. An amendment does not repair
  a missing or stale approval;
- the branch does not contain the latest `main`, because the amendment is
  shown and approved against the planning as it is now;
- a required planning document is missing or empty afterwards.

## Creating a feature Issue from the roadmap

When a roadmap feature becomes active, create its Issue from its block in
`docs/roadmap.md`:

```bash
./scripts/create-feature-issue.sh F03
```

The script finds the heading that starts with the feature ID, such as
`### F03 — Sharing`, and uses everything up to the next heading of the same or
a higher level as the Issue body, unchanged. The heading becomes the title, so
the feature ID stays visible and review triage can use it for follow-up
provenance. The script shows the proposed Issue and creates it only after your
approval.

It refuses a feature ID that is missing, used for more than one heading, or
has an empty block, and it does not create a second Issue for a feature that
already has one, open or closed. When the block refers to another feature
whose Issue is still open, it warns before asking.

Create Issues one feature at a time, only for work that is about to start. An
Issue that is not a roadmap feature can still be created from a title and a
body file:

```bash
./scripts/create-feature-issue.sh "Issue title" path/to/body.md [label]
```

## Canonical feature workflow

Start with an actionable GitHub Issue. Create a detailed implementation plan
under `.agents/plans/` for non-trivial work when warranted.

From a clean primary checkout, create the feature worktree and start the
implementation agent:

```bash
./scripts/start-feature.sh 12 player-movement
```

The full interface is:

```text
./scripts/start-feature.sh <issue> [slug] [base-branch] [--agent <agent>] [--model <model>]
./scripts/start-feature.sh <issue> --resume [--agent <agent>] [--model <model>]
```

The slug names the branch and the worktree. Without one, the script derives it
from the Issue title: the title without its feature ID, in lowercase, as at
most four words joined by hyphens. Reading the title is tried three times when
the connection or the service fails for a moment (a timeout, a reset or
refused connection, a host that cannot be resolved, a server error); any other
failure, such as an Issue that does not exist or a refusal, stops at once with
its reason. A connection that keeps failing ends with
status 75, which `run-feature.sh` tries again like any temporary failure. The
script fetches the selected remote base,
creates `feature/<issue>-<slug>` in a sibling worktree, and starts the agent
of role `implementer` inside that worktree. Untracked files in the checkout do
not matter; modified tracked files do, because they would not be part of the
new worktree. After the session it prints the worktree path and the next
commands.

The implementer verifies its result itself: it finishes every edit to a
tracked file and then runs `./scripts/verify.sh`. That pass is recorded and
reused by the review that follows, so you do not run the verification by hand
between the two.

A new worktree has none of the project's ignored files, such as installed
dependencies or a build cache. To prepare them, add an executable
`scripts/worktree-setup.sh` to the project. `start-feature.sh` runs it in the
new worktree before the agent starts, with the path of the primary checkout as
its argument, for example to copy a cache from there:

```bash
#!/usr/bin/env bash
set -euo pipefail
primary="$1"
# On macOS (APFS), -c copies without using extra disk space.
[[ ! -d "$primary/node_modules" ]] || cp -Rc "$primary/node_modules" node_modules
```

The script is optional and only saves time: when it fails, the script reports
that and starts the agent anyway.

### Resuming an interrupted feature

A session can end before the work is complete: a closed terminal, a usage
limit, an agent that got stuck. Continue with:

```bash
./scripts/start-feature.sh 12 --resume
```

Run it from any checkout of the repository. It finds the worktree whose branch
is `feature/12-*` and starts a new implementer session there; it creates
nothing. `--agent` and `--model` let another provider or model continue.

The new session does not have the earlier conversation. It is told to read
the state from the repository: the Issue, the plan, `git status` and the diff
against the base, the latest review or triage if the interrupted session was
resolving findings, and the handoff note.

The handoff note is `.agents/handoffs/<issue>.md`, a working file that Git
ignores. The implementer keeps it while it works, updated after each completed
part and not only at the end, with what is done, what is in progress, what
remains, and what was tried and rejected. A session that ends abruptly may not
have updated it, so the script compares it with the files: changed files that
are newer than the note are named to the new session as not described by it.
Resuming also works without a note.

After a resumed session, continue as after `start-feature.sh`: review, triage,
fixes. When the interrupted session was `apply-triage.sh`, the partial fixes
have made its review stale; resume, then run `review-feature.sh` again.

### The completion gate

A session that ends is not a feature that is complete. An implementer can
stop after two of nine plan steps and end normally, and nothing in the exit
status says so. The scripts therefore decide from what the implementer
recorded, not from the fact that it stopped.

The implementer writes a completion record before it ends, in every session:
`.agents/completion/<issue>.json`, a working file that Git ignores.

```json
{
  "schema": "completion/v1",
  "status": "partial",
  "criteria": [
    {"criterion": "Recipes can be searched by ingredient",
     "status": "met",
     "evidence": "tests/test_search.py::test_search_by_ingredient passes"},
    {"criterion": "The search page works without JavaScript",
     "status": "not_met",
     "evidence": "not started; plan step 4"}
  ],
  "remaining": ["Plan steps 4 to 6: the page without JavaScript, the documentation"]
}
```

`status` is `complete`, `partial`, or `blocked`. A criterion is `met`,
`not_met`, or `not_applicable`, each with evidence. `complete` needs every
criterion met or not applicable and nothing remaining; the other two need
something that remains. A record that breaks these rules is invalid.

The gate passes when the record is valid and says `complete`, and the handoff
note lists nothing under "Remaining". The note outweighs the record: remaining
work listed there means not complete, whatever the record says.

| Script | What the gate decides there |
|---|---|
| `start-feature.sh` | After the session it says whether the Issue is complete, and offers the review only then |
| `run-feature.sh` | Goes on to the review only when the gate passes and the summary of the changes exists; otherwise it resumes the implementer with the reasons in the handoff note, at most four sessions in a run. `blocked` stops the run with status 3. The gate is asked again before every later review, because a session that repairs the verification is a session of the implementer too |
| `review-feature.sh` | Gives the record to the reviewer of the complete feature, as a claim to check |
| `finish-feature.sh` | Refuses a missing, invalid, partial, or blocked record. `--partial` commits partial work as your explicit choice |
| `publish-feature.sh` | Asks the gate again. The pull request closes the Issue only when the commit says `Completion: complete` and the gate still passes; otherwise it is a draft that refers to the Issue and says why it does not close it |

The record is a claim of the implementer, and an implementer can claim
`complete` wrongly. The scripts only read the status. What checks the claim
is the independent review of the complete feature: the reviewer goes through
every acceptance criterion of the Issue against the diff and the tests, and
reports a criterion that is not met, or a `met` the code does not support, as
a major finding. That is why a feature is committed only on a review of the
complete feature (see "Reviewing only the changes").

When you implemented a feature yourself, write the record yourself: it is the
statement that the Issue is done, with where to see it.

### Reviewing a feature

After the implementation agent exits, enter the feature worktree. When
independent review is required by `.agents/policies/autonomy.md`, run it before
committing so the reviewer includes the complete working-tree changes:

```bash
cd ../project-12-player-movement
./scripts/review-feature.sh 12
```

A reviewer cannot run the checks, so the review starts only when
`./scripts/verify.sh` passes for the content under review. The script runs it
first, names the failing check when it fails, and starts no agent then. The
review records that verification passed for the reviewed tree. To have a
failure reviewed, for example when its cause is unclear, pass
`--unverified "<reason>"`; the review then records the reason instead.

The full interface is:

```text
./scripts/review-feature.sh <issue> [base-branch] [--agent <agent>] [--model <model>] [--changes] [--unverified "<reason>"]
```

It uses role `reviewer` with the `read-only` profile. The review is
non-interactive: the reviewer cannot modify files and has no network access, so
the script supplies the GitHub Issue and the complete diff against the base
branch, including uncommitted and untracked changes. The reviewer returns its
result as JSON and the script validates and stores it. An invalid result is
retried once and then rejected, and a reviewer that changed the working tree or
created a commit is reported as an error; in both cases no review is stored.

The diff starts where the feature left its base branch. The feature was
created from `origin/<base>`, and the local `<base>` of your checkout can be
behind it, for example after pull requests were merged on GitHub. The script
therefore uses whichever of the two shares the more recent commit with the
feature, so that work merged before the feature started never counts as the
feature's own change. You do not have to pull the base branch first.

The review script must run from the matching feature worktree and needs an
authenticated GitHub CLI. Each round writes a numbered pair of files without
overwriting earlier reviews:

```text
.agents/reviews/feature-12-player-movement-review-01.json
.agents/reviews/feature-12-player-movement-review-01.md
```

See "Review and triage data" below for the two files.

Triage an explicit review artifact with an agent independent from the
implementation:

```bash
./scripts/triage-review.sh \
  .agents/reviews/feature-12-player-movement-review-01.json
```

The full interface is:

```text
./scripts/triage-review.sh <review-json> [--agent <agent>] [--model <model>]
./scripts/triage-review.sh <review-json> --decisions <file> --reason <text> [--proposal <file>]
```

The triage agent (role `triage`) classifies every finding as:

- `FIX_NOW`: resolve before the feature proceeds. Critical and Major findings
  always use this category.
- `DEFER`: valid non-blocking work proposed as a separate follow-up Issue.
- `ACCEPT`: consciously take no action, with an explicit rationale.

The script validates the decisions before showing them: every finding is
decided exactly once, Critical and Major findings are `FIX_NOW`, and a deferred
finding has a follow-up title, action, and acceptance criteria. Invalid
decisions are retried once and then rejected. A review without findings needs
no triage agent.

The script displays the complete proposal before side effects. Only after
interactive approval does it create one GitHub Issue per `DEFER` finding and
write a persistent, uniquely named artifact such as:

```text
.agents/triage/feature-12-player-movement-review-01-triage.json
.agents/triage/feature-12-player-movement-review-01-triage.md
```

That artifact maps the source review findings to their decisions and any
created Issue numbers. After storing it, the script publishes the review and
triage reports as one comment on the source Issue, so the outcome is visible in
the Issue and, through `Closes #12`, from the pull request. The reports are
rendered from the JSON. When they exceed the size of one GitHub comment, they
are published in numbered parts rather than shortened. A failed publication
keeps the stored triage and prints the command to retry each unpublished
part. Declining the proposal creates neither an artifact nor
Issues. The source review remains unchanged. The artifact is stored only after
every follow-up Issue exists; if creating one fails, nothing is stored and a
new triage reuses the Issues created so far, which it finds by their trace
token. A re-run reuses a follow-up Issue that already exists for a finding.

The order is review, triage, fix, verify, review again. Triage every round
with findings before you fix anything from it; `review-feature.sh` says so.

**Historical triage.** Triage applies to the content that was reviewed, so a
review whose code changed afterwards is stale. When findings were fixed before
their triage, the round can still be triaged as a historical review, provided
a later review round of the same Issue exists (the latest round never
qualifies, so a historical review cannot stand in for a fresh review of the
current code) and its reviewed tree is still in the Git object database. The
triage agent then reads an extract of the reviewed tree, not the live
worktree, and classifies the findings as they were reported; the later review
confirms whether they were fixed. The proposal, the approval question,
`--unattended`, the follow-up Issues and the publication on the Issue are the
same as for any triage, and the artifact records `"historical": true`. When
the review is the latest round, or its tree is gone, the script refuses and
creates nothing: run a new review first and triage the older round after it.
`finish-feature.sh` still needs a current latest review and an approved,
published triage of every round with findings; nothing here replaces either.
The extract holds every path of the reviewed tree (also `export-ignore`
paths) and is a Git repository of its own, because Codex refuses to start in
a directory that is not one. A complete historical triage with Codex as the
`triage` agent has not been verified; the automated tests use fake agents, so
full Codex compatibility is not claimed.

### Owner-directed triage

Approving or declining is not always enough: the triage agent can propose
`FIX_NOW` for a suggestion or a trivial documentation point that you decide to
`ACCEPT`, and running the agent again gives the same proposal. Approving a fix
you do not want costs another implementation, verification and review cycle,
which finds new suggestions. In that case, and only when the agent's proposal
is disproportionate, give the decisions yourself:

```bash
./scripts/triage-review.sh <review-json> \
  --decisions <file> --reason "<why you override>" [--proposal <file>]
```

`<file>` has the shape of the triage schema (`{"decisions": [...]}`, one entry
per finding with `finding_id`, `decision`, `rationale`, and `followup`, which
is required for `DEFER` and `null` otherwise). `--proposal` optionally gives
the decisions the agent proposed (for example its output from an earlier run),
so they are recorded next to yours. The same rules apply as for an agent:
every finding exactly once, no unknown IDs, a follow-up for every `DEFER`, and
critical and major findings stay `FIX_NOW`; an override cannot accept or defer
them. The reason is required, no agent is started, and `--unattended` is
refused. The script shows your exact decisions, the reason and the account, and
asks for your confirmation before it creates follow-up Issues. It then shows
the complete artifact, with the follow-up references, and asks once more
before it stores and publishes it. The files are copied before anything is
shown, and the artifact is stored exactly as shown; only `published_at` is added
when it is published. Declining the second question stores and publishes
nothing; follow-up Issues already created are reused by the next triage.

The artifact has an `owner_directed` object with the `reason`, the `account`
that ran the script, the time (`directed_at`), and the `original_proposal`
when one was given; the comment on the Issue shows them. Old artifacts without
the field stay valid. It is not a way to skip the review: the round still
needs an approved and published triage, `finish-feature.sh` and the other
gates are unchanged, and the stored decisions are protected like every review
and triage artifact, so `apply-triage.sh` and `finish-feature.sh` read them as
they are and an agent that changes them is detected.

Deferred follow-up Issue titles include deterministic provenance:

```text
[F02][R01][S2] Concise follow-up title
```

The script obtains the feature ID from the source Issue title and the review
round and finding ID from the review. When no feature ID is available, it falls
back to the source Issue number:

```text
[#12][R01][S2] Concise follow-up title
```

Apply the approved `FIX_NOW` set from the same feature worktree:

```bash
./scripts/apply-triage.sh \
  .agents/triage/feature-12-player-movement-review-01-triage.json
```

The full interface is:

```text
./scripts/apply-triage.sh <triage-json> [--agent <agent>] [--model <model>]
```

The helper uses role `triage-implementer`. It validates the approved artifact and source review, shows the exact
`FIX_NOW` scope, and asks for confirmation before starting a write-capable
agent. It never passes `DEFER` or `ACCEPT` findings to that agent. After the
agent exits, it verifies that the review and triage artifacts are unchanged and
verifies the result with `./scripts/verify.sh --reuse`, so a pass that the
agent recorded for exactly that content is not repeated.

The helper does not commit, push, merge, deploy, or create/close Issues. Inspect
the resulting diff and run another independent review and triage when fixes
require confirmation.

### Review and triage data

Results that an agent writes and a script consumes are JSON. Each review and
each triage is stored as two files with the same name:

- `.json` is the source of truth. The scripts read only this file.
- `.md` is a report generated from the JSON for reading. It is never parsed;
  editing it has no effect.

Both are working files for the scripts during a feature and are ignored by
Git, so `git add .` does not commit them. The record that stays is the comment
on the Issue and the follow-up Issues, each of which names its source finding.

The agent's result must match a schema in `.agents/schemas/`
(`review.schema.json`, `triage.schema.json`). The schema is passed to the
provider CLI and the script checks the result again with `jq`, including rules
a schema cannot express. For a review, the verdict must follow from the
findings: `PASS` without findings, `PASS_WITH_MINOR_FINDINGS` with only minor
or suggestion findings, and `CHANGES_REQUIRED` with at least one critical or
major finding. What a reviewer could not verify belongs in `limitations` and
does not change the verdict.

The script, not the agent, numbers the findings: `C1` (critical), `M1` (major),
`MIN1` (minor), and `S1` (suggestion). Triage decisions and follow-up Issues
refer to those identifiers. When a result is invalid, the agent is asked once
more, with the reasons for the rejection.

Stored artifacts are checked with the same rules as agent results, plus the
fields the scripts own, so editing a stored artifact cannot weaken a decision.

Documents that people maintain, such as the roadmap, requirements, and
architecture, keep Markdown as their source.

### Reviewing only the changes

Every round reviews the complete feature by default, also after a fix. That
costs a full review each time, and it is what finds a problem that an earlier
round missed: a later complete round regularly reports something in code that
did not change.

A review of changes confirms fixes. It does not establish that the Issue is
done, so **a feature is committed on a review of the complete feature**:
`finish-feature.sh` refuses when the latest round reviewed only changes, and
asks for a complete round. A round of changes is for the rounds in between.

After a small fix you can limit a round to what changed since the previous
one:

```bash
./scripts/review-feature.sh 12 --changes
```

The reviewer then receives the difference between the content that the
previous round reviewed and the current content, with the findings of that
round and what an approved triage decided about each; without one, every
finding counts as to be fixed. It checks that every finding
that was to be fixed is resolved, reviews the changed lines and what they
affect, and leaves the rest of the feature alone. The review records its
scope, its report says so at the top, and the commit message of
`finish-feature.sh` names it.

Use it when the fix is small and local. Run a complete round when the fix
touches several parts, changes behaviour beyond the finding, or when you are
not sure. The script refuses `--changes` when it cannot build on the previous
round:

- there is no previous round;
- nothing changed since it;
- the base of the branch changed, for example after merging `main`, so the
  feature differs in more than your changes;
- the content that the previous round reviewed is no longer in the object
  database.

`finish-feature.sh` accepts a review of changes only as the latest round when
it builds on exactly the content of the round before it, back to a complete
review. Otherwise it asks for a complete round.

### When a review becomes stale

Every review records a fingerprint of what it reviewed (`reviewed_tree`): the
Git tree hash of the file contents at review time, including uncommitted and
untracked changes. Review and triage artifacts and ignored files are not part
of it, except files Git already tracks. A review may instead cover an explicit
list of files (`reviewed_paths`); then only those files count.

The fingerprint depends on content, not on commits. Committing the reviewed
content keeps the review current; changing, adding, or deleting a covered file
makes it stale. `apply-triage.sh` refuses a stale review before it starts an
agent. `triage-review.sh` refuses it too, unless it is a historical review (a
later round of the Issue exists and the reviewed tree is available; see
"Historical triage" under `triage-review.sh`). After `apply-triage.sh` changes the code, the
review is stale by design: run a new review round, complete or with
`--changes`, to confirm the fixes.

Check a review yourself with:

```bash
./scripts/check-review.sh .agents/reviews/feature-12-player-movement-review-01.json
```

It exits 0 when the review is current, 1 when it is stale, and 2 on an error.
Every script that refuses a stale review, and `check-review.sh`, first lists
the files that changed since the review, as added, modified, or deleted.

### Finishing a feature

When the latest review round is resolved, finish the feature from its
worktree:

```bash
./scripts/finish-feature.sh 12 "Implement player movement"
```

The script refuses another branch than `feature/12-*` or a tree without
changes, and a feature whose completion gate does not pass (see "The
completion gate"). It verifies the result with `./scripts/verify.sh --reuse`,
and checks the latest review of the
feature: it must be current, cover the complete feature, and have no critical
or major finding. Every
review round with findings needs an approved triage that was published on the
Issue (the newest triage of that round counts), and the latest round may have
no `FIX_NOW` findings left to apply. After fixes, run a new review round first;
a passed newer round confirms the fixes of earlier rounds. A failed
publication can be repeated with `./scripts/triage-review.sh --publish
<triage-json>`.

It then stages all changes (review and triage files are ignored) and opens a
structured commit message in your editor: the summary, the Issue, the list of
changes, the completion statement with the evidence per criterion, the
verification, the review round and verdict, and `Refs #12`.
Emptying the message aborts the commit and leaves the changes staged. The
script never pushes, opens a PR, or merges.

The list of changes comes from `.agents/summaries/<issue>.md`, which the
implementer writes and keeps up to date when fixes change what the feature
does: every line that starts with `- ` is taken over. Like the manual steps
it is a working file and is not committed. Without it the message has a line
for you to fill in; an unattended commit, which nobody edits, is refused.

Work that is not complete is committed only as your explicit choice:

```bash
./scripts/finish-feature.sh 12 "Add the first part of player movement" --partial
```

The completion record has to say `partial` or `blocked` itself, with what
remains: a record that says `complete` against a handoff note with remaining
work is refused also with `--partial`, because the commit message is made
from the record. The commit message
carries `Completion: partial` with the criteria and what remains, and
`publish-feature.sh` opens a draft pull request that does not close the Issue.
`run-feature.sh` never uses the option.

A change that `.agents/policies/autonomy.md` classifies as low risk may be
finished without an independent review; the reason is recorded in the commit
message:

```bash
./scripts/finish-feature.sh 12 "Fix a typo in the README" --no-review "documentation only"
```

When the feature needs a step that only you can do, such as a repository
setting or a secret, the implementer records it in
`.agents/manual-steps/<issue>.md`. `finish-feature.sh` shows those steps before
the commit and records them in the commit message under `Manual steps:`; the
file itself is a working file and is not committed.

Then publish the feature:

```bash
./scripts/publish-feature.sh 12
```

The script pushes the branch and opens a pull request whose description is
the commit message, the manual steps, and `Closes #12`. For a pull request
that is already open it pushes and replaces the description with the current
one, since a fix round can change the manual steps. It never merges.

`Closes #12` is written only for a complete feature: the commit carries
`Completion: complete` of `finish-feature.sh`, and the completion gate, asked
again, still passes. In every other case the pull request is opened as a
draft, refers to the Issue, and says why it does not close it: the feature
was committed as partial, the gate does not pass any more, or the commit was
made without `finish-feature.sh` and has no completion statement. A draft is
marked ready when a later publish finds the feature complete, and a pull
request that was ready goes back to a draft when the work published to it is
not complete.

GitHub closes an Issue on a closing keyword (`Closes`, `Fixes`, `Resolves`,
and their forms) next to its number, in a pull request description and in the
message of a merged commit. For work that may not close the Issue the script
therefore turns such a keyword in the text it takes over into `Refs`, and it
refuses to publish, before pushing, while a commit of the branch carries one:
reword that commit, or complete the feature.

**Bringing a finished feature up to date with its base.** When the base
branch moved on after `finish-feature.sh`, for example because a conflict has
to be resolved, merge the base into the feature branch and publish again:

```bash
git merge origin/main
./scripts/publish-feature.sh 12
```

The script takes the statement, the description, and the title from the
commit that `finish-feature.sh` made: merge commits of the base after it are
passed over, since they change nothing of the feature itself. Any other
commit after the finish has no statement, and the pull request becomes a
draft until the feature is finished again. Run `./scripts/verify.sh --all`
after the merge; a review that was done before it covered the feature, not
the merge.

The script ends once the pull request is open and prints its address. Follow
the checks there and merge after they passed. Local verification during a
feature never runs on a clean checkout, and may run on another operating
system than CI, so a failure can appear in CI only; a pull request must not be
merged while a check fails.

- When the base branch requires a passing status check, through a ruleset or
  branch protection, GitHub refuses that merge, and the script says so.
- When it does not, the script warns: nothing but your own look at the checks
  stops the merge. `docs/repository-setup.md` describes how to add the rule,
  and `./scripts/doctor.sh` reports a `main` without one.

`--wait` keeps the script running until the checks finish, to have the result
in the terminal: all checks passed, or a non-zero exit and the advice not to
merge when one failed. After a failed check, fix the cause in the worktree,
then review, finish, and publish again.

After the merge GitHub closes the linked Issue. From the primary checkout,
remove the merged worktree and its branch:

```bash
./scripts/cleanup-worktree.sh 12
```

The script asks GitHub whether the branch's pull request is merged, so it also
works after a squash merge. A branch counts as merged when its tip is the head
of the merged pull request or an ancestor of it: after "Update branch" on the
pull request, or a push from another checkout, the branch on GitHub is ahead
of the local one, and the local branch still holds nothing that was not
merged. A merged head that is not in the local repository is fetched from the
pull request first; when that fails, the worktree is kept and the script says
why. It refuses an unmerged worktree, a branch with a local commit that the
merged pull request does not contain, and a worktree with uncommitted changes;
ignored review and triage files do not count. After removing the worktree and
the local branch it fast-forwards `main` when the primary checkout is on `main`
without modified tracked files; untracked files do not prevent that. After a
merged planning it also removes an untracked file in the primary checkout that
is identical to `docs/PROJECT_DESCRIPTION.md`, such as the original idea file. A planning worktree is cleaned with
`./scripts/cleanup-worktree.sh planning/<name>`, every merged worktree at once
with `--merged`, and an abandoned, unmerged one with `--discard` after
confirmation.

### Running feature steps without questions

The steps of a feature that ask you something, or that start an agent in your
terminal, accept `--unattended`. The step then asks nothing and ends by
itself, so a script can run one step after the other.

| Step | With `--unattended` |
|---|---|
| `start-feature.sh <issue> [--resume]` | The implementer runs with the `unattended` profile instead of in your terminal. Its final message is stored in `.agents/run/<issue>-implementer.md` in the feature worktree and shown. |
| `triage-review.sh <review-json>` | The proposed triage is approved without a question (not for `--decisions`, which is refused). The proposal is validated as always: a critical or major finding cannot be deferred or accepted. |
| `apply-triage.sh <triage-json>` | The fixes start without confirmation, with the `unattended` profile. The final message is stored in `.agents/run/<issue>-fixes.md` and shown. |
| `finish-feature.sh <issue> "<summary>"` | The commit message is used as it is, without an editor. Without a summary of the changes the commit is refused: nobody would write one. |

`review-feature.sh` and `publish-feature.sh` ask nothing as they are. The
planning is yours to decide: its steps refuse the option.

The option needs the working files to be ignored by Git, as the template's
`.gitignore` does with `.agents/run/`, `.agents/summaries/`, and
`.agents/completion/`; a step stops
when they are not. A project that was created from an earlier version of the
template gets the rules with `./scripts/sync-template.sh`.

An unattended agent cannot ask you anything. It is told to stop when it
needs a decision of yours, or when the work conflicts with the Issue's scope,
the architecture, or an ADR: it then records the question in the handoff note
and ends its final message with a line `BLOCKED: <reason>`. The step shows
the reason and exits with status 3, which it uses for nothing else, so a
blocked session can be told apart from a failed one. Answer in the handoff note or change the Issue, and
continue with `./scripts/start-feature.sh <issue> --resume`.

`BLOCKED` is only for a decision. The agent is told not to use it when its
own run of `./scripts/verify.sh` fails on something outside its work, does not
finish within the session, or cannot run on the machine: it reports that in
its final message and ends normally. The step that follows verifies the
result itself: `review-feature.sh` and `apply-triage.sh` exit with status 4
when the verification fails, apart from every other failure, and
`run-feature.sh` repeats and repairs it as described under "Running a feature
with one command". Common causes on your side are a tool that
is not in the `PATH` of the terminal you started from, and a verification
that takes longer than one command of an agent session may.

A triage that was approved this way says so: the artifact has
`"unattended": true`, and the report and the comment on the Issue state that
no human approved the decisions. Deferred findings still become follow-up
Issues, and accepted findings keep their rationale, so you can read
afterwards what was decided without you.

The files in `.agents/run/` are working files, ignored by Git. An unattended
Codex session also writes, next to its final message, its events, one JSON
object per line, with `.events` added to the name, and what it writes on
standard error, with `.log` added; the end of both is shown when the session
fails, and the run records read the token usage from the events.

### Running a feature with one command

`run-feature.sh` runs the steps of a feature one after the other, from the
implementation to the open pull request, without asking anything:

```bash
./scripts/run-feature.sh 12
```

```text
./scripts/run-feature.sh <issue> [slug] [base-branch] [--implemented]
```

From the primary checkout it runs:

1. `start-feature.sh <issue> [slug] [base-branch] --unattended`: the worktree
   and the implementation. The run goes on only when the completion gate
   passes and the implementer wrote the summary of the changes. Otherwise it
   resumes the implementer, with the reasons in the handoff note, for at most
   four sessions in a run (`RUN_FEATURE_SESSIONS`).
2. `review-feature.sh`, and for a review with findings `triage-review.sh
   --unattended` and, when the triage has `FIX_NOW` findings,
   `apply-triage.sh --unattended`, followed by the next review round. This
   repeats until a review of the complete feature has no findings or its
   triage has nothing to fix.
3. `finish-feature.sh --unattended`, with the title of the Issue as the
   summary of the commit, and `publish-feature.sh`.

It uses at most five review rounds. The first round reviews the complete
feature; a round after fixes reviews only what changed since the round before
it (`review-feature.sh --changes`). That review knows what was decided about
the earlier findings, so a finding that was deferred or accepted is not
reported, triaged, and turned into a follow-up Issue again in every round.
The round that ends the run reviews the complete feature again, against the
Issue and the completion record: a feature with one fix round therefore has
three reviews, the complete feature, the fix, and the complete feature.
When the base of the branch changed between two rounds, for example because
you merged `main` into it while the run was stopped, the next round reviews
the complete feature.
The agents and models are those of the roles in `.agents/agents.conf`.

What stays with you: choosing the feature and creating its Issue, reading the
pull request, following its checks, merging, and `cleanup-worktree.sh`. The
run never merges, never pushes to `main`, and never removes a worktree.

The run decides the outcome of every step itself, from exit statuses and from
the result of the checks. What an agent writes decides one outcome only, and
only together with what it recorded:

| Outcome | How the run establishes it | What it does |
|---|---|---|
| Completed | The step exits 0 | Goes on |
| Temporary | An agent or a connection fails: a usage limit, a timeout, the network | Tries the step again, three times, with a wait that doubles from two minutes. A fix session that had already changed the content is taken up with `apply-triage.sh <triage-json> --continue`: the same findings, contract, and protections, for the session of this triage that was left unfinished, and for nothing else |
| Unstable check | The verification is repeated once, and no check failed in both runs | Records the checks and goes on, at most three times in a run |
| Failed verification | A check failed in both runs | Resumes the implementer with those checks in the handoff note, at most three times (`AGENTS.md`); a review follows. A repair session is retried like any other |
| Blocked | An agent ends with `BLOCKED:` and the handoff note holds a question under "Open questions", or the completion record says `blocked` | Stops with status 3. Without such a question there is nothing to answer: the line is ignored and the run goes on |
| Not complete | The implementer ended normally, but the completion gate does not pass: no record, an invalid one, `partial`, remaining work in the handoff note, or no summary of the changes | Resumes the implementer with the reasons in the handoff note, at most four sessions in a run. Nothing is reviewed or committed before the gate passes |

Every interruption is written to `.agents/run/<issue>-log` in the feature
worktree, one line each: the time, the step, the outcome, the reason, and
what the run did. The output of the last step is kept next to it in
`<issue>-step.log`, and that of a repeated verification in
`<issue>-verify.log`. Status 4 is kept for a failed verification: the scripts
turn an agent that happens to exit with it into an ordinary failure. `RUN_FEATURE_RETRIES`, `RUN_FEATURE_RETRY_WAIT` (seconds),
and `RUN_FEATURE_REPAIRS` change the limits for one run.

The run stops with a non-zero status, and keeps the worktree, when:

| Stop | Status |
|---|---|
| An agent needs a decision of yours, or reports a conflict with the Issue's scope, the architecture, or an ADR. Its question is in the handoff note | 3 |
| An agent or a connection keeps failing after the retries | 1 |
| The verification still fails after three repairs, or checks are unstable more than three times | 1 |
| The proposed triage is invalid, for example because it defers a critical or major finding | 1 |
| Five rounds are used and the last one still has a finding that must be fixed, or reviewed only changes | 1 |
| The implementer ended four sessions without completing the Issue | 1 |
| The completion record says `blocked` | 3 |
| The fixes changed nothing, the commit is refused, or the pull request cannot be opened after the retries | 1 |

It then says why it stopped and which command resolves it. After that, run
the same command again: `./scripts/run-feature.sh <issue>`. The run reads
where the feature stands from the worktree, so every step that is done is
skipped: a current review is not repeated, a stored triage is not made again,
and a committed feature is only published. The one thing it records itself is
that the completion gate passed, in `.agents/run/<issue>-state`. As long
as that is missing, the next run resumes the implementer, as
`start-feature.sh <issue> --resume` does. The same happens after a fixing
agent stopped for a decision of yours: the implementer reads your answer in
the handoff note and continues, and a review follows. When you completed the
implementation in a session of your own, say so with `--implemented`, and the
run continues with the review without a session of the implementer; the
completion gate has to pass for that too, so write the completion record and
the summary first. You can also take over by hand at any point:
the single scripts work on the same files.

Know what you hand over before you use it:

- An unattended agent runs commands on your machine while nobody watches.
  Codex stays inside its workspace sandbox; Claude decides with its own
  permission check. Neither gets the tools of your configuration. See
  "Configuring agents".
- Nobody approves the triage. The validation still refuses to defer or
  accept a critical or major finding, but a minor finding or a suggestion
  can be accepted or deferred wrongly. You see that in the pull request and
  on the Issue, where every finding is published with its decision, instead
  of before the fixes. Read that record before you merge.
- The completion record is the implementer's own claim. The run acts on its
  status; whether the claim holds is judged by the reviewer of the complete
  feature, and by you in the pull request, where the commit message lists
  every criterion with its evidence.
- Up to four implementer sessions and up to five review rounds, each with a
  triage and a fix session, use the
  usage limits of your agents without a moment at which you can stop them.
- The commit message is not edited: its summary is the title of the Issue
  and its list of changes is what the implementer wrote.

### The merge approval gate

A feature may update the architecture and add an ADR, and in an unattended
run nobody reads a pull request before it could be merged. The gate decides
which pull requests only you may merge. It rests on what the diff contains;
the judgement of a model is a second line, never the only one.

| Source | What it looks at | Who decides |
|---|---|---|
| Rules on the diff | ADRs, protected and sensitive paths, the verification configuration | `scripts/check-guardrails.sh` |
| Independent review | The impact of the whole feature on the architecture | The reviewer, in `architecture_impact` of its result |

The heaviest of the two decides. Your approval is needed when the diff
changes a protected path, when the reviewer classifies the impact as `major`
or `breaking`, or when there is no valid classification, as for a feature
finished with `--no-review`.

**The rules on the diff.** Always protected, in every project:

- every ADR in `docs/decisions/` that is added, changed, or removed. A new
  ADR can replace an accepted one without touching its file, so no ADR passes
  without you. A feature writes a new ADR with the status `Proposed`;
- the CI workflows, and the configuration, scripts, prompts, and schemas that
  carry out the gate;
- in `scripts/verify.conf` and `scripts/verify-workflow.conf`: a changed or
  removed line. An added check is sensitive.

What is fundamental in your project you list in
`.agents/policies/guardrails.conf`, as Git pathspecs:

```text
protected: site/_quarto.yml .github/CODEOWNERS deploy
sensitive: docs/architecture.md pyproject.toml
```

A protected path needs your approval. A sensitive path does not: it is named
to the reviewer, who has to look at it. Keep the protected list short, or
every feature waits for you.

The rules are always read from the base branch as it is now, never from the
feature itself, so a feature cannot relax the rules it is checked by; a
change to them is protected. Locally the rules of your base branch and of
`origin/<base>` both apply, whichever is behind; the script does not fetch,
and CI checks every pull request against the base on GitHub.

```bash
./scripts/check-guardrails.sh                      # this worktree against its base
./scripts/check-guardrails.sh --commits main HEAD  # two commits
```

**The reviewer's classification.** A feature review must return
`architecture_impact`: `none`, `minor`, `major`, or `breaking`, with a
rationale and the ADRs and rules it was checked against. The implementer does
not classify its own change. A review without a valid classification is
rejected.

**What happens.** `finish-feature.sh` records the decision and its reasons in
the commit message, under `Merge approval:`, and `publish-feature.sh` in the
pull request. A feature that needs your approval still gets its pull request;
`run-feature.sh` ends with `MERGE APPROVAL REQUIRED`. No script merges a pull
request, and an agent or a queue that merges for you must skip one that says
`required from the project owner`.

**In CI.** The workflow `Guardrails` runs the gate on the actual diff of every
pull request, with the script and the rules of the base branch and without
running code of the pull request. It fails when the diff changes a protected
path. It is a signal and not the required check, so that you can merge after
reading what it lists.

**Your approval is your own merge.** You merge the commit you see, so an
approval never carries over to content that changed afterwards. This is an
agreement that the scripts and agents keep, not a lock: the agent works with
your GitHub account and could do what you can do. A lock needs a separate
identity for the agent, with code owners and required reviews on GitHub.

## Run records

The workflow records how long every step of a feature or a planning took and
how many tokens its agents used. The scripts and the agent adapter record it;
agents estimate nothing. It is a local record for you: nothing is sent to
GitHub.

**A run** is one command that you start: `./scripts/run-feature.sh 12`,
`./scripts/review-feature.sh 12`, `./scripts/revise-planning.sh ...`, or
`./scripts/verify.sh` in a feature or a planning worktree. The
commands that a run starts itself belong to it, so nothing is counted twice. A
command that you start again, such as `start-feature.sh 12 --resume`, is a new
run that names the run before it.

**Where the records are**, in the primary checkout, ignored by Git:

| Path | What |
|---|---|
| `.agents/run/records/<run-id>.jsonl` | One file per run, written while it runs, never rewritten. All worktrees write here, so a record survives the removal of a worktree, and two runs never share a file |
| `.agents/records/feature-<issue>.jsonl` | The runs of a feature together, written by `publish-feature.sh` and again by `cleanup-worktree.sh` before it removes the worktree; at the end of a run an existing copy is brought up to date, so that it holds the end and the status of the run. A run whose file is gone stays in the copy |
| `.agents/records/planning-<name>.jsonl` | The runs of a planning together, written by `finish-planning.sh` and by `cleanup-worktree.sh` |

The records live on one machine: a new clone and `git clean -fdx` do not keep
them. Copy the two directories when you want to keep them. `cleanup-worktree.sh`
keeps a worktree whose records it could not copy. In a project whose
`.gitignore` does not ignore `.agents/run/` and `.agents/records/`, nothing is
recorded, since a record would otherwise be committed; `sync-template.sh`
brings the rules.

**What a line holds.** Every line is one JSON object with `schema`
(`run-record/v1`), `run`, `time` (UTC), `epoch`, and `type`:

| `type` | Fields |
|---|---|
| `run-start` | `kind` (`feature` or `planning`), `subject` (the Issue or the name of the planning), `command`, `seq` (the number of the run within its subject, which orders runs that start in the same second; claimed with a link in `.agents/run/records/.sequence/`, `null` when it could not be claimed), `previous` (the run before it of the same subject), `repository` (owner/name), `versions` (the template commit, a hash of the prompts and of `agents.conf`) |
| `run-end` | `status`: the exit status; 130 when the run was interrupted. A run without an end was killed and is incomplete, and a start without its end shows what was going on |
| `agent-start`, `agent-call` | an agent call begins (`id`, `role`, `profile`, `agent`, `model`) and ends (the same, with `status`, `seconds`, `usage`) |
| `verification-start`, `verification` | a verification begins (`id`, `groups`: `all`, or the groups of `--only`) and ends (with `status`, `seconds`, and `reused`: a recorded pass stood in for the run) |
| `step-start`, `step` | a step of `run-feature.sh` begins (`id`, `name`) and ends (with `status` and `seconds`) |
| `wait-start`, `wait` | the pause before a step is tried again: the `planned` seconds, and the `seconds` it really took |
| `intervention` | `what` you did that a script saw: an approval, a resume by hand, `--implemented`, `--partial` |
| `resumed` | the run follows a run of the subject that stopped with `previous_status` other than 0 (`after` is that run); for a feature, `handoff_changed` says whether the handoff note changed after the stop (never its content). Who started the run or changed the note is not known, so this is not an intervention |
| `note` | a line of the log of `run-feature.sh` (`.agents/run/<issue>-log`), which is written from the same event |
| `completion-gate` | one check of the completion gate: `check` (its number in the run), `sessions` (the sessions of the implementer and the triage implementer that the run recorded before it, a repair or a retry too), `session` (the last of them, which the check judges; a check without a new session judges it again), `status`, `reasons`, and `content`, the fingerprint of what it judged |
| `artifact` | a review or a triage that the run wrote: `kind` and `path` |
| `experience-notes` | a session of the run changed the agent's experience notes: the `call` and the `hash` of the notes |
| `experience` | the experience record of a feature run, under `record`: see below |

**Token usage** keeps the field names of the provider, with `source` saying
where it came from: `claude-result` (the result of an unattended or a
read-only Claude session), `codex-events` (the events of a Codex session),
`interactive` (a session in your terminal, which reports nothing), or
`unavailable`. A figure the provider did not report is `null`, never zero.
A Codex call adds up its turns; a field that one turn did not report is
`null` for the call, and what the other turns reported is under `partial`, so
an incomplete sum never passes for a total.
`total_input` adds up what the provider counts as input: Claude reports the
input, the cache creation, and the cache reads apart, and they are added;
Codex reports input tokens that already include the cached ones.

**Time.** `seconds` of a call or a step is elapsed time. The elapsed time of a
run is the difference between its start and its end; the sum of its calls can
be higher when work runs side by side.

No prompt, no answer, no secret, and no transcript is recorded: every event
passes a filter that replaces what looks like a key or a token, a private key
with its whole body, by `[redacted]`. A record that
cannot be written is reported, and the work goes on with its own outcome.

### Reporting on the records

```bash
./scripts/report-runs.sh 12                         # one feature; in its worktree, without the number
./scripts/report-runs.sh 12 14 15                   # side by side, with what differs
./scripts/report-runs.sh planning:final-curriculum  # a planning cycle
./scripts/report-runs.sh --all --since 2026-10-01   # every subject, runs from a date on
./scripts/report-runs.sh --all --split 2026-11-01   # the features before and after a change
./scripts/report-runs.sh 12 --json                  # the same as JSON
```

A report shows per subject the outcome of its runs, the elapsed time, the
agent time, the review rounds, the triage, and the repair sessions, the tokens
per role, model, and run, the verification, the steps of `run-feature.sh`, the
recorded interventions, and the versions the runs used. It reads the run files
and the copies of the primary checkout; a run is read from its own file while
that exists and from the copy of its subject otherwise, so nothing is counted
twice and a feature whose worktree is gone gives the same totals. It needs no
network.

Some figures need care:

- **Elapsed time** is the time during which at least one run of the subject
  went on: runs side by side count once. A subject with a run without an end
  has an elapsed time of "at least", and `--split` leaves it out of the means
  of elapsed time and says how many. **Agent time** is the sum of the agent
  calls, and is higher when calls ran side by side.
- **A call or a step that did not finish**, as in an interrupted run, counts
  as unfinished: its time and its tokens are unknown.
- **Tokens** that a call did not report are not zero. A sum to which some
  calls reported nothing says "at least" and how many calls lack figures; a
  sum without any figure is "unknown". `--split` leaves such features out of
  the means of tokens and says how many.
- **A subject without any record** is named and left out, not counted as zero.
- **A comparison** names what differs between the subjects: the template
  commit, the prompts, `agents.conf`, and the models. It and `--split` say
  that totals and means show no cause: features differ in size and
  difficulty.
- **Interventions** are what a script saw you do. A run that follows a
  stopped run is counted apart, since who started it is not recorded.

**The summary on GitHub.** `./scripts/publish-feature.sh 12 --summary` also
posts the totals of the feature on its Issue: the elapsed time, the number of
runs, the review rounds, the repair sessions, and the tokens per role and
model. It is off by default, since a repository is often public. It is built
from an explicit list of numeric fields, so no log, path, time of day, status
reason, or other text of the records reaches it; a role or a model name that
does not look like one is shown as `other`. It is one comment, replaced when
the feature is published again, and a failure to post it only warns.

### Experience records

At the end of every run of a feature, except a verification on its own, the
run file gets an experience record: compact observations of the run, kept
with its run records, copied with them, and never published. It supplements
the handoff note, the completion record, the reviews, and the triage, and
replaces none of them.

**What a script derives, always.** Without an agent and without tokens, from
what the run itself wrote, as it recorded it when it wrote it (an `artifact`
event for a review or a triage), so that nothing of an earlier run or of a run
beside it counts: the review rounds and their findings
per severity, what the triage decided, the verifications that failed and
those for which a later verification of the same checks passed, why the run
stopped (status 3: a decision of yours; 130: interrupted), the outcome of the
completion gate after each session
(each check of the gate is a `completion-gate` event, with the number of
sessions before it, its reasons, and the content it judged), and the completion record at the end. The
artifacts are read from the worktree of the feature, also when the run was
started from the primary checkout. The record names the code version: the
commit, the content of the worktree with its uncommitted changes, and the
commits and contents the reviews of the run covered. Each becomes an observation of
the kind `fact`, with a reference to its evidence: the review and finding,
the triage, the run record, the handoff note, or the completion record. A
finding without a triage in the run says that its evidence is missing. A run
with nothing to observe says so (`none_relevant`).

**What the agent adds, optionally.** The implementer may write what only it
knows in `.agents/experience/<issue>.json`, which Git ignores (the prompt
shows the format): per observation its `kind` (`fact`, `hypothesis`, or
`proposal`), `what` happened, the `circumstances`, what was `tried` and its
`result`, the `evidence` (each with only a `type` and a `ref`) or the
`missing_evidence`, the `uncertainty`, and
`corrects` for an observation of an earlier run that it corrects. Notes count
for the run whose session of the implementer or the triage implementer wrote
them (an `experience-notes` event with their hash, never their content), and
only while the file still holds what that session left. They are checked: notes that are not
valid, such as a fact without evidence or a field the format does not know,
are reported and not kept.

**Never a gate.** A record that cannot be made is reported, and the run keeps
its own outcome; nothing in a review, the completion gate, `finish-feature.sh`,
or `publish-feature.sh` depends on it. A record is written once and never
rewritten, so the original observations stay, and a correction is a new
observation that names what it corrects. A record changes nothing in the
repository. What looks like a secret is replaced by `[redacted]`, a private
key with its whole body, and the handoff note and the transcripts are not
copied. The limit of 20 observations applies to the notes of the agent; what
a script derives is as long as the run was.

```bash
./scripts/show-experience.sh 12         # the records of feature 12, as Markdown
./scripts/show-experience.sh 12 --json  # valid and invalid records apart
```

`show-experience.sh` checks every record and lists a record that is not valid
under "Invalid records", with what is wrong, also a line that is not JSON,
with its file and line, and a record that names
another run or Issue than the one it belongs to: it is never a source for an
analysis, and it hides no valid record. Nothing moves from a record to `.agents/lessons/` by itself; that is
a proposal of an analysis and your decision.

### Analysing several runs

```bash
./scripts/analyze-runs.sh 12 14 15          # these features
./scripts/analyze-runs.sh --since 2026-10-01  # the features with runs from a date on
./scripts/analyze-runs.sh --last 10         # the ten features whose first run started last
./scripts/analyze-runs.sh 12 14 --input-only  # the input only, without an agent
```

You start an analysis by hand. It compares the run statistics
(`report-runs.sh`) and the valid experience records (`show-experience.sh`) of
the selected features, looks for recurring errors and blocks, the causes of
extra review and repair rounds, the steps that cost the most time or tokens,
ways of working that succeeded, and assumptions or observations that
contradict each other, and proposes improvements in order of priority.

**The analyst is read-only**: a role of its own in `.agents/agents.conf`
(`analyst`), run as a read-only session. An analysis that changed the working
tree fails, and nothing of it is kept. Nothing reaches the knowledge, the
prompts, or the checks of the project by itself: each proposal names its
place, and you take it through the review and approval that apply there.

| Place | What |
|---|---|
| `adr`, `agent-instruction`, `skill`, `documentation` | a change you make in the project, with its review |
| `script-check` | an enforceable check in a script of the project, also named in `enforceable_check` |
| `issue` | a separate Issue of the project |
| `template` | the workflow scripts, prompts, or schemas: a project takes them over with `sync-template.sh` and cannot repair them locally, so it is an Issue in the template repository |

**What the script checks in the result**, before it keeps it (one corrected
attempt is allowed):

- every conclusion cites evidence, and only ids that are in the input: runs,
  observations (`<run>/<observation>`), and `statistics/<kind>/<subject>`;
- a `finding` rests on at least two runs; one observation is a `hypothesis`
  or a `single-observation`, never a general rule;
- every conclusion says which differences in task size, model, and workflow
  version it considered;
- a proposal that concerns the workflow scripts is placed in `template`;
- no conclusion at all is valid only as `insufficient_evidence`, which is a
  valid outcome.

**Reproducible and not counted twice.** Every analysis is kept in
`.agents/analysis/<time>-<input>/` of the primary checkout, ignored by Git:
`input.json` with the selection and its runs (a period selects runs, so the
observations of a run outside it are not in the input), the template commit,
the commit of the repository, and a content hash of the workflow as it is in
the working tree (the scripts, the prompts, the schemas, and `agents.conf`),
with whether it has uncommitted changes; `sources/` with the prompt, the
schema, and `agents.conf` as they were used, and every file the analyst says
it read besides the input (`consulted`); `analysis.json` with the result and
the evidence it used; and `report.md`. An analyst that changed the working
tree, also a file that was changed already or a review or triage artifact,
fails. The next analysis gets that
evidence as `already_analysed`, and the report marks a conclusion that rests
on it as used by an earlier analysis: the same observations are no new,
independent evidence. The input holds the compact records; the analyst reads
more only where a conclusion needs it.

## Linking a feature plan

To add or update the plan reference in an existing Issue:

```bash
./scripts/update-issue-with-plan.sh 12 .agents/plans/12-player-movement.md
```

The helper manages one delimited plan block in the Issue body. Re-running it
updates that block instead of appending duplicates. It stores only the
repository-relative plan path; the detailed plan remains in `.agents/plans/`.

## Taking over template changes

A project is created as a copy of the template and does not receive later
template changes by itself. `scripts/sync-template.sh` takes them over:

```bash
./scripts/sync-template.sh
```

Run it from the primary checkout without uncommitted changes to tracked
files. On `main` it first creates a branch `fix/sync-template-<commit>`. It
fetches the template named in `.agents/template.conf`, lists the template's
commits since the version the project has, and applies them to the files
listed under `paths:` in the template's version of that file. Every other
file is the project's own and is never touched. To keep a listed file as the
project's own, add `:(exclude)<path>` to `paths:` in the project's
`.agents/template.conf`; the project's exclusions always apply.

| Situation | What the script does |
|---|---|
| The project did not change the file | Replaces it with the template's version |
| Both changed it | Merges the two; a conflict is marked in the file and reported |
| The template added the file | Adds it; a file of the project at that path is merged against nothing and left as a conflict |
| The template removed the file | Reports it; the project decides whether to delete it |
| The template changed a file the project deleted | Reports it and leaves it out |
| The template started to list a file under `paths:` that already existed in the previous version (changed in the range or not) | Adds it when the project has no such file; keeps the project's file with other content and reports it |
| The template changed only the executable bit | Applies it to the project's file |
| The file, or a directory above it, is a symbolic link in the project | Reports it and writes nothing |

The script records the template commit the project now has in
`.agents/template.conf` and prints the next steps: resolve conflicts, run
`./scripts/verify.sh --all`, commit, and open a pull request. It never commits
or pushes, and exits 1 when it left a conflict. Running it again when nothing
changed in the template reports that the project is up to date.

A project that has no recorded version yet, because it was created before
this script existed or has never been synced, gets one on the first run: the
script uses the template commit that has the most files identical to the
project's, and says which one. When several versions match equally well and
differ in template files, it does not guess, because the newest would skip a
template change to a file the project changed too: it lists them and asks for
`--from <commit>`, where the oldest is the safe choice. A project that is
already up to date only gets its version recorded. `--to <ref>` selects
another template version than its default branch, and
`--template <url-or-path>` another location, for example a fork; that location
is recorded, so the next sync continues from it.

A template change can need a decision in the project, such as a new check or
a changed step. Read the listed commits before merging the result; the sync
only takes over files.

## Lifecycle

The complete lifecycle, with diagrams and a reference table per step, is in
`docs/workflow.md`.
