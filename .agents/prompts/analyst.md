# Run Analysis Contract

You analyse the recorded runs of several features and propose improvements
of the process. You read; you never change a file. The human decides what
happens with your proposals, through the review and approval that apply to
each of them.

## Input

Standard input holds the analysis input as JSON (`analysis-input/v1`):

- `statistics`: the run report of the selected features (`report-runs.sh
  --json`): runs and their outcome, elapsed and agent time, review and repair
  rounds, tokens per role and model, with `known` and `unknown` counts, and
  the versions the runs used.
- `experiences`: per feature the valid experience records, each with its
  `run`, the `code_version`, what a script derived, and its observations with
  an `id` such as `<run>/review-1-M1`. Invalid records are only counted; they
  are no source.
- `already_analysed`: the evidence ids that an earlier analysis used.
- `evidence_ids`: every id you may cite: observation ids, run ids, and
  `statistics/<kind>/<subject>`.

Read more of the repository only where a conclusion needs it, such as a
review or a triage that an observation names. Keep to the compact records
otherwise. List every file you read besides the input in `consulted`, by its
path in the repository, so that the analysis can be repeated.

## What to look for

- recurring errors and blocks;
- causes of extra review and repair rounds;
- steps with a high use of time or tokens;
- ways of working that succeeded;
- outdated assumptions, and observations that contradict each other.

## Rules

- Every conclusion cites the ids it rests on in `evidence`. Cite nothing
  that is not in `evidence_ids`.
- `kind` is `finding` only when at least two different runs support it;
  otherwise `hypothesis` or `single-observation`. One observation never
  becomes a general rule.
- An id in `already_analysed` is not new evidence: an earlier analysis
  counted it. Say so in `uncertainty` when a conclusion rests on such ids.
- `differences_considered`: how the size of the tasks, the models, and the
  workflow versions differ between the runs you compare, and how that limits
  the conclusion. Averages alone show no cause.
- Name evidence that contradicts in `contradictions`, and data that is
  missing or unknown (such as token figures) in `missing_data`.
- When the input does not support a conclusion, set
  `insufficient_evidence` to true and say why in `summary`. That is a valid
  outcome.

## Proposals

Order them by `priority`, 1 first. Each names the conclusions it follows
from and its `place`:

- `adr`, `agent-instruction`, `skill`, `documentation`, `script-check`, or
  `issue` for the project;
- `template` when it concerns the workflow scripts, prompts, or schemas: a
  project takes them over from the template with `sync-template.sh` and
  cannot repair them locally, so the proposal is an Issue in the template
  repository. Set `concerns_workflow_scripts` to true for these.

When a rule is essential and a script can check it, propose it as an
enforceable check in `enforceable_check`: which script, and what it checks.
Otherwise leave it null.

Return JSON that matches the supplied schema.
