---
title: "Agent roles and models"
description: "Choose providers and models for every role and risk level."
order: 4
---

<a id="roles"></a>

## Agent roles and models

A role is a job in the workflow, not a person or an account. Each role has an agent and a model, set in [`.agents/agents.conf`](https://github.com/taspinar/agentic-coding-template/blob/main/.agents/agents.conf), one role per line:

```
implementer: claude opus
reviewer: codex gpt-6-luna
```

| Role | What it does |
| --- | --- |
| `project-grill` | Asks you questions about a new project and writes the requirements |
| `project-planner` | Writes the architecture, the roadmap, and the decision records |
| `planning-reviewer` | Reviews the plan, read-only |
| `implementer` | Implements a feature and writes its tests |
| `reviewer` | Reviews a feature, read-only |
| `triage` | Proposes what to do with each review finding |
| `triage-implementer` | Fixes the findings that were selected |
| `analyst` | Compares the runs of several features and proposes improvements, read-only (<a href="../technical-reference/#learning">learning from your runs</a>) |

The supported agents are Claude Code (`claude`) and Codex (`codex`). You can override the agent and the model for one run with `--agent` and `--model` on a workflow script. The model you name is passed to the agent as it is: the workflow never replaces it with another one, and an unknown agent is an error.

The reviewer must use a different agent than the implementer, at every risk level: that is what makes the review independent. `review-feature.sh` refuses to start a reviewer that resolves to an agent the implementer of the feature ran with, and `doctor.sh` warns when a reviewing role and the role it reviews resolve to the same agent.

A role of a feature (`implementer`, `reviewer`, `triage`, `triage-implementer`) can also have a line per <a href="../risk-policy/#risk">risk level</a> of the feature, such as `implementer@high: claude fable` next to `implementer: claude opus`. A script that starts the role takes `--agent` and `--model` first, then the line of the level the feature has at that moment, then the plain line; a later session of a feature never runs at a weaker level than an earlier one did. Without a level line the plain line applies. `doctor.sh` validates the lines, and `report-runs.sh` shows the calls per level and model.

**What the template ships.** These are the template's own choices; set the agents, models, and levels your project wants:

| Role | Low and medium risk | High risk |
| --- | --- | --- |
| `implementer`, `triage-implementer` | Claude, `opus` | Claude, `fable` |
| `reviewer` | Codex, `gpt-6-luna` | The same |
| `triage` | Claude, `sonnet` | The same |
| `project-grill`, `project-planner` | Claude, `fable` | |
| `planning-reviewer` | Codex, `gpt-6-astra` | |
| `analyst` | Claude, `fable` | |

The levels come from the features that built the template: a feature that changes the workflow and its gate, which is high risk, needed one or two rounds with the strongest model and many with a weaker one, while the other features did not need it. Codex stays supported as implementer for a project that configures it.

## Shipped configuration

The active lines of [.agents/agents.conf](https://github.com/taspinar/agentic-coding-template/blob/main/.agents/agents.conf):

```text
project-grill: claude fable
project-planner: claude fable
planning-reviewer: codex gpt-6-astra
implementer: claude opus
implementer@high: claude fable
reviewer: codex gpt-6-luna
triage: claude sonnet
triage-implementer: claude opus
triage-implementer@high: claude fable
analyst: claude fable
```
