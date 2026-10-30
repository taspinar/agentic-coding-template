---
title: "Detailed workflow"
description: "Every planning and feature step: commands, approvals and artifacts."
order: 3
---

<a id="steps"></a>

## Every step in detail

### Stage 1 · Plan the project

<a id="step-idea"></a>

### Describe the idea

Start with a short description of your project. You do not need every detail worked out: the next step helps find what is missing.

| Field | Detail |
| --- | --- |
| Who | You |
| Input | `PROJECT_DESCRIPTION.md`, written by you |
| Result | A starting point for the planning |
| Important | Agents do not overwrite your description |

<a id="step-grill"></a>

### Clarify the requirements (Project Grill)

The planning agent asks questions about the goals, the users, the scope, and the constraints of the project. We call this round the Project Grill. It then writes a requirements document for you to review. Planning continues after you approve it.

| Field | Detail |
| --- | --- |
| Who | You and the planning agent |
| Script | `./scripts/start-planning.sh <name>` |
| Input | The project description and your answers |
| Result | `docs/PROJECT_REQUIREMENTS.md` in the planning worktree, a separate working copy of the repository |
| Your approval | You approve the requirements |

<a id="step-plan"></a>

### Create the project plan

From the approved requirements, the planning agent proposes an architecture, a roadmap of features with IDs and dependencies, and a record of each important technical decision.

| Field | Detail |
| --- | --- |
| Who | Planning agent |
| Script | The same run of `start-planning.sh` |
| Result | `docs/architecture.md`, `docs/roadmap.md`, `docs/decisions/` |
| Blocked if | The agent needs you to make a decision |

<a id="step-planning-review"></a>

### Review the plan

A separate agent that cannot edit files checks the plan for missing requirements, inconsistent decisions, and risks. It records its findings in a format the workflow can validate.

| Field | Detail |
| --- | --- |
| Who | Independent planning reviewer |
| Script | `./scripts/review-planning.sh` |
| Result | A review report with findings grouped by severity |
| Next | Address the findings, or go on to the approval when there are none |

<a id="step-revise"></a>

### Address the review findings

The planning agent proposes what to do with each finding: adopt it, reject it, defer it, or escalate it to you. You approve those decisions. If the plan changes, the reviewer checks the new version again.

| Field | Detail |
| --- | --- |
| Who | You and the planning agent |
| Script | `./scripts/revise-planning.sh` |
| Your approval | You approve the decisions; an escalated finding needs your answer |
| Repeat | Review again after every change, until a round changes nothing |

<a id="step-finish-planning"></a>

### Approve the plan

The workflow records your approval together with a fingerprint: a checksum that identifies the exact version of the requirements and the roadmap you approved. If either document changes later, the approval no longer applies.

| Field | Detail |
| --- | --- |
| Who | You |
| Script | `./scripts/finish-planning.sh` |
| Result | `docs/PLANNING_APPROVAL.md` and the planning commit |
| Blocked if | The review is outdated or a required decision is missing |

<a id="step-planning-merge"></a>

### Merge the planning pull request

The approved planning documents are merged into `main`. Feature development starts from that version of the plan.

| Field | Detail |
| --- | --- |
| Who | Repository maintainer |
| Result | The approved plan on `main` |

<a id="step-change"></a>

### Update an approved plan

When the requirements or the direction of the project change, write a short change request. The planning agent updates the documents the request touches, and the changes go through review and approval again. A lighter process exists for a small change to the architecture or to a decision record.

| Field | Detail |
| --- | --- |
| Who | You and the planning agents |
| Script | `./scripts/start-planning.sh <name> --change <file>` |
| Optional | `--grill` when the requirements need clarification |
| Small amendments | `./scripts/finish-planning.sh --amend` |
| Important | Feature IDs stay the same, and a replaced decision stays traceable |

### Stage 2 · Build each feature

<a id="step-issue"></a>

### Create a feature issue

Create a GitHub issue for the roadmap feature you are ready to build. Creating it at that moment keeps it in line with the current requirements and architecture.

| Field | Detail |
| --- | --- |
| Who | Script, started by you |
| Script | `./scripts/create-feature-issue.sh F01` |
| Input | The approved roadmap entry |
| Result | A GitHub issue |
| Blocked if | The approval of the plan is no longer valid |

<a id="step-implement"></a>

### Implement the feature

The implementer works in a separate branch and worktree. It reads the feature issue and the approved project documents, writes the code and the tests, and leaves notes so that the work can be resumed. Before it ends, it records how far the issue is done: complete, awaiting evidence, partial, or blocked, with evidence for each acceptance criterion. Evidence that cannot exist yet, such as the CI result of a pull request that is not published or a check of the default branch after the merge, is recorded as pending at its gate, and the status is then awaiting evidence.

