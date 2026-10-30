---
title: "Getting started"
description: "Create your repository and take your first feature from idea to pull request."
order: 1
---

## What you need

- Git and Bash
- The [GitHub CLI](https://cli.github.com/), signed in to your account
- `jq` 1.6 or later
- As shipped you need Claude Code and Codex: Claude implements, Codex reviews. A feature review needs a second provider; `review-feature.sh` refuses a reviewer of the implementer’s provider.

## Sign in

Sign in to GitHub once with `gh auth login`. Each coding agent signs in through its own command-line tool. The workflow reads no tokens: do not put API keys or tokens in a file of the repository.

## 1. Create your repository

[Create a repository from the template](https://github.com/taspinar/agentic-coding-template/generate) and clone it. Then delete `documentation/` and `.github/workflows/pages.yml`: they are this website, not part of your project. Keep, replace, or remove `LICENSE`, the MIT licence of the template, for your own project.

Then set up GitHub. The scripts point out risky changes, but only GitHub can enforce who merges:

- Add a ruleset for `main` that requires a pull request and the CI check.
- Replace the placeholder `@YOUR_GITHUB_USERNAME` in `.github/CODEOWNERS` with your account.

The [repository setup guide](https://github.com/taspinar/agentic-coding-template/blob/main/docs/repository-setup.md) has every setting; <a href="../github-setup/#github">GitHub setup</a> explains why they matter.

## 2. Check your setup

```
./scripts/doctor.sh
```

The script checks that the tools above are installed and that the agents you configured can run. It also checks that Git has a commit identity (`user.name` and `user.email`) and that you can push with it, and, when Codex has a role that writes, that a Codex session can write the working files of the workflow under `.agents/`. It tells you what is missing.

## 3. Choose your agents

Each role in the workflow has an agent and a model. Set them in `.agents/agents.conf`, one role per line:

```
implementer: claude opus
implementer@high: claude fable
reviewer: codex gpt-6-luna
```

This is what the template ships: Claude implements, with a stronger model for a high-risk feature, and Codex reviews. A line with `@high` (or `@low`, `@medium`) applies to features of that <a href="../risk-policy/#risk">risk level</a>, and the plain line to the others. The file lists every role, including the planner and the planning reviewer; <a href="../agent-roles/#roles">Agent roles and models</a> explains each one. The reviewer must use a different agent than the implementer, at every level.

## 4. Plan your project

Write a short description of what you want to build, and start the planning with it:

```
./scripts/start-planning.sh --description path/to/idea.md
```

An agent asks you questions and writes the requirements for your approval. It then proposes an architecture and a roadmap in a planning worktree: a separate folder next to your repository, whose path the script prints. Go to that folder, then review the plan, address the findings, and approve it:

```
cd ../<repository>-planning-project-bootstrap
./scripts/review-planning.sh
./scripts/revise-planning.sh --review <review>
./scripts/finish-planning.sh
```

Each script ends by telling you the next command. Merge the planning pull request when you are done, then return to your repository and update it:

```
cd ../<repository>
git pull
```

## 5. Build your first feature

From your repository, on the updated `main`, create the issue of the first roadmap feature. Then let one command take it to a pull request:

```
./scripts/create-feature-issue.sh F01
./scripts/run-feature.sh <issue>
```

The run implements the feature, runs your checks, has it reviewed, fixes what the review finds, and opens a pull request. It does not merge. Read the pull request and the decisions about the review findings, then merge it yourself.

To stay closer to the work, run the steps one at a time, starting with `./scripts/start-feature.sh <issue>`. <a href="../detailed-workflow/">The workflow</a> explains each step.

For a complete sample project, read the [worked example](https://github.com/taspinar/agentic-coding-template/blob/main/docs/example.md).
