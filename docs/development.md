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

Agents run with one of two permission profiles. The profile follows from the
role, not from the provider or model configured for it: a reviewing role is
always read-only, a writing role always gets `write`.

- `write`: an interactive session that may modify its worktree and use the
  network, for example to install dependencies and run builds. Anything beyond
  that needs your permission. Claude accepts edits automatically and asks you
  before it runs a shell command. Codex works without asking inside a
  workspace-write sandbox with network access and asks you when a command
  needs to leave that sandbox, for example to write outside the worktree;
  Codex has no setting that asks per command without a sandbox. Used for
  planning, implementation, and applying triage.
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
```

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
```

The slug names the branch and the worktree. Without one, the script derives it
from the Issue title: the title without its feature ID, in lowercase, as at
most four words joined by hyphens. The script fetches the selected remote base,
creates `feature/<issue>-<slug>` in a sibling worktree, and starts the agent
of role `implementer` inside that worktree. Untracked files in the checkout do
not matter; modified tracked files do, because they would not be part of the
new worktree. After the session it prints the worktree path and the next
commands.

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

After the implementation agent exits, enter the feature worktree and verify:

```bash
cd ../project-12-player-movement
./scripts/verify.sh
```

When independent review is required by `.agents/policies/autonomy.md`, run it
before committing so the reviewer includes the complete working-tree changes:

```bash
./scripts/review-feature.sh 12
```

The full interface is:

```text
./scripts/review-feature.sh <issue> [base-branch] [--agent <agent>] [--model <model>]
```

It uses role `reviewer` with the `read-only` profile. The review is
non-interactive: the reviewer cannot modify files and has no network access, so
the script supplies the GitHub Issue and the complete diff against the base
branch, including uncommitted and untracked changes. The reviewer returns its
result as JSON and the script validates and stores it. An invalid result is
retried once and then rejected, and a reviewer that changed the working tree or
created a commit is reported as an error; in both cases no review is stored.

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
runs `./scripts/verify.sh`.

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
review is stale by design: run a new review when the fixes need confirmation.

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
changes, runs `./scripts/verify.sh`, and checks the latest review of the
feature: it must be current and have no critical or major finding. Every
review round with findings needs an approved triage that was published on the
Issue (the newest triage of that round counts), and the latest round may have
no `FIX_NOW` findings left to apply. After fixes, run a new review round first;
a passed newer round confirms the fixes of earlier rounds. A failed
publication can be repeated with `./scripts/triage-review.sh --publish
<triage-json>`.

It then stages all changes (review and triage files are ignored) and opens a
structured commit message in your editor: the summary, the Issue, a list of
changes to fill in, the verification, the review round and verdict, and
`Refs #12`. Emptying the message aborts the commit and leaves the changes
staged. The script never pushes, opens a PR, or merges.

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

The script pushes the branch, opens a pull request whose description is the
commit message, the manual steps, and `Closes #12`, and waits for its checks.
For a pull request that is already open it pushes and replaces the
description with the current one, since a fix round can change the manual
steps. It never merges. It ends with the result:

- all checks passed: the pull request is ready for you to merge;
- a check failed: it exits non-zero and tells you not to merge. Fix the cause
  in the worktree, then review, finish, and publish again;
- no checks were reported: the repository has no CI for pull requests, and the
  script says that nothing verified the change on GitHub.

`--no-wait` stops after the pull request is open. Local verification during a
feature never runs on a clean checkout, and may run on another operating
system than CI, so a failure can appear in CI only; wait for it before
merging. A ruleset that requires the CI status check on `main` makes GitHub
refuse a merge while a check fails; `./scripts/doctor.sh` warns when `main`
has no such rule.

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

## Linking a feature plan

To add or update the plan reference in an existing Issue:

```bash
./scripts/update-issue-with-plan.sh 12 .agents/plans/12-player-movement.md
```

The helper manages one delimited plan block in the Issue body. Re-running it
updates that block instead of appending duplicates. It stores only the
repository-relative plan path; the detailed plan remains in `.agents/plans/`.

## Lifecycle

The complete lifecycle, with diagrams and a reference table per step, is in
`docs/workflow.md`.
