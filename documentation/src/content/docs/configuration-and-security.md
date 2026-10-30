---
title: "Configuration and security"
description: "Permissions, attribution and the changes that need the owner."
order: 2
---

<a id="attribution"></a>

## Agent attribution

Coding agents name themselves in what they commit: Claude Code adds a `Co-Authored-By` trailer to a commit and a "Generated with Claude Code" line to a pull request. Whether your project wants that is one setting in [`.agents/attribution.conf`](https://github.com/taspinar/agentic-coding-template/blob/main/.agents/attribution.conf): `agent-attribution: disabled`, which the template ships so that the work is published under the owner's own name, or `allowed`, which a project selects by changing the line if it wants its agents named. With `disabled`, `AGENTS.md` tells the agents, the Claude sessions the scripts start get the matching setting, and `finish-feature.sh` and `publish-feature.sh` refuse a commit of the feature with an agent's trailer and a description with generated attribution text, each reported on its own. Co-authors who are people are never rejected, and the history of the base is never touched. Codex has no attribution setting and Cursor's is set per user, not per project: `doctor.sh` says so instead of claiming that they are configured.

<a id="profiles"></a>

## What an agent is allowed to do

A script starts an agent with one of three permission profiles:

| Profile | Used for | What the agent can do |
| --- | --- | --- |
| **write** | A step you follow in the terminal, such as implementing a feature | Change files in its worktree and use the network. For anything beyond that it asks you: Claude before it runs a shell command, Codex before a command leaves its sandbox |
| **unattended** | A step that runs without you, such as in `run-feature.sh` | The same reach as write, and it asks nothing. What it would have asked you is decided without you, in a different way per agent: Codex stays inside its sandbox and is refused what leaves it; Claude runs in its automatic permission mode, whose own check allows or denies each action, and anything that would still need a question is denied. It gets none of your personal integrations, such as MCP servers or apps |
| **read-only** | Reviews, triage proposals, and the analysis of runs | Read files. It cannot change them, and it gets none of your personal integrations |

If an agent cannot enforce a profile, the script stops. It never starts the agent with broader permissions instead.

**Codex and `.agents/`:** Codex keeps `.agents/` read-only inside its sandbox. A writing Codex session therefore gets exactly the five working directories it has to write opened for it: `.agents/completion/`, `.agents/handoffs/`, `.agents/summaries/`, `.agents/manual-steps/`, and `.agents/experience/`. The policies, prompts, schemas, reviews, and the agent configuration stay read-only for the agent. When a role with write access uses Codex, `doctor.sh` runs one short Codex session to check that it can write them.

**What this is not:** a profile uses the permission and sandbox settings of the agent's own command-line tool. It is not a container or a virtual machine. All agents share your machine, your network, and whatever databases and services run there, and a worktree separates working files only. Full isolation per agent is one of the <a href="../../about/">possible improvements</a>.

<a id="gate"></a>

## Changes that need the owner

Before a feature is committed, `check-guardrails.sh` looks at which files it changes. The rules come from the base branch, so a feature cannot loosen the rules it is checked against.

| Kind of change | Examples | What happens |
| --- | --- | --- |
| **Protected** | Decision records in `docs/decisions/`, CI workflows, `CODEOWNERS`, the agent configuration, and the scripts and prompts that carry out the review | The pull request is opened and marked as needing the owner's approval. No script merges it |
| **Sensitive** | `docs/architecture.md`, a new check in `scripts/verify.conf`, and paths you add yourself | Allowed; the reviewer is told to look at it closely |
| Everything else | Ordinary feature work | No extra step |

You add the paths that matter in your project, such as the deployment or the dependency manifest, to [`.agents/policies/guardrails.conf`](https://github.com/taspinar/agentic-coding-template/blob/main/.agents/policies/guardrails.conf). Changing or removing an existing check in `scripts/verify.conf` counts as protected; adding one counts as sensitive.

The reviewer also says how much a change affects the architecture. A "major" or "breaking" assessment marks the change as needing the owner, whatever the files are. The reviewer can make the outcome stricter, never looser. A feature committed without a review, as the risk policy can allow for a low-risk one, has no such assessment and therefore needs the owner too.

**The approval request.** When a feature needs you, `finish-feature.sh` writes `.agents/approval-requests/<issue>.json` and commits it with the feature: what you are asked to approve and why. It names the content tree, a checksum of exactly the content that was verified and reviewed, which `finish-feature.sh` and `publish-feature.sh` print next to the commit. The request is for display only: no script acts on it, and no agent takes it as an instruction. `check-guardrails.sh` computes the content tree again from the commit and refuses a request that names another one, and CI runs that check on every pull request.

Your approval is your own review of the pull request on GitHub, bound to the commit you see. Nothing an agent can write counts as it. That the approval really comes from you is enforced by GitHub only once agents have an identity of their own ([Issue 99](https://github.com/taspinar/agentic-coding-template/issues/99)); until then the scripts ask for your approval in the same cases as before.

See the [development guide](https://github.com/taspinar/agentic-coding-template/blob/main/docs/development.md) for command options, and <a href="../github-setup/">GitHub setup</a> for the settings that enforce merges.
