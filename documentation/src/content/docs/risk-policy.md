---
title: "Risk policy and workflow profiles"
description: "How risk is computed and how profiles change the requirements."
order: 5
---

<a id="policy-settings"></a>

## The risk policy

The <a href="../risk-policy/#risk">risk level of a feature</a> is computed from the policy file, [`.agents/policies/risk.conf`](https://github.com/taspinar/agentic-coding-template/blob/main/.agents/policies/risk.conf), one `<key>: <value>` per line with paths. Like the rules of the gate, it is always read from the base branch, so a feature that changes it is classified by the old one, and is high risk because it changed a policy.

Example classes for an application (not the shipped policy):

```text
default: medium
low: docs :(glob)**/*.md
high: src/auth db/migrations deploy
```

The classes `low`, `medium`, and `high` name paths; a path in two classes gets the higher one, and a path in none gets the `default`. The template ships `default: medium`, the paths of the workflow and its gate as `high`, and no `low` class: every feature is medium or high until you add classes for your project.

Some changes make a feature high whatever the classes say:

| Kind of change | Examples | What happens |
| --- | --- | --- |
| **A weakened test** | A removed or changed line of an existing test file, or a removed test file | High. A diff that only adds lines to a test file does not escalate: a new test weakens nothing |
| **Shared test fixtures** | Any change to the libraries many tests load (`test-fixtures`), also an added line or a new file | High, since such a file can change every test |
| **The verification configuration** | A changed or removed line in `scripts/verify.conf` or `scripts/verify-workflow.conf` | High |
| **Policies, prompts, schemas** | A change to an existing file under `.agents/policies/`, `.agents/prompts/`, or `.agents/schemas/` | High |
| **Manifests** | A change to an existing dependency or toolchain file that the policy names under `manifests` | High |

**What each level requires.** The policy can also say, per level, what the review rounds of `run-feature.sh` need, one `<level>: <kind>: <value>` per line:

| Line | What it means |
| --- | --- |
| `verification: full` or `groups <group>...` | Every check before every review round, or only the named groups in the repair rounds between the first review and the last. A partial check is never a verification: the commit still needs every check |
| `review: delta`, `full`, or `none` | Whether a later round may review only the changes, or always the complete feature. `low: review: none` commits a low-risk feature without a review; only `low` may have it |
| `triage: full` or `light` | The light triage prefers to defer or accept a suggestion or a minor finding over a fix session. Only `low` and `medium` may have it |

The template writes no such line, so every level gets the full verification, reviews of the changes when a round can build on the one before, and the full triage: what the workflow always did. A value that is not allowed counts as the strictest one, and `check-risk.sh` reports it as refused.

**Profiles.** One line, `profile: light` or `profile: standard`, fills in the rules the file does not write (<a href="../risk-policy/#workflow-profiles">workflow profiles</a>). `light` makes documentation and process files low risk, commits a low-risk feature without a review, and gives low- and medium-risk features the light triage. No profile changes what a high-risk feature gets. The template ships no `profile:` line; to switch, change that one line and merge it.

<a id="risk"></a>

### The risk level of a feature

Every feature has a risk level: low, medium, or high. The workflow computes it; you can raise it with the label `risk: high` or `risk: medium`, or `--risk`. Nobody can lower it. It is the highest of three things:

- **The paths the feature changes**, by the classes of the risk policy. A path that no class names gets the default.
- **Fixed escalations to high** that no policy turns off, such as a removed or changed line of an existing test, a changed or removed line of the verification configuration, or a change to an existing file under `.agents/policies/`, `.agents/prompts/`, or `.agents/schemas/`. An added file does not escalate by itself; protected paths remain high by their class. Any change to shared test fixtures, including an added line, escalates.
- **What the agents say**: the implementer can record a higher level, and a reviewer who rates the impact on the architecture as major or breaking makes the feature high.

The level can be raised, never lowered: a lower claim is ignored and reported. The rules are read from the base branch, so a feature cannot relax the rules it is classified by. The level decides which model an agent uses (<a href="../agent-roles/#roles">agent roles and models</a>) and what the review rounds require (<a href="#policy-settings">the risk policy</a>). It does not replace the merge approval: a protected path still needs you. The scripts print the level with its reasons, the commit and the pull request record it, and `./scripts/check-risk.sh` shows it for the current worktree.

A new feature has no changes yet, so its first session runs at the default level. When you know that a feature is risky, say so before that session: label the issue `risk: high` (or `risk: medium`), or pass `--risk high` to `start-feature.sh` or `run-feature.sh`. A label counts for the whole feature; the option for one run. Either one only raises the level.

### Workflow profiles

A workflow profile is one line in the risk policy, `profile: light` or `profile: standard`, that fills in the rules the policy does not write itself. A line you write always wins.

| Profile | What it means |
| --- | --- |
| No `profile:` line | Nothing is added: the policy is the lines of the file, as before profiles existed. This is what the template ships |
| `standard` | The policy the template ships, written as a preset |
| `light` | The same, and documentation and process files are low risk. A low-risk feature is committed without a review, and its merge then needs your approval, since nobody assessed its impact; a low- or medium-risk feature gets the light triage |

A profile never changes what a high-risk feature gets: under every profile it has the full workflow. It does not select the level, and it is unrelated to the permission profiles of the agents. Under every profile the implementer, the full verification before the commit, the pull request, CI, and the merge approval stay. A feature that changes the profile line is classified by the profile of the base branch, and is high risk, because it changes the policy.

## Shipped configuration

The active lines of [.agents/policies/risk.conf](https://github.com/taspinar/agentic-coding-template/blob/main/.agents/policies/risk.conf):

```text
default: medium
high: docs/decisions .github/workflows .github/CODEOWNERS .agents/policies .agents/prompts/reviewer.md .agents/schemas .agents/agents.conf scripts/check-guardrails.sh scripts/lib/guardrails.sh scripts/check-risk.sh scripts/lib/risk.sh scripts/lib/agent.sh scripts/lib/review-data.sh scripts/lib/review-run.sh scripts/lib/fingerprint.sh scripts/review-feature.sh scripts/finish-feature.sh scripts/publish-feature.sh scripts/run-feature.sh scripts/verify.conf scripts/verify-workflow.conf
tests: tests test
test-fixtures: tests/lib-fakes.sh
```
