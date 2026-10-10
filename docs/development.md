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

Any later change to a planning document invalidates the approval:

```bash
./scripts/finish-planning.sh --check
```

exits 0 when the approval still matches the documents and 1 when it is missing
or stale. `create-feature-issue.sh <feature-id>` refuses to create a feature
Issue from a roadmap without a current approval, so a roadmap change after the
planning PR needs a new review round and approval.

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

Every change to a planning document invalidates the planning approval until
the new one is merged. In between, `create-feature-issue.sh` creates no new
Issue. A feature that is already in progress is not affected.

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
most four words joined by hyphens. The script fetches the selected remote base,
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
makes it stale. `triage-review.sh` and `apply-triage.sh` refuse a stale review
before they start an agent. After `apply-triage.sh` changes the code, the
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
changes, verifies the result with `./scripts/verify.sh --reuse`, and checks the
latest review of the
feature: it must be current and have no critical or major finding. Every
review round with findings needs an approved triage that was published on the
Issue (the newest triage of that round counts), and the latest round may have
no `FIX_NOW` findings left to apply. After fixes, run a new review round first;
a passed newer round confirms the fixes of earlier rounds. A failed
publication can be repeated with `./scripts/triage-review.sh --publish
<triage-json>`.

It then stages all changes (review and triage files are ignored) and opens a
structured commit message in your editor: the summary, the Issue, the list of
changes, the verification, the review round and verdict, and `Refs #12`.
Emptying the message aborts the commit and leaves the changes staged. The
script never pushes, opens a PR, or merges.

The list of changes comes from `.agents/summaries/<issue>.md`, which the
implementer writes and keeps up to date when fixes change what the feature
does: every line that starts with `- ` is taken over. Like the manual steps
it is a working file and is not committed. Without it the message has a line
for you to fill in.

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
works after a squash merge. It refuses an unmerged worktree, a branch with
commits after its merged pull request, and a worktree with uncommitted changes;
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
| `triage-review.sh <review-json>` | The proposed triage is approved without a question. The proposal is validated as always: a critical or major finding cannot be deferred or accepted. |
| `apply-triage.sh <triage-json>` | The fixes start without confirmation, with the `unattended` profile. The final message is stored in `.agents/run/<issue>-fixes.md` and shown. |
| `finish-feature.sh <issue> "<summary>"` | The commit message is used as it is, without an editor. Without a summary of the changes, the message says that the implementer supplied none. |

`review-feature.sh` and `publish-feature.sh` ask nothing as they are. The
planning is yours to decide: its steps refuse the option.

The option needs the working files to be ignored by Git, as the template's
`.gitignore` does with `.agents/run/` and `.agents/summaries/`; a step stops
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
result itself, and a verification that really fails stops the run there, with
status 1 and the failing checks. Common causes on your side are a tool that
is not in the `PATH` of the terminal you started from, and a verification
that takes longer than one command of an agent session may.

A triage that was approved this way says so: the artifact has
`"unattended": true`, and the report and the comment on the Issue state that
no human approved the decisions. Deferred findings still become follow-up
Issues, and accepted findings keep their rationale, so you can read
afterwards what was decided without you.

The files in `.agents/run/` are working files, ignored by Git. A Codex
session also writes its complete output to a file next to its final message,
with `.log` added to the name; it is shown when the session fails.

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
   and the implementation.
2. `review-feature.sh`, and for a review with findings `triage-review.sh
   --unattended` and, when the triage has `FIX_NOW` findings,
   `apply-triage.sh --unattended`, followed by the next review round. This
   repeats until a review has no findings or its triage has nothing to fix.
3. `finish-feature.sh --unattended`, with the title of the Issue as the
   summary of the commit, and `publish-feature.sh`.

It uses at most five review rounds. The first round reviews the complete
feature; a later round reviews only what changed since the round before it
(`review-feature.sh --changes`). That review knows what was decided about
the earlier findings, so a finding that was deferred or accepted is not
reported, triaged, and turned into a follow-up Issue again in every round.
When the base of the branch changed between two rounds, for example because
you merged `main` into it while the run was stopped, the next round reviews
the complete feature.
The agents and models are those of the roles in `.agents/agents.conf`.

What stays with you: choosing the feature and creating its Issue, reading the
pull request, following its checks, merging, and `cleanup-worktree.sh`. The
run never merges, never pushes to `main`, and never removes a worktree.

The run stops with a non-zero status, and keeps the worktree, when:

| Stop | Status |
|---|---|
| An agent needs a decision of yours, or reports a conflict with the Issue's scope, the architecture, or an ADR. Its question is in the handoff note | 3 |
| The implementer, the reviewer, the triage, or the fixing agent fails, for example on a usage limit | 1 |
| Verification fails after the implementation or after the fixes | 1 |
| The proposed triage is invalid, for example because it defers a critical or major finding | 1 |
| Five rounds are used and the last one still has a finding that must be fixed | 1 |
| The fixes changed nothing, the commit fails, or the pull request cannot be opened | 1 |

It then says why it stopped and which command resolves it. After that, run
the same command again: `./scripts/run-feature.sh <issue>`. The run reads
where the feature stands from the worktree, so every step that is done is
skipped: a current review is not repeated, a stored triage is not made again,
and a committed feature is only published. The one thing it records itself is
that the implementation was completed, in `.agents/run/<issue>-state`. As long
as that is missing, the next run resumes the implementer, as
`start-feature.sh <issue> --resume` does. The same happens after a fixing
agent stopped for a decision of yours: the implementer reads your answer in
the handoff note and continues, and a review follows. When you completed the
implementation in a session of your own, say so with `--implemented`, and the
run continues with the review. You can also take over by hand at any point:
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
- A part of the feature that no fix touched is reviewed once, in round 1.
  After a large fix you can run a complete review by hand in the worktree,
  `./scripts/review-feature.sh <issue>`, before the run continues.
- Up to five review rounds, each with a triage and a fix session, use the
  usage limits of your agents without a moment at which you can stop them.
- The commit message is not edited: its summary is the title of the Issue
  and its list of changes is what the implementer wrote.

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
| The template added the file | Adds it |
| The template removed the file | Reports it; the project decides whether to delete it |
| The template changed a file the project deleted | Reports it and leaves it out |
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
