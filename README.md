# Agentic Coding Template

A GitHub template for building software with AI coding agents. It provides a
repeatable workflow for planning projects, implementing features, checking the
results, and reviewing changes before they are merged.

**Documentation:** <https://taspinar.github.io/agentic-coding-template/>

## How it works

1. **Plan.** An agent questions you about the idea and writes the
   requirements; you approve them. It then proposes an architecture and a
   roadmap, an independent agent reviews the plan, and you approve it.
2. **Build.** An agent implements one roadmap feature in its own Git branch
   and worktree.
3. **Verify and review.** One command runs the project's checks. An
   independent, read-only agent reviews the change, and every finding gets a
   recorded decision.
4. **Deliver.** A pull request is opened with the recorded verification and
   review. Merging it is your decision.

## What you get

- Roles for planning, implementing, and reviewing, each with the agent
  (Claude Code or Codex) and the model you choose.
- An independent review of every plan and every feature, by an agent that
  cannot edit files.
- Each feature in its own Git branch and worktree. A worktree separates
  working files; it is not a sandbox for databases or services.
- One command for the project's checks, with a result that is recorded for
  the version it was run on.
- An unattended run that takes a feature to an open pull request and stops
  there.
- A check that flags changes which need the owner's approval. Enforcing
  approvals takes GitHub rulesets and permissions, which you configure
  yourself.

## Quickstart

You need Git, Bash, the GitHub CLI, `jq`, and at least one supported coding
agent.

```bash
# In a repository created from this template:
./scripts/doctor.sh                                   # check your setup
./scripts/start-planning.sh --description idea.md     # plan the project
# review, revise, approve, and merge the plan; then:
./scripts/create-feature-issue.sh F01
./scripts/run-feature.sh <issue>                      # to an open pull request
```

Before the first run, set the agent and model of each role in
`.agents/agents.conf`, configure GitHub with
[docs/repository-setup.md](docs/repository-setup.md), and delete
`documentation/` and `.github/workflows/pages.yml`: they are the website of
the template itself.

## Where to read more

| You want to | Read |
|---|---|
| Understand the workflow, with a diagram | [The documentation site](https://taspinar.github.io/agentic-coding-template/) |
| Set up GitHub for a new project | [docs/repository-setup.md](docs/repository-setup.md) |
| Look up a command or an option | [docs/development.md](docs/development.md) |
| See every step, artifact, and approval | [docs/workflow.md](docs/workflow.md) |
| Follow a complete example | [docs/example.md](docs/example.md) |
| Find what a file is for | [docs/project-map.md](docs/project-map.md) |
| Keep an existing project up to date | "Taking over template changes" in [docs/development.md](docs/development.md) |

The rules for agents are in `AGENTS.md`; their boundaries are in
`.agents/policies/`.
