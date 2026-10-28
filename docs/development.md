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
prerequisite is missing, and never modifies anything of the project. A missing
agent CLI fails when `.agents/agents.conf` assigns it to a role and is a
warning otherwise. It fails when Git has no commit identity (`user.name` and
`user.email`, at any configuration level), with the two `git config` commands
that set one: without it `finish-feature.sh` fails at the commit, after the
implementation, the review, and the triage are done. When a role with write
access (`project-grill`, `project-planner`, `implementer`,
`triage-implementer`, also by a level line) uses Codex, it runs one short
real `codex exec` session in a scratch repository under your temporary
directory, with agent.sh's unattended profile, and reports as `FAILED`, with
its path, a runtime directory under `.agents/` that the session cannot write
(see "Codex and `.agents/`" under "Configuring agents"); the check never
prompts, a session that does not end is stopped after `DOCTOR_CODEX_TIMEOUT`
seconds (180 by default), and it is skipped with a warning when Codex is not
installed, not logged in, or the script itself runs inside a Codex session.
It also warns when a pull request into `main` can be merged while its checks
fail, because no ruleset or branch protection requires a status check; see
`docs/repository-setup.md`.

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
passed, nothing is written into the record of a run it was started in, and
`--reuse` is refused, so `review-feature.sh` and `finish-feature.sh` still run
every check. The one place the workflow uses a partial run is an intermediate
review round of a `high` feature whose risk policy names groups for it
(`review-feature.sh --checks`, see "What each level requires"): that review
records the content as partially checked, and the commit still needs the full
verification. A failing partial run removes an
existing record, like any failing run. The workflow self-tests keep their own
rule with `--only`: they run when a workflow file changed, or with `--all`.

### Budgets

A check may be a budget: it measures something against a target (the time of
a test suite, the size of a bundle, the number of warnings) and exits non-zero
over the target. The word `budget` stands before the colon, after the name or
the group:

```text
suite-time [code] budget: ./scripts/measure-suite.sh --max-seconds 300
bundle-size budget: ./scripts/bundle-size.sh --max 250k
```

A budget is a measurement, never a failure and never a repair order:

- `verify.sh` runs it like any check and keeps its output. Over the target
  the summary shows `BUDGET <name> (exit <status>)` with the output of the
  check under it, not `FAIL`, and the verification passes when every other
  check passed: the exit status is 0. Within the target the summary shows
  `PASS <name> (budget within its target)`.
- A budget check that does not finish or cannot run measured nothing: a death
  by a signal, the exit status 124 of `timeout`, and the statuses 125 to 127
  (an error of `timeout` itself, a command that is not executable or not
  found) are a `FAIL` as for any check, and so is a missing tool. The exit
  statuses 1 to 123 and 128 mean "over the target": 128 is not reserved by
  `timeout` or the shell, so a measurement may use it. Wrap a measurement
  that may hang in `timeout`.
- The results are recorded with the pass, in `.agents/verification/budgets`
  next to the record (see "Recorded verification"), and in the run record
  (the `verification` event, `budgets`), so the scripts that reuse the pass
  show the measurement where a decision is made: `review-feature.sh` gives it
  to the reviewer ("Budget results of the verification") with the whole
  output of each check, `finish-feature.sh` lists it under `Verification:`
  in the commit message, which `publish-feature.sh` copies into the pull
  request, with the last 20 lines of the output and, when lines were left
  out, where the whole output is (the budget record, the handoff note, the
  run record), and `run-feature.sh` writes an exceeded budget with its whole
  output to the handoff note and its first line to the log of the feature
  (see "Running a feature with one command").
- Nothing repairs it. `run-feature.sh` starts no repair session for a budget
  result; the result changes neither the scope of the feature nor the
  architecture, needs no ADR, and opens no Issue by itself. The reviewer may
  raise it as a finding, which is triaged like any finding. The completion
  record may not cite a budget check as evidence of a met criterion: the
  completion gate refuses such a record.
- Changing a budget stays cheap and visible. The target lives in the line of
  the check in `scripts/verify.conf`, or in a file that line reads. Changing
  the line is a change of the verification configuration, protected by the
  merge approval gate like every changed line there, and so is making a check
  a budget or a budget a check; adding a budget check is sensitive, like
  adding any check. Record the measurement and the decision in the commit
  message of that change, and in a comment of the configuration when the
  reason is not obvious; budgets add no approval step of their own.
- The execution limits that the project approved
  (`.agents/policies/execution-limits.md`) are not budgets and stay
  enforceable as they are.

The template ships no budget check. A partial run (`--only`) runs the budget
checks of its groups and shows them the same way; it records nothing, as
before.

### Recorded verification

A run in which every check passed is recorded in `.agents/verification/passed`,
a working file that Git ignores, together with the fingerprint of the content
it verified. Any change to a file that Git does not ignore makes the record
stale, and a failing run removes it. The results of the budget checks of that
run, with the output of each, are kept next to it in
`.agents/verification/budgets`, and go with the record: a reused pass shows
them, and a failing run removes them.

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
the role whose work it reviews: `review-feature.sh` refuses to start a
reviewer that resolves to the implementer's provider (see "Per risk level").

Every workflow script accepts `--agent <agent>` and `--model <model>` to
override the configuration for one run. Overriding the provider requires a
model as well. The model is always passed to the provider, for Claude as well
as Codex, and is never replaced: an unknown provider, missing CLI, missing
model, or malformed configuration fails before the script creates a branch,
worktree, or file, and a model the provider rejects fails the run.