Before it changes anything, the first session decides whether the feature is clear. It reads the issue, the requirements, the architecture, the accepted decision records, and the code. When they settle every decision that matters for the scope, the user experience, a public interface, the data, the architecture, security, or compatibility, it implements, and its notes say `Clarification: clear`. When they do not, it changes nothing, writes its questions in the handoff note, each with the options and its recommendation, and the run stops for you. A choice the agent can make itself, such as a name or the layout of the tests, is not a question for you.

Your comments on the issue reach the agents. The implementer, the reviewer, and the triage agent get them after the body of the issue, so all three judge the same issue. Only comments of the owner, members, and collaborators of the repository are passed on, never those of anyone else, and the reports that the workflow posts itself are left out. A comment you add later counts from the next session.

| Field | Detail |
| --- | --- |
| Who | Implementer agent |
| Script | `./scripts/start-feature.sh <issue>` |
| Resume | `./scripts/start-feature.sh <issue> --resume` |
| Result | Changes in the feature worktree, and a completion record |
| Not done if | The record does not say complete or awaiting evidence, or the notes list remaining work. A session that ends is not a finished feature: the workflow continues to the review only when the record says complete, or awaiting evidence for a later gate |
| Blocked if | The feature needs clarification, or the agent needs another decision from you. Answer in the handoff note or in a comment on the issue, and resume: the next session reads your answers and implements |

<a id="step-verify"></a>

### Run verification

Run the tests, lint checks, and build commands configured for the project. A successful run is recorded, so it can be reused while the checked code does not change.

| Field | Detail |
| --- | --- |
| Who | Verification script |
| Script | `./scripts/verify.sh` |
| Configuration | `scripts/verify.conf` |
| Rule | Verification has to pass before a feature is reviewed and before it is committed |
| Partial check | When the risk policy names groups of checks for the level of the feature, a repair round between the first review and the last runs only the named groups of checks. A partial check is never a verification: it records no pass, the reviewer is told, and the commit still needs every check |
| Budget | A check declared as a budget is a measurement, not a failure: over its target it is reported as `BUDGET`, the verification still passes, and nothing repairs it |
| Exception | `review-feature.sh <issue> --unverified "<reason>"` reviews work whose verification fails. The review records the reason; the checks still count as failed, and the commit still requires them to pass |

<a id="step-review"></a>

### Review the implementation

An independent agent that cannot edit files compares the change with the feature's requirements. It reports problems with their severity and says how much the change affects the architecture.

| Field | Detail |
| --- | --- |
| Who | Reviewer agent |
| Script | `./scripts/review-feature.sh <issue>` |
| Option | `--changes` for a follow-up review of the recent fixes only. The review before the commit always covers the complete feature |
| Changes only | In a run of `run-feature.sh`, a later round reviews only the changes when the risk policy allows it, the previous round is valid, the base of the branch is the same, and the risk level did not rise. Otherwise the complete feature is reviewed again, and the run says why |
| Checks | Every acceptance criterion of the issue against the code and the tests. The implementer's completion record is a claim; the reviewer reports a claim the code does not support |
| Earlier rounds | Every round after the first gets the decisions of the earlier rounds. The reviewer does not raise an accepted or deferred finding again unless the change made it worse, and a finding that continues an earlier one names it, as unresolved or worsened. The scripts check that claim: a re-raised finding cannot lower the severity of the one it continues |
| Result | A review tied to the current version of the code. If the code changes afterward, another review is required |
| Next | Decide on the findings, or commit when there are none |

<a id="step-triage"></a>

### Decide what to do with review findings

For each finding, decide whether to fix it now, defer it to a follow-up issue, or accept it with a reason. This step is called triage.

| Field | Detail |
| --- | --- |
| Who | You, step by step. An agent, in an unattended run |
| Script | `./scripts/triage-review.sh <review>` |
| Result | Recorded decisions, published on the feature issue |
| Your approval | Step by step, you approve the decisions. In an unattended run an agent decides without you: read its decisions afterward |
| Light triage | For a low- or medium-risk feature, the risk policy can ask for a light triage: the agent is told to defer or accept a suggestion or a minor finding rather than start a fix session, unless it blocks the feature. Critical and major findings are always fixed, and a high-risk feature always gets the full triage |

<a id="step-fix"></a>

### Apply fixes and review again

The implementer fixes only the findings that were selected in the triage, and the checks run again. The code has changed, so another review is required: run the review again, until a review has nothing left to fix.

| Field | Detail |
| --- | --- |
| Who | Implementer agent |
| Script | `./scripts/apply-triage.sh <triage>` |
| Result | Verified fixes that wait for another review |
| Next | `./scripts/review-feature.sh <issue> --changes` to confirm the fixes, then `./scripts/review-feature.sh <issue>` for the complete feature |

<a id="step-commit"></a>

