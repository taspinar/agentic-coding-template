---
title: "Troubleshooting"
description: "Resume interrupted work and resolve checks, stale evidence and agent failures."
order: 9
---

## If something goes wrong

### A tool is missing, or GitHub is not signed in

Run `./scripts/doctor.sh`. It names what is missing.

### An agent does not start, or rejects the model

Check the agent and the model of that role in `.agents/agents.conf`, and that the agent's command-line tool is signed in. The workflow passes the model name on as you wrote it.

### A check fails

`./scripts/verify.sh` prints which check failed and its output. A feature cannot be reviewed or committed until the checks pass.

### A script says a review is no longer current

The code changed after the review. Run `./scripts/review-feature.sh <issue>` again.

### A script says the plan approval is not current

The requirements or the roadmap changed after you approved them. Changes to an approved plan go through <a href="../detailed-workflow/#step-change">the change process</a>.

### A session or a run was interrupted

Continue with `./scripts/start-feature.sh <issue> --resume`, or run `./scripts/run-feature.sh <issue>` again: it picks up where it stopped.

<a id="handles"></a>

## Situations the workflow handles

### The plan has to change

You do not edit an approved plan by hand. A change request goes through review and approval again: <a href="../detailed-workflow/#step-change">update an approved plan</a>.

### A run is interrupted

The implementer keeps a handoff note with what is done and what remains, so the work continues without the earlier conversation: `start-feature.sh <issue> --resume`, or `run-feature.sh <issue>` again. An unattended run retries a temporary failure itself. When an agent needs a decision from you, it stops and leaves its question in the note.

### The issue leaves a decision open

The implementer asks before it invents an answer: it writes its questions in the handoff note and the run stops. Answer there or in a comment on the issue, and run the feature again. See <a href="../detailed-workflow/#step-implement">implement the feature</a>.

### Results are no longer current

A verification result belongs to the exact content that was checked: change the code and the checks run again. A review belongs to the content that was reviewed: when that changes, the scripts ask for a new review. If the base branch was merged into the feature in the meantime, a later review has to cover the complete feature, not only the recent changes. The approval of the plan lapses in the same way when the requirements or the roadmap change. See <a href="../verification-and-completion/#verification">project checks and workflow checks</a> for the details.

### An agent hits a usage limit

When the provider of an agent refuses a session because a usage or rate limit is reached, the script shows the provider's own message and says that it is a usage limit, not a defect: run the step again after the time the provider names. An unattended run retries the step and writes the limit into its log, so you can see afterward why it stopped.

### The network fails while a feature starts

Reading the issue is tried again when the connection or GitHub fails for a moment; an issue that does not exist, or a refusal, stops at once with its reason. An unattended run tries the start again, like any other temporary failure.

### The base branch moved after a feature was finished

Merge the base branch into the feature branch and publish again: `git merge origin/main`, then `./scripts/publish-feature.sh <issue>`. The pull request is still described by the commit of the finished feature and still closes the issue. Any other commit after the finish needs a new finish first.

### A review has findings

Each finding gets one of three recorded decisions: fix it now (`FIX_NOW`), defer it to a follow-up issue (`DEFER`), or accept it with a reason (`ACCEPT`). See <a href="../detailed-workflow/#step-triage">decide what to do with review findings</a>.

### You need a review although a check fails

`review-feature.sh <issue> --unverified "<reason>"` reviews work whose verification fails, and records the reason. It is an exception, not a pass: the checks still count as failed, and the feature cannot be committed until they pass.

### Your checks, and the checks of the workflow

Your project's tests and linters are one list; the tests of the workflow scripts are another. See <a href="../verification-and-completion/#verification">project checks and workflow checks</a>.