**Per risk level.** A role of a feature (`implementer`, `reviewer`, `triage`,
`triage-implementer`) may have a line per risk level of the feature ("The
risk level of a feature" below) next to its plain line:

```text
implementer: claude sonnet
implementer@high: claude fable
```

When a script starts such a role it takes, in this order: `--agent` and
`--model` on the command line; the line of the role and the effective level of
the feature; the plain line of the role. Without a level line the plain line
applies, so a configuration without one behaves as before ("The shipped
configuration" below says which lines the template ships). The level is the
effective level as `check-risk.sh` computes it at the
moment the role starts, raised to the highest level that the run records of
the feature hold: the level can rise during a feature, so a later session may
use a stronger model, never a weaker one than a session that already ran at a
higher level. `start-feature.sh` starts a new feature at the default of the
risk policy of its base, since the feature has no changes yet, and a resumed
session at the level of the changes in the worktree. A level that cannot be
determined is `high`. The script prints the level, why, and which line
selected the agent; the run record notes both for every agent call (`level`,
and `selection`: `command-line`, `level-line`, or `plain-line`), and
`report-runs.sh` shows the calls, the time, and the tokens per level, model,
and selection ("Per risk level"). A model that cannot be invoked stops the
step, as for a plain line; nothing falls back to another model. In a project
that keeps no run records (see "Run records"), the level is computed anew at
every session.

`doctor.sh` validates the level lines like the plain ones: an unknown level, a
duplicate, a malformed line, an unsupported provider, or an invalid model is
reported with its line, on any line of the file, also one of a role that the
script does not start; a CLI that only a level line needs is required; and
every script refuses such a file before it resolves a role. It also warns
when a reviewing role and the role whose work it reviews resolve to the same
provider, for the plain lines and for every level that either side has a
line for, and when a role that never runs with a level (the planning roles
and the analyst) has a level line. The reviewer's independence is enforced
where the reviewer starts: `review-feature.sh` takes the implementer's
provider from the run records of the feature ("Run records"), which hold
every session of the implementer with the provider it ran with, also a
session that `--agent` on the command line gave another provider than the
configuration (each run counted once: from its run file while it exists,
from the copy of the feature otherwise), and refuses, before it calls any
agent, a reviewer that resolves to a provider the implementer ran with.
Without a recorded session
(a project that keeps no run records, or work done by hand) it resolves the
implementer's provider for the same level (`implementer@<level>`, or the
plain line) and refuses a reviewer that resolves to that provider. `--agent`
and `--model` on the command line can make the pair differ for one run, but
never make the reviewer equal to a provider that implemented: an implementer
that ran with both providers leaves no independent reviewer.

**The shipped configuration.** The template's own `.agents/agents.conf`
gives the writing roles of a feature to Claude at every level, `claude opus`
for a low- and a medium-risk feature and `claude fable` at high
(`implementer@high`, `triage-implementer@high`), the review to Codex at every
level (`reviewer: codex gpt-6-luna`, with no level line, since the pair
differs at every level), and the triage to `claude sonnet`, which judges the
review of the other provider. The planning roles and the analyst have plain
lines. The levels come from the features that built the template: a feature
that changes the workflow and its gate, which the risk policy classes as
high, converged in one or two rounds with the strongest model where a weaker
one needed many, while the other features did not need it. The models are
the template's choices; a project sets the models, the levels, and the
providers it wants, and Codex remains supported as implementer and
triage-implementer for a project that configures it ("Codex and `.agents/`"
below). `tests/agent-levels-test.sh` checks a copy of the shipped file: what
each level resolves to, and that `doctor.sh` accepts it without a
same-provider warning. With no writing role on Codex, `doctor.sh` and
`tests/agent-sandbox-test.sh` have no Codex sandbox to check and skip that
check; they run it again as soon as a line gives Codex write access.

`AGENT_CONFIG_FILE` selects another configuration file for a run, for the
workflow scripts and `doctor.sh`; `ATTRIBUTION_CONFIG_FILE` does the same for
the attribution preference (see "Configuring attribution"). Neither reaches
the checks of `verify.sh`: `verify.sh` unsets both for every check, and the
workflow self-tests that assume the repository's own `.agents/agents.conf`
unset them themselves, so they give the same result when you start one by
hand. `tests/agent-test.sh`, `tests/agent-levels-test.sh`, and
`tests/doctor-test.sh` set them on purpose.
Other variables, such as `CLAUDE*`, are not changed.

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

**Codex and `.agents/`.** Codex 0.164 and later mount `.agents/`, `.git/`, and
`.codex/` read-only in the workspace-write sandbox, also inside the worktree
that the session may write otherwise. The implementer and the
triage-implementer have to write five directories under `.agents/`
(`.agents/prompts/implementer.md`, `.agents/prompts/triage-implementer.md`):
the completion record, the handoff note, the summary, the manual steps, and
the experience notes. A Codex session of the `write` and of the `unattended`
profile therefore gets exactly these opened as writable roots of its sandbox
(`-c sandbox_workspace_write.writable_roots=[...]`, built from the worktree):

- `.agents/completion/`
- `.agents/handoffs/`
- `.agents/summaries/`
- `.agents/manual-steps/`
- `.agents/experience/`

All five are ignored by Git. `agent.sh` creates them before the session
starts, because the sandbox refuses a writable root that does not exist (every
command of the session then fails) and the session cannot create a directory
inside the read-only `.agents/` itself. Nothing else under `.agents/` is
opened: the policies, the prompts, the schemas, the plans, the reviews, the
triage, `.agents/run/`, `.agents/verification/`, and `agents.conf` stay
read-only for the agent, as do `.git/` and `.codex/`; a read-only session and
a Claude session get no such roots. A `./scripts/verify.sh` that the agent
runs inside the sandbox therefore cannot record its pass
(`.agents/verification/`) or its run record (`.agents/run/records/` of the
primary checkout): both are warnings of the scripts, the verification itself
passes or fails as always, and the step that follows the session verifies
the result again. `tests/agent-sandbox-test.sh` checks the grant with the
real Codex CLI, when it is installed and logged in, and `doctor.sh` checks
the Codex of your host the same way (see "Prerequisites").

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

## Configuring attribution

Coding agents name themselves in what they commit: Claude Code adds a
`Co-Authored-By` trailer to a commit and a "Generated with Claude Code" line
to a pull request description, Cursor a trailer of its own. Whether this
project wants that is one setting in `.agents/attribution.conf`:

```text
agent-attribution: allowed
```

- `allowed`: agents attribute their work as their clients do, and nothing is
  checked. The template ships this value, and a project without the file
  behaves the same: it is what every project did before the setting existed,
  so taking over the template changes nothing until you select `disabled`.
- `disabled`: no commit of a feature and no pull request description may name
  an agent. Three things follow it:
  - **The instructions.** `AGENTS.md` tells every agent to add no agent
    trailer and no "Generated with" line to a commit message, a pull request
    description, or a summary the scripts copy into them.
  - **The client settings, as far as a client has them.** A Claude session
    that the scripts start in the `write` or `unattended` profile gets
    `--settings '{"attribution": {"commit": "", "pr": "", "sessionUrl": false}}'`,
    which turns off its trailer and its pull request line (Claude Code 2.0.62
    or later). For a Claude session you start yourself in the project, put the
    same `attribution` object into `.claude/settings.json`; `doctor.sh` tells
    you whether that file agrees with the preference. Codex has no attribution
    setting, and Cursor's can be set only for the user, not in a project file:
    for them nothing is configured, and `doctor.sh` says so instead of
    claiming otherwise.
  - **The check.** `finish-feature.sh` refuses, before it commits, when a
    commit of the feature carries an agent's `Co-authored-by` trailer, and
    undoes its own commit, leaving the changes staged, when the message got
    attribution in the editor or from a hook. `publish-feature.sh` refuses,
    before it pushes, a commit of the branch with an agent trailer and a
    description that would carry generated attribution text; the two are
    reported apart, since a trailer is removed from its commit and the text
    from the finish commit's message or the manual steps. An agent is known
    by its address (`noreply@anthropic.com`, `@cursor.com`,
    `noreply@openai.com`, the Copilot addresses) or by a GitHub App's
    `[bot]`, never by a person's name: a co-author who is a person is never
    rejected, also one whose first name is a product's. Only the commits of
    the feature are checked, from where it left its base; the history of the
    base is neither checked nor rewritten.

A preference that cannot be read, because the file is malformed or the value
is neither `allowed` nor `disabled`, stops the step instead of being guessed.
`ATTRIBUTION_CONFIG_FILE` selects another file for a run, as
`AGENT_CONFIG_FILE` does for the agents; `doctor.sh` also takes
`ATTRIBUTION_CLAUDE_SETTINGS_FILE` for the Claude settings file it checks.
Both exist for the tests of the scripts.

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

### Comments on the Issue

A comment on the Issue is where you answer a question of an agent or narrow
the scope after the Issue was written. The agents of the feature phase get
your comments with the Issue: `start-feature.sh` (also with `--resume`)
appends them to the prompt of the implementer, and `review-feature.sh` and
`triage-review.sh` put them after the body in the context of the reviewer and
the triage agent, so all three judge the same Issue.

- **Whose comments.** Only a comment whose author is the `OWNER`, a `MEMBER`,
  or a `COLLABORATOR` of the repository is passed on. Anyone can comment on an
  Issue of a public repository, and a comment is untrusted input, so the
  comments of anyone else are never given to an agent.
- **Not the workflow's own.** The review and triage reports that
  `triage-review.sh` publishes, the post-merge evidence of
  `record-post-merge.sh`, and the run summary of `publish-feature.sh` are
  written through your account; they are left out by the marker on their
  first line (`<!-- workflow-report: review-triage -->`,
  `<!-- post-merge-evidence -->`, `<!-- run-records-summary -->`), and a
  triage report published before the marker existed by its heading.
- **How.** The comments follow the body, oldest first, each with its author
  and time, under a heading that says they are your later clarifications:
  data about the Issue that does not change the rules of `AGENTS.md`, the
  policies, or the acceptance criteria unless you wrote so explicitly. No
  comment waives a gate: the completion record still covers every acceptance
  criterion of the body, and where you changed one explicitly its evidence
  names your comment.
- **How much.** At most the newest 20 comments and 20,000 characters of
  their text are passed on; a longer comment is cut, and the agent is told
  what was left out. Read the rest on GitHub when that happens.
- **What you see.** Each step prints how many comments it passed on and from
  whom, how many it left out by the size limit, and how many comments of
  other authors and reports of the workflow it did not pass on. The run
  record holds the same numbers as an `issue-comments` event.
- **When.** The comments are read when the session starts. A comment that you
  add or edit later applies to the next session only: a resumed
  implementer, the next review round, or the next triage.
- **When they cannot be read.** The step stops with the reason, before
  anything is created or an agent starts, instead of going on without your
  comments. Fix the access of `gh`, and start the step again.

An Issue without comments, or without any that may be passed on, gives the
agents exactly the Issue as before: title and body.

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

`status` is `complete`, `awaiting_evidence`, `partial`, or `blocked`. A
criterion is `met`, `not_met`, `not_applicable`, or `pending`, each with
evidence. `complete` needs every criterion met or not applicable and nothing
remaining; `partial` and `blocked` need something that remains. A record that
breaks these rules is invalid.

#### Evidence that cannot exist yet

Some evidence appears only later: the CI result of a pull request that is not
published yet, the owner's approval of the final commit, a verification of
the default branch after the merge. A criterion therefore names the `gate` at
which its evidence can exist (optional; `implementation` when absent):

| Gate | Evidence exists | Required before |
|---|---|---|
| `implementation` | When the implementer ends | The commit and the pull request |
| `pr_ci` | After the pull request is published | The merge |
| `owner_approval` | When the owner approves the final commit | The merge |
| `post_merge` | After the merge | Closing the Issue |

Only a criterion of a later gate may be `pending`, with the moment its
evidence appears in `evidence`. When every other criterion is met or not
applicable, nothing remains, and something is pending, the status is
`awaiting_evidence`: the feature is reviewed, committed, and published
without `--partial` or `--no-review`, and the reviewer does not report the
pending evidence as a defect. It reports a criterion that is pending although
its evidence could exist now. `complete` keeps its meaning: every required
criterion is satisfied. A not met criterion of the implementation gate cannot
be hidden as pending, and a pending criterion cannot be in a `complete`
record.

Pending `pr_ci` and `owner_approval` evidence is not recorded anywhere by the
scripts: CI and the merge approval gate on the pull request already hold the
merge until it exists, and they are not weakened. A criterion that the record
leaves pending at the `owner_approval` gate also makes `finish-feature.sh`
state that the merge needs the owner's approval, whatever the diff and the
review say: a record can require the owner's approval, never grant it. The pull request of a
feature that awaits only these closes the Issue as usual. A feature that
awaits `post_merge` evidence is published as ready for review, but without
a closing keyword: the commit text refers to the Issue with `Refs`, and the
description says that the Issue stays open and lists the pending criteria. After the merge, record each one with

```bash
./scripts/record-post-merge.sh <issue> "<criterion>" "<evidence>"
```

which posts the criterion and its evidence as a comment on the Issue and
closes the Issue when no `post_merge` criterion is left. The criterion must
be given exactly as the pull request lists it: the finish commit holds one
line `Post-merge criterion: "<criterion as a JSON string>"` per pending
`post_merge` criterion, and the script matches those strings exactly, so a
criterion that begins like another, or holds parentheses or quotes, never
stands for it. `publish-feature.sh` publishes a feature as ready only when
the pending `post_merge` and `owner_approval` lines of the finish commit
equal those of the record; a record edited after the finish needs a new
`finish-feature.sh`, because the finish decides what the pull request states
and whether the merge needs the owner. No pull request and
no review round is needed; the comments are the audit trail. The script does
not authenticate who gives the evidence: it is an agent-written or owner
comment under the account that runs `gh`, not an independent approval. Owner
approval stays with the merge approval gate and with the work to enforce it on
GitHub with a separate identity (#99).

The gate passes when the record is valid and says `complete` or
`awaiting_evidence`, and the handoff note lists nothing under "Remaining".
The note outweighs the record: remaining work listed there means not complete,
whatever the record says. Two things are never evidence: a partial run of the
checks (`verify.sh --only`), which is not a verification, and a budget check
of `scripts/verify.conf` or `scripts/verify-workflow.conf` (see "Budgets"),
which is a measurement that never fails the verification. A record whose
evidence for a met criterion names such a run, or names a budget check as a
word, is invalid.

| Script | What the gate decides there |
|---|---|
| `start-feature.sh` | After the session it says whether the Issue is complete, and offers the review only then |
| `run-feature.sh` | Goes on to the review only when the gate passes and the summary of the changes exists; otherwise it resumes the implementer with the reasons in the handoff note, at most four sessions in a run. `blocked` stops the run with status 3. The gate is asked again before every later review, because a session that repairs the verification is a session of the implementer too |
| `review-feature.sh` | Gives the record to the reviewer of the complete feature, as a claim to check |
| `finish-feature.sh` | Refuses a missing, invalid, partial, or blocked record. `--partial` commits partial work as your explicit choice, and is refused for a feature that is complete or awaits evidence |
| `publish-feature.sh` | Asks the gate again. The pull request closes the Issue only when the commit says `Completion: complete` (or `awaiting_evidence` with no `post_merge` evidence pending) and the gate still agrees. A feature that awaits `post_merge` evidence is published for review with `Refs`; any other outcome is a draft that refers to the Issue and says why it does not close it |
| `record-post-merge.sh` | After the merge: records the evidence of a pending `post_merge` criterion as an Issue comment, and closes the Issue when none is left |

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
./scripts/review-feature.sh <issue> [base-branch] [--agent <agent>] [--model <model>] [--changes] [--checks <group>[,<group>...]] [--unverified "<reason>"]
```

It uses role `reviewer` with the `read-only` profile, and refuses to start
when the reviewer resolves to a provider the implementer ran with for the
feature, by the run records, or, without a recorded session, to the
implementer's provider for the feature's risk level (see "Configuring
agents"). The review is
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
no triage agent. The triage mode of the project policy for the risk level of
the feature, `full` or `light` (see "What each level requires" and "Light
triage"), is derived by the script itself from the diff and the rules of the
base, shown before the proposal, told to the agent when it is `light`, and
recorded in the artifact; a `high` feature always gets the full triage.

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
verification, the review round and verdict, the merge approval, the risk
level with its reasons (see "The risk level of a feature"), and `Refs #12`.
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

When the project disables agent attribution (`.agents/attribution.conf`,
see "Configuring attribution"), the script refuses a feature whose commits
name an agent as a co-author, and undoes a commit whose message got
attribution in the editor; a co-author who is a person passes.

A change that `.agents/policies/autonomy.md` classifies as low risk may be
finished without an independent review; the reason is recorded in the commit
message. `./scripts/check-risk.sh` tells you the level of the feature by the
rules of `.agents/policies/risk.conf` (see "The risk level of a feature"):

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
the commit message, one line with the triage mode of the project policy for
the risk level of the feature (`Triage mode: full` or `light`, see "What each
level requires"), the manual steps, and `Closes #12`. For a pull request
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

With agent attribution disabled (`.agents/attribution.conf`), the script also
refuses to push while a commit of the branch carries an agent's
`Co-authored-by` trailer, or while the description would carry generated
attribution text such as "Generated with Claude Code"; each is reported
on its own, with where to remove it. See "Configuring attribution".

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
   triage has nothing to fix: a round whose findings were all deferred or
   accepted ends without a fix session, in every triage mode of the policy
   (see "Light triage" under "What each level requires").
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
the complete feature; so does a round after the risk level of the feature
rose, or when the risk policy requires complete reviews for the level. What
the rounds require per level, and the partial checks of the intermediate
rounds of a `high` feature, are described under "What each level requires";
with the policy the template ships, the rounds are as described here.
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
| Budget exceeded | The verification passed, and a budget check (`<name> [<group>] budget: <command>`, see "Budgets") exceeded its target | Goes on: no repair session, whatever the measurement. Writes the measurement to the handoff note, with the note that it is not a repair order, and to the log and the run record, once per result and only where a note cannot make a review stale (before a review round, after the verification of an unreviewed `low` feature, after the commit). The reviewer's context, the commit message, and the pull request get it from the verification record |
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
| Five rounds are used and the last one still has a finding that must be fixed, or was an intermediate round (only the changes, or partially checked content) | 1 |
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
  removed line, which includes a check made a budget, a budget made a check,
  and a changed target (see "Budgets"). An added check is sensitive.

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

**Three things, kept apart.** What was verified and reviewed, what you are
asked to approve, and the approval itself are three different things, and
no file stands in for another:

| Role | What it is | Where |
|---|---|---|
| The content tree | What was verified and reviewed: the Git tree hash of the content without the workflow's metadata under `.agents/` | Computed by `scripts/lib/fingerprint.sh`; printed by `finish-feature.sh` and `publish-feature.sh` next to the commit SHA, and in the commit message under `Merge approval:`; recomputed by `check-guardrails.sh` |
| The approval request | What you are asked to approve, and why: references and an explanation, nothing else | `.agents/approval-requests/<issue>.json`, written by `finish-feature.sh` when the gate requires you, committed with the feature, constrained by `.agents/schemas/approval-request.schema.json` |
| The approval | Your review of the pull request on GitHub, which GitHub binds to the commit | GitHub, and only there |

The content tree is one value: `finish-feature.sh` computes it from the
working tree before the commit, prints it as the content tree next to the
commit SHA, writes it into the request as `content_tree`, and checks after
the commit that the commit holds exactly that content. `publish-feature.sh`
computes it again from the finish commit and puts it into the pull request,
next to the commit SHA, labelled as the content tree. The reviewer gets it in
the review context, and gets the request of the feature, when there is one,
as a section of that context with the content tree it names, like the
completion record and the handoff note: the diff the reviewer sees shows no
change in `.agents/approval-requests/`, neither the feature's own request nor
a request of an earlier feature that the base already has, since the content
fingerprint leaves the directory out. No other fingerprint is printed in the
same statement:
the `reviewed_tree` of a review artifact is a different value, since it also
covers the completion record and the handoff note (see "What does not change
the fingerprint"), and comparing the two was a recurring false finding in
Physics by Construction.

The request asks and records. It grants nothing and changes nothing: no
script reads it for anything but display, and the one check that reads a
field, `check-guardrails.sh`, can only refuse it. The check recomputes the
content tree from the commit it checks, with the exclusion list of
`scripts/lib/fingerprint.sh` and the schema as the base branch has them, and
refuses a request whose `content_tree` differs, that has a field the schema
does not name, or that is not named `<issue>.json`; it exits 4 then, and CI
runs it on every pull request with the script of the base. A merge of the
base into a finished feature is passed over, as `publish-feature.sh` passes
it over: the request names the finish commit. Any other commit after the
finish needs a new finish, which rewrites the request, or removes it when
the gate no longer requires you. The request is never executed and is never
an instruction for an agent, as the prompts of the implementer and the
reviewer say.

The authority of the approval stays with #99: today the request records who
is asked and why, and the approval is bound to the commit by GitHub, not to a
trusted owner identity. Until #99 provides that identity, `finish-feature.sh`
and `publish-feature.sh` require your approval in exactly the cases they
did before, and nothing an agent can write counts as it.

### The risk level of a feature

Every feature has a risk level, `low`, `medium`, or `high`, computed from one
policy: `.agents/policies/risk.conf`. `.agents/policies/autonomy.md` says in
prose what the levels mean and refers to the file as the one source of the
rules. The level is computed, recorded with the feature, and read by the
workflow; the same policy says what each level requires of the review rounds
("What each level requires" below). The shipped policy changes nothing for a
project until it adds its own classes or requirements.

**The policy.** One `<key>: <value> [<value>...]` per line, with Git pathspecs:

```text
default: medium
high: docs/decisions .github/workflows .agents/policies .agents/prompts/reviewer.md ...
tests: tests test
```

| Key | Meaning |
|---|---|
| `low`, `medium`, `high` | The path classes. The highest class of any path the feature changed is its path-based minimum; a path in two classes gets the higher one |
| `default` | The level of a path that no class names |
| `tests` | The test files. A change to an existing one escalates to `high`; without the key, `tests test` |
| `manifests` | The dependency and toolchain manifests. A change to an existing one escalates to `high` |

The template ships the file with `default: medium`, the paths that the merge
approval gate protects as the `high` class (the ADRs, the CI workflows, the
scripts, prompts, schemas, and configuration of the gate, and the two
verification configurations), and no `low` class: with it, every feature is
`medium` or `high`, which is the behaviour of today, and of a project whose
base has no file at all. A project adds its classes. For a web application,
for example:

```text
default: medium
low: docs :(glob)**/*.md
high: src/auth src/permissions db/migrations infra deploy
manifests: package.json package-lock.json pyproject.toml uv.lock Dockerfile
```

Then a documentation-only feature is `low`, a feature that also changes a
module under `src/` is `medium`, and one that touches authentication,
authorization, a migration, the infrastructure, or a dependency file is
`high`.

**The computation.** The effective level is the highest of three sources:

1. the path-based minimum, by the classes and the default of the policy on
   the diff of the feature: from where it left its base, with uncommitted and
   untracked files, as the merge approval gate computes it;
2. the fixed escalations to `high`, which no policy turns off: a changed or
   removed line in `scripts/verify.conf` or `scripts/verify-workflow.conf`;
   a change to an existing test file, which is where shared fixtures, test
   collection, skips, and acceptance thresholds live (a new, standalone test
   file does not escalate by itself); a change to an existing file under
   `.agents/policies/`, `.agents/prompts/`, or `.agents/schemas/`, the policy
   itself among them; and a change to an existing manifest the policy names.
   An escalation reads only changed or removed existing lines and files,
   never their content: a file the feature adds, and the lines of a new file,
   never escalate by themselves, whatever they hold, and a protected path
   keeps its `high` class by the path rule. The template ships no detector of
   content patterns (tolerances, test markers, assertions);
3. what the agents recorded: `"risk": "<level>"` in the implementer's
   completion record, and the reviewer's `architecture_impact`, of which
   `major` and `breaking` count as `high`.

An agent can raise the level, never lower it: a recorded level below the
computed one is ignored and reported, and `finish-feature.sh` refuses a
completion record that claims less than the diff shows. A record without
`risk`, as every record written before the level existed, claims nothing and
is never refused: a feature that was already in progress gets its level
derived, recorded, and shown like any other. The rules are read from the base
branch as it is now, like those of the gate, so a feature that adds its own
paths to `low` is still classified by the base's file, and is `high` because
it changed the policy. When the base of the feature cannot be determined, or
Git cannot enumerate its changes (a failed `git diff`), the level is `high`,
never the default for a feature that changed nothing.

**Where it appears.** Each script derives the level itself, from the diff
and the rules of the base at that moment; a level stored in an artifact is an
input to the maximum, never the source of truth. `review-feature.sh` tells
the reviewer the level and its reasons and stores them in the review artifact
(`risk`). `finish-feature.sh` records them in the commit message, under
`Risk:`. `publish-feature.sh` computes the level again for the pull request
description and names the commit's level when the two differ.
`run-feature.sh` prints the level once the worktree exists and before each
review round, and the run record notes it (`risk` events). The merge approval
gate is unchanged: a `high` level grants nothing, and a protected path keeps
needing your approval.

To ask, in a feature worktree or in CI:

```bash
./scripts/check-risk.sh            # against main
./scripts/check-risk.sh develop    # against another base
```

The first line is `risk: <level>`, then one reason per line, then what the
level requires of the review rounds (`verification: ...`, `review: ...`, and
`refused: ...` for a value of the policy that is not accepted). It exits 0
for `low`, 1 for `medium`, 2 for `high`, and 3 on a usage error, so a CI
step can branch on it.

### What each level requires

The risk policy also says what a level requires of the rounds of
`run-feature.sh`, one `<level>: <kind>: <value>` per line:

| Line | Meaning |
|---|---|
| `<level>: verification: full` | The full verification runs before every review round of a feature of that level |
| `<level>: verification: groups <group> ...` | Before an intermediate round, only the named groups of `scripts/verify.conf` run (`verify.sh --only`, see "Groups of checks"). An intermediate round is a round after the first review that is not the review of the complete feature a feature is committed on: the repair and fix rounds |
| `<level>: review: delta` | A later round may review only the changes since the round before (`review-feature.sh --changes`), when it can build on that round |
| `<level>: review: full` | Every round reviews the complete feature |
| `low: review: none` | A `low` feature is committed without a review. Only `low` may have it; `medium: review: none` and `high: review: none` are refused |
| `<level>: triage: full` | The findings of a review round are triaged as the triage contract says, with nothing added: the triage agent decides `FIX_NOW`, `DEFER`, or `ACCEPT` for every finding |
| `<level>: triage: light` | The light triage of suggestions and minor findings (see "Light triage" below). Only `low` and `medium` may have it; `high: triage: light` is refused, and the full triage applies |

The template ships `verification: full`, `review: delta`, and `triage: full`
for every level, which is exactly what the workflow did before it knew the
levels: the full verification before each round, a review of the changes
when it can build on the round before, a complete review last, and the
triage as the contract says. A level without a line gets the same. Of the
base refs the rules are read from (the local base and `origin/<base>`), the
strictest requirement counts, and a value that is not accepted counts as the
strictest and is reported by `check-risk.sh` and the scripts: `full` before
`groups`, `full` before `delta` before `none`, `full` before `light`.

**Intermediate and final rounds.** In an intermediate round of a level with
`verification: groups`, the fixes are verified with those groups
(`apply-triage.sh --checks`, which also tells the fixing agent to run only
them) and the review of the round starts on them (`review-feature.sh
--checks`); the groups run once after the fixes and once before the review,
since a partial run records nothing that a later step could reuse. A partial
check never counts as a verification, whatever the policy says: `verify.sh
--only` records no pass, the review of that round records
`verification.status: partial` with the groups, the reviewer is told that
the content is partially checked, the completion record cannot cite the run
as evidence (`finish-feature.sh` and the completion gate refuse a record
that does), and `finish-feature.sh` does not commit on such a review. A round on a partial check is an intermediate
round like a review of changes only: when it leaves nothing to fix, the run
goes on to a review of the complete feature on the full verification, and
the commit is made on that one. Before the commit the full verification runs
(`verify.sh --reuse`: a pass that was recorded for identical content is
reused, as before). A `high` feature keeps needing your approval through the
merge approval gate, which this does not touch. `run-feature.sh` names a
round on a partial check in its output (`review on a partial check of the
groups ...`); when the policy names a group that `verify.sh` does not know,
the full verification runs and the log of the run says so.

**Baseline and delta.** The first review is complete. A later round reviews
only the changes (`--changes`) when the policy allows it for the level, the
previous round is valid, the branch has the same base as then and the
content that round reviewed is still known, and the level computed now did
not rise above the level that round recorded. Otherwise the round reviews
the complete feature, and the log of the run says why: the base changed, the
previous review is invalid, or the level rose because the fixes touched a
path of a higher class or an agent raised it (the feature is reclassified by
the rules of "The risk level of a feature"). There is no changed-line
threshold. `run-feature.sh` computes the level again before every round from
the diff and the rules of the base; the level a review stored is at most
an input to the maximum.

**Low without a review.** With `low: review: none` in the policy of the base,
`run-feature.sh` verifies a `low` feature as a step of its own, repairs a
failed verification as it would after a review, and goes on to the commit
without a reviewer; a repair that makes the feature `medium` sends it to the
review after all. `finish-feature.sh` accepts the feature without a review
artifact and records `Review: not reviewed: Low risk by project policy` in
the commit message, which `publish-feature.sh` copies into the pull request.
Without a reviewer nobody classified the impact on the architecture, so the
merge approval gate requires your approval, as it does today for a feature
without a valid classification; CI stays required. A feature that has a
review is committed on it as before. Without the line, a `low` feature is
reviewed like any other.

**Light triage.** In every mode, a round whose triage has no `FIX_NOW`
finding ends the review loop without a fix session: `run-feature.sh` goes on
to the commit when that round reviewed the complete feature on the full
verification, and to the review of the complete feature when it was an
intermediate round; a `FIX_NOW` finding, also a minor one, is fixed and
reviewed again. With `<level>: triage: light` in the policy of the base, for
`low` or `medium`, `triage-review.sh` tells the triage agent that the policy
prefers to defer or accept a suggestion or a minor finding over a fix
session: `FIX_NOW` for such a finding only when it blocks the feature,
otherwise `DEFER` with a follow-up Issue, or `ACCEPT`. The agent still
decides every finding, and nothing is accepted by a script. Critical and
major findings are `FIX_NOW` in every mode, also in an owner-directed
triage; the validation of the decisions is the same. The triage artifact
records the mode (`triage.mode`), the log of the run notes a round that the
light triage ended, and the pull request description names the mode of the
policy (`Triage mode:`); the published triage comment, the follow-up Issues
of the deferred findings, and the commit message are unchanged.
`triage-review.sh` derives the level itself, from the diff and the rules of
the base, and never runs a light triage for a `high` feature, whatever the
review or the completion record says; `check-risk.sh`, `run-feature.sh`, and
`finish-feature.sh` report `high: triage: light` as refused, the full triage
applies, and `finish-feature.sh` refuses to commit on a light triage of a
feature that is `high` when the commit is made. With the shipped `full`,
nothing changes.

The template ships no `low` class. A project that wants one defines it by
paths only, and any escalation wins over the path class. Physics by
Construction, for example, defines its Level 1 as the documentation and
process files outside the ADRs, the planning documents, and `AGENTS.md`:

```text
default: medium
low: docs :(glob)**/*.md :(exclude)docs/decisions :(exclude)docs/roadmap.md :(exclude)docs/PROJECT_REQUIREMENTS.md :(exclude)AGENTS.md
low: review: none
high: scripts/verify.conf scripts/verify-workflow.conf src/verification
high: verification: groups unit lint
```

With that file a feature that changes only such documentation is `low` and
is committed without a review; a `high` feature gets a partial check of the
groups `unit` and `lint` in its repair rounds and the full verification
before its final review and its commit. Whether a partial check pays off
depends on the project: it saved about 55 minutes per repair round in
Physics by Construction, and little in a project whose full run takes a few
minutes, which is why the template ships `full`.

**What does not change the fingerprint.** The content fingerprint that a
verification is recorded for, and that decides whether a review is stale,
leaves out what the workflow writes about the content: the review and triage
artifacts, the record of the last passed verification
(`.agents/verification/`), the run records and the state, logs, and risk
notes of a run (`.agents/run/`, `.agents/records/`), and the approval
requests (`.agents/approval-requests/`). A review therefore cannot be made
stale by the metadata it produces, also in a project whose `.gitignore` does
not name those paths, and an edited explanation of an approval request keeps
the verification and the review valid. The list is fixed and lives in one
place, `scripts/lib/fingerprint.sh`, which the merge approval gate protects;
`check-guardrails.sh` reads it from the base branch, so a feature cannot add
an exclusion for itself. Nothing else is left out: the plans under
`.agents/plans/` stay in, because a plan can change the acceptance criteria,
the review scope, or the risk, and so do the policies, prompts, schemas,
check lists, and manifests. The fingerprint of a feature review covers one
thing more than the content: the implementer's completion record and handoff
note of the Issue, which the reviewer of the complete feature judged too. A
change to either after the review makes the review stale, while the
verification pass stays valid, since a note about the verification does not
change what was verified.

**The rule for what is left out.** The files the content fingerprint
leaves out are of two kinds, and the rule differs:

- *Display-only files*: the approval request. It changes the behavior of no
  script; a script reads it only to display it, and `check-guardrails.sh` can
  only refuse it. The tests change every field of a request and show that no
  script's exit status or output changes but the displayed request
  (`tests/publish-feature-test.sh`, `tests/guardrails-test.sh`,
  `tests/finish-feature-test.sh`). The sentence "a field which affects
  behavior must enter the content fingerprint" applies to display-only files
  and to nothing else: a file that a script would read for more than display
  is not left out as display-only, and the list is not extended for it.
- *Decision artifacts*: the review and triage artifacts. The gates read them,
  and that is their purpose: `finish-feature.sh` reads the verdict, the
  findings, the base, and the scope of the latest review and the decisions,
  the mode, and the publication of every triage. They change behavior only
  for the content tree they name: a review names the content it judged
  (`reviewed_tree`); an artifact whose `reviewed_tree` is not the tree of the
  current content is not current (`check-review.sh`), and a gate acts only on
  a current artifact that passes its schema. A triage must name the reviewed
  tree and the verdict of its review, and is published on the Issue before a
  commit rests on it. So editing a behavior-driving field of a current
  artifact (the verdict, a finding's severity, a triage decision) changes
  what the gate does, and the gate follows the edited artifact; the same
  artifact against other content is refused as not current
  (`tests/finish-feature-test.sh`, cases `gate-review-field` and
  `gate-triage-field`). The artifacts are left out of the content tree so
  that the evidence cannot invalidate what it describes: editing one leaves
  the content tree, the recorded verification, and the currency of the
  latest review unchanged, and the edit shows in the hash of the artifacts
  (`fingerprint_artifacts` in `scripts/lib/fingerprint.sh`), which
  `review-feature.sh`, `triage-review.sh`, `apply-triage.sh`, and
  `analyze-runs.sh` take before they start an agent and compare after, and
  refuse the result of an agent that changed or removed an artifact
  (`tests/fingerprint-test.sh`, `tests/finish-feature-test.sh`). The
  verification record and the run records are left out the same way and
  bound the same way: the record names the tree it passed for, and
  `verify.sh --reuse` reuses it for that tree only.

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
| `agent-start`, `agent-call` | an agent call begins (`id`, `role`, `profile`, `agent`, `model`, and `level` and `selection`: the risk level of the feature that selected the agent, `null` for a planning or an analysis, and where the selection came from, `command-line`, `level-line`, or `plain-line`; see "Configuring agents") and ends (the same, with `status`, `seconds`, `usage`) |
| `verification-start`, `verification` | a verification begins (`id`, `groups`: always `all`, since a partial run with `--only` is not recorded) and ends (with `status`, `seconds`, `reused`: a recorded pass stood in for the run, and `budgets`: the budget checks of the run, each with `name`, `status` `exceeded` or `within`, `exit`, and `output`; an empty list without one, and the recorded results for a reused pass) |
| `step-start`, `step` | a step of `run-feature.sh` begins (`id`, `name`) and ends (with `status` and `seconds`) |
| `wait-start`, `wait` | the pause before a step is tried again: the `planned` seconds, and the `seconds` it really took |
| `intervention` | `what` you did that a script saw: an approval, a resume by hand, `--implemented`, `--partial` |
| `resumed` | the run follows a run of the subject that stopped with `previous_status` other than 0 (`after` is that run); for a feature, `handoff_changed` says whether the handoff note changed after the stop (never its content). Who started the run or changed the note is not known, so this is not an intervention |
| `note` | a line of the log of `run-feature.sh` (`.agents/run/<issue>-log`), which is written from the same event |
| `completion-gate` | one check of the completion gate: `check` (its number in the run), `sessions` (the sessions of the implementer and the triage implementer that the run recorded before it, a repair or a retry too), `session` (the last of them, which the check judges; a check without a new session judges it again), `status`, `reasons`, and `content`, the fingerprint of what it judged |
| `artifact` | a review or a triage that the run wrote: `kind` and `path` |
| `risk` | the risk level of the feature as `run-feature.sh` printed it: `when` (at the start, or before a review round), `level`, and `reasons` |
| `issue-comments` | the comments of the Issue that a step read for its agent: `issue`, `role` (`implementer`, `reviewer`, or `triage agent`), `passed` and the `authors` of the passed comments, `left_out` (by the size limit), `others` (comments of other authors), and `workflow` (the workflow's own reports) |
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

**Self-tests started inside a run.** A run passes its `RECORDS_*` variables to
everything it starts, so a workflow script that an agent starts belongs to the
run. The workflow self-tests do not: every `tests/*-test.sh` sources
`tests/lib-fakes.sh`, which unsets them, as `verify.sh` does for each check,
so a test that an agent starts by hand inside a run writes nothing into that
run's record. A test of the records sets what it needs itself.

Records written before the self-tests did this may contain the fake events of
such tests, under the run's own `run` id. They are recognizable by their
model: `agent-start` and `agent-call` events whose `model` is a fake of the
tests, `model-` followed by a letter or a word (`model-a`, `model-b`,
`model-t`, `model-claude`, `model-codex`), mostly with usage figures `null`.
The same runs hold many `verification-start` and `verification` events within
seconds, and review or triage rounds that the run never had.
`report-runs.sh` counts these events like the others; such records are not
repaired.

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
per role, model, and run, the calls, the time, and the tokens per risk level
of the feature, model, and selection of the agent (for the calls that
recorded a level, see "Configuring agents"), the verification, the steps of
`run-feature.sh`, the recorded interventions, and the versions the runs used.
It reads the run files
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
- **Tokens** that a call did not report are not zero. A call has complete
  figures, partial figures (only some of its turns reported them), or none.
  Partial figures count in the sum, which then says "at least" (and "≥" in
  the GitHub summary) and how many calls are partial and how many have no
  figures; a sum without any figure is "unknown". `--split` leaves features
  with partial or unknown figures out of the means of tokens and says how
  many.
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
model, with how many calls reported complete, partial, or no figures for
each direction. It is off by default, since a repository is often public. It is built
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

Whether the template started to list a file is decided against the files of
the version the project has. When that version predates the `paths:` list,
the script says so and takes the list in the project's
`.agents/template.conf` as the files of that version: a file the template
lists now and the project's list does not is newly owned, with the outcomes
in the table. When the project's list is empty too, the files of that
version are not known and nothing counts as newly owned. When neither the
template now nor the project's `.agents/template.conf` lists files under
`paths:`, the script stops with an error before it changes anything. A list
that matches no file is an empty set: every file the template lists now is
newly owned.

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