### Commit the feature

Before committing, the script checks that the feature is complete, that verification passed, and that the latest review is still valid and covers the complete feature. The commit message records all three, the risk level of the feature with its reasons, and whether the change needs additional approval.

When the change needs your approval, the script also writes an approval request, `.agents/approval-requests/<issue>.json`, and commits it with the feature. It says what you are asked to approve and why, and names the content tree: a checksum of exactly the content that was verified and reviewed, which the script prints next to the commit. The request only asks and records; it grants nothing.

| Field | Detail |
| --- | --- |
| Who | Script |
| Script | `./scripts/finish-feature.sh <issue> "<summary>"` |
| Result | A commit with the completion, verification, review, and risk information, and the approval request when you have to approve the merge |
| Refuses if | The implementer's completion record is missing or does not say complete or awaiting evidence. `--partial` commits unfinished work as your explicit choice |
| Important | This step does not push or merge |

<a id="step-publish"></a>

### Open the pull request

Push the feature branch and open a pull request linked to its GitHub issue. CI runs the project's checks again. The pull request closes the issue only when the feature is complete; unfinished work becomes a draft that leaves the issue open. A feature that waits for a check of the default branch after the merge is ready for review, but leaves the issue open until `./scripts/record-post-merge.sh` records that evidence.

| Field | Detail |
| --- | --- |
| Who | Script |
| Script | `./scripts/publish-feature.sh <issue>` |
| Result | An open pull request with the verification and review details, the risk level and its reasons, and whether the merge needs your approval, with the content tree you are asked to approve next to the commit |

<a id="step-merge"></a>

### Review and merge

Check the pull request, the test results, and the required approvals before you merge. The workflow points out changes that need the owner's attention. To enforce those rules for everyone, configure permissions and branch protection in GitHub: the scripts alone cannot do that.

| Field | Detail |
| --- | --- |
| Who | Authorized repository maintainer |
| Script | `./scripts/check-guardrails.sh` lists what needs the owner |
| After the merge | `./scripts/cleanup-worktree.sh <issue>` |

<a id="step-run"></a>

### Run a feature unattended

One command coordinates implementation, verification, review, triage, fixes, the commit, and the pull request. It retries a temporary failure and stops when it cannot safely continue.

| Field | Detail |
| --- | --- |
| Who | Script that coordinates the agents |
| Script | `./scripts/run-feature.sh <issue>` |
| Limit | Up to five review rounds |
| Result | An open pull request, or an explanation of why the run stopped |
| Important | The command does not merge |

## Owner-directed triage

When the agent's triage proposal is disproportionate, you can supply your decisions:

```bash
./scripts/triage-review.sh <review-json> --decisions <file> --reason "<why you override>"
```

The file contains one decision per finding in the triage schema. `--proposal <file>` optionally records the original proposal. Critical and major findings remain `FIX_NOW`; every `DEFER` needs a follow-up Issue and every `ACCEPT` a rationale. The script starts no agent, refuses `--unattended`, shows your decisions for confirmation, creates any follow-up Issues, then asks again before storing and publishing the complete artifact. The Issue comment records your account and reason. This does not bypass review or publication gates.

See [Owner-directed triage in the command reference](https://github.com/taspinar/agentic-coding-template/blob/main/docs/development.md#owner-directed-triage) for the schema and recovery after declining.

## Skipping a review explicitly

Under the shipped policy every feature needs independent review before commit. A project can allow Low features to skip review with `low: review: none` or `profile: light`. For a low-risk change, you can also explicitly finish without a review with `finish-feature.sh <issue> "<summary>" --no-review "<reason>"`; `check-risk.sh` shows the risk level. The commit and pull request record that it was not reviewed; the merge needs the owner. Verification and completion still apply.

## Plans and earlier review rounds

An optional technical plan lives in `.agents/plans/`; link it with `./scripts/update-issue-with-plan.sh <issue> <plan>`. The Issue owns scope and acceptance criteria; the plan owns implementation details. Do not turn each plan step into a separate Issue.

Reviewers and triage receive earlier rounds and their approved decisions. A continuing finding identifies its predecessor as unresolved or worsened; it cannot lower the earlier severity or weaken an unresolved `FIX_NOW` decision. Accepted or deferred findings are not raised again without a worsening caused by the change. See [review history](https://github.com/taspinar/agentic-coding-template/blob/main/docs/development.md#earlier-rounds-and-re-raised-findings).

After you merge, run `./scripts/cleanup-worktree.sh <issue>` from the primary checkout. No workflow script merges for you.

The [workflow reference](https://github.com/taspinar/agentic-coding-template/blob/main/docs/workflow.md) describes the artifacts and approvals of every step; the [development guide](https://github.com/taspinar/agentic-coding-template/blob/main/docs/development.md) holds the complete command options.
