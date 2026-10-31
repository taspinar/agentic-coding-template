// Every step of the workflow: what happens, then its facts in order. The
// workflow reference (/docs/reference/workflow/) shows every step with its
// facts in the five fields (reference), and the step detail panel of the map
// takes its content from the same steps (details), so the panel and the
// reference cannot say different things. Text in backticks is a value (a
// command, a path, a policy line) and set as code (parts).
//
// The facts are those of docs/development.md.

export type Step = { id: string; title: string; text: string; facts: [string, string][] };

/** Text split at its backticks: every second part is a value. */
export const parts = (text: string) => text.split("`").map((part, index) => ({ part, code: index % 2 === 1 }));

export const planning: Step[] = [
  {
    id: "describe-the-idea",
    title: "Describe the idea",
    text: "Start with a short description of the project in your own words. It does not need every detail: the next step asks about what it leaves open.",
    facts: [
      ["who", "You"],
      ["input", "`docs/PROJECT_DESCRIPTION.md`, or a file anywhere passed with `--description`"],
      ["result", "The recorded input of the planning; no agent changes it"],
    ],
  },
  {
    id: "clarify-the-requirements",
    title: "Clarify the requirements",
    text: "Project Grill asks only the questions that materially affect the product or the technical direction: the goals, the users, the scope, the constraints. It writes the requirements as a draft; the script shows them and records them as approved only after you confirm.",
    facts: [
      ["who", "You and Project Grill, in the planning worktree"],
      ["script", "`./scripts/start-planning.sh [name]`"],
      ["result", "`docs/PROJECT_REQUIREMENTS.md`, approved"],
      ["your decision", "You approve the requirements; declining stops the planning and keeps the worktree"],
    ],
  },
  {
    id: "create-the-plan",
    title: "Create the plan",
    text: "A fresh planning session reads the approved requirements and proposes the architecture, a roadmap of features with IDs and dependencies, and an ADR for each technical decision that needs one.",
    facts: [
      ["who", "Planning agent"],
      ["script", "The same run of `start-planning.sh`"],
      ["result", "`docs/architecture.md`, `docs/roadmap.md`, `docs/decisions/`/"],
      ["stops if", "The agent fails or needs a decision from you; the worktree stays as it is"],
    ],
  },
  {
    id: "review-the-plan",
    title: "Review the plan",
    text: "An agent that cannot edit files checks the plan for missing requirements, inconsistent decisions and risks, and records its findings in a form the scripts validate.",
    facts: [
      ["who", "Planning reviewer, read-only"],
      ["script", "`./scripts/review-planning.sh`"],
      ["result", "A review round with its findings by severity"],
      ["next", "Address the findings, or approve the plan when there are none"],
    ],
  },
  {
    id: "address-the-findings",
    title: "Address the review findings",
    text: "The planning agent proposes a decision per finding: adopt, reject, defer or escalate to you. You approve the decisions, and a changed plan is reviewed again.",
    facts: [
      ["who", "You and the planning agent"],
      ["script", "`./scripts/revise-planning.sh`"],
      ["your decision", "You approve the decisions; an escalated finding needs your answer"],
      ["repeat", "Review again after every change, until a round changes nothing"],
    ],
  },
  {
    id: "approve-the-plan",
    title: "Approve the plan",
    text: "The approval is recorded with a fingerprint of the requirements and the roadmap. When either changes later, the approval is stale, and no feature Issue is created from it.",
    facts: [
      ["who", "You"],
      ["script", "`./scripts/finish-planning.sh`"],
      ["result", "`docs/PLANNING_APPROVAL.md` and the planning commit"],
      ["refused if", "The review is stale, the latest round has a critical or major finding, or a finding has no decision or is escalated"],
    ],
  },
  {
    id: "merge-the-plan",
    title: "Merge the planning pull request",
    text: "The approved planning is merged into main; features start from that version of the plan.",
    facts: [
      ["who", "You, or a maintainer by your repository's rules"],
      ["result", "The approved plan on main"],
    ],
  },
  {
    id: "change-the-plan",
    title: "Change an approved plan",
    text: "When the requirements or the direction change, write the change down in a short file. The planning agent updates the documents it touches, and the change goes through the review and your approval again. A small change to the architecture or an ADR has a lighter route.",
    facts: [
      ["who", "You and the planning agents"],
      ["script", "`./scripts/start-planning.sh <name> --change <file>`, with `--grill` when the requirements change"],
      ["small amendment", "`./scripts/finish-planning.sh --amend`"],
    ],
  },
];

export const feature: Step[] = [
  {
    id: "create-a-feature-issue",
    title: "Create a feature Issue",
    text: "Create the GitHub Issue of a roadmap feature when you are ready to build it, so that it matches the current requirements and architecture.",
    facts: [
      ["who", "Script, started by you"],
      ["script", "`./scripts/create-feature-issue.sh <feature-id>`"],
      ["result", "A GitHub Issue"],
      ["refused if", "The approval of the plan is missing or stale"],
    ],
  },
  {
    id: "implement-the-feature",
    title: "Implement the feature",
    text: "The implementer works in its own branch and worktree. Its first session decides whether the feature is clear: when the Issue with your comments, the requirements, the architecture, the accepted ADRs and the code settle every decision that matters, it implements; when they do not, it changes nothing, writes its questions in the handoff note with options and a recommendation, and stops. It writes the code and the tests, runs the checks itself, and records how far the Issue is done, with evidence per acceptance criterion.",
    facts: [
      ["who", "Implementer agent; the model follows the risk level"],
      ["script", "`./scripts/start-feature.sh <issue> [slug]`, or `--resume` to continue"],
      ["result", "Changes in the feature worktree, a completion record and a summary of the changes"],
      ["not done if", "The completion record does not say complete or awaiting evidence, or the handoff note lists remaining work"],
      ["blocked if", "The feature needs clarification or another decision of yours: answer in the handoff note or in a comment on the Issue, then resume; the next session implements"],
    ],
  },
  {
    id: "run-the-checks",
    title: "Run the checks",
    text: "The tests, linters and builds of `scripts/verify.conf`. A pass is recorded for exactly the content it checked and reused while that content does not change.",
    facts: [
      ["who", "Verification script"],
      ["script", "`./scripts/verify.sh`"],
      ["rule", "The verification has to pass before a review and before the commit"],
      ["fails", "The implementer repairs the failing check; an unattended run resumes it with the failing checks, at most three times"],
      ["partial check", "A policy can name groups of checks for the repair rounds between the first review and the last; a partial run is never a verification, and the commit needs every check"],
      ["budget", "A check declared as a budget measures: over its target it is reported as `BUDGET`, and the verification still passes"],
    ],
  },
  {
    id: "review-the-code",
    title: "Review the code",
    text: "An agent of another provider than the implementer, which cannot edit files, checks every acceptance criterion against the code and the tests, reports problems with their severity, and rates the impact on the architecture. The completion record is a claim; the reviewer reports one that the code does not support. Under the shipped risk policy every feature is reviewed; a project can let low-risk features skip it with `low: review: none`, which the light profile sets, and such a feature is committed as not reviewed.",
    facts: [
      ["who", "Reviewer agent, read-only"],
      ["script", "`./scripts/review-feature.sh <issue>`, or `--changes` for the recent fixes only"],
      ["result", "A review tied to the current content; a change afterwards needs a new review"],
      ["refused if", "The verification does not pass, unless `--unverified \"<reason>\"` records why; the commit still needs the checks to pass"],
      ["refused if", "The reviewer would be of the provider that implemented"],
    ],
  },
  {
    id: "decide-on-the-findings",
    title: "Decide on the findings",
    text: "Each finding gets a recorded decision: fix it now, defer it to a follow-up Issue, or accept it with a reason. Critical and major findings are always fixed. For a low- or medium-risk feature the policy can ask for the light triage, which prefers to defer or accept a suggestion or a minor finding over a fix round; a high-risk feature always gets the full triage.",
    facts: [
      ["who", "The triage agent proposes; step by step you approve, unattended it decides"],
      ["script", "`./scripts/triage-review.sh <review-json>`"],
      ["result", "Recorded decisions, published on the Issue"],
      ["your decision", "Step by step you approve the decisions, or give your own with `--decisions <file>` `--reason \"<why>\"`; unattended, read them on the Issue afterwards"],
    ],
  },
  {
    id: "apply-the-fixes",
    title: "Fix and review again",
    text: "The implementer fixes only the findings decided as fix now, and the checks run again. The content changed, so it is reviewed again: the changes, then the complete feature.",
    facts: [
      ["who", "Implementer agent"],
      ["script", "`./scripts/apply-triage.sh <triage-json>`"],
      ["next", "`./scripts/review-feature.sh <issue> --changes`, then `./scripts/review-feature.sh <issue>`"],
    ],
  },
  {
    id: "commit-the-feature",
    title: "Commit the feature",
    text: "The commit records the completion with its evidence, the verification, the review and its triage, and the risk level with its reasons. When the merge needs your approval, the commit carries an approval request that names the content tree that was verified and reviewed; it asks and records, it grants nothing.",
    facts: [
      ["who", "Script"],
      ["script", "`./scripts/finish-feature.sh <issue> \"<summary>\"`"],
      ["refused if", "The completion record is missing or does not say complete or awaiting evidence, the verification does not pass, or the latest review is stale, does not cover the complete feature, or has a critical or major finding"],
      ["without review", "Low risk with `low: review: none` is committed as not reviewed; the owner can also skip the review with `--no-review \"<reason>\"`, which is recorded"],
      ["important", "This step does not push or merge"],
    ],
  },
  {
    id: "open-the-pull-request",
    title: "Open the pull request",
    text: "The branch is pushed and the pull request opened with the evidence, the risk level and whether the merge needs your approval. CI runs the checks again. Unfinished work becomes a draft that leaves the Issue open; evidence that exists only after the merge is recorded later with `./scripts/record-post-merge.sh`.",
    facts: [
      ["who", "Script"],
      ["script", "`./scripts/publish-feature.sh <issue>`"],
      ["result", "An open pull request that closes the Issue when the feature is complete"],
    ],
  },
  {
    id: "merge",
    title: "Review and merge",
    text: "Read the pull request, its checks and the published triage before you merge. Your approval is needed when the change touches a protected path, when the reviewer rated the impact on the architecture major or breaking, or when nobody rated it, as for a feature without a review. Codeyard states and checks this; GitHub enforces it only with the rulesets and code owners you configure.",
    facts: [
      ["who", "You, or a maintainer by your repository's rules; no script merges"],
      ["script", "`./scripts/check-guardrails.sh` lists what needs you"],
      ["after the merge", "`./scripts/cleanup-worktree.sh <issue>`"],
    ],
  },
  {
    id: "run-unattended",
    title: "Run a feature unattended",
    text: "One command runs the implementation, the checks, the review rounds with their triage and fixes, the commit and the pull request. It retries a temporary failure, and stops when an agent needs you or it cannot safely go on, with the reason and the command that resolves it.",
    facts: [
      ["who", "Script that coordinates the agents"],
      ["script", "`./scripts/run-feature.sh <issue> [--risk <level>]`"],
      ["limits", "Four implementer sessions, three repairs of a failed verification, five review rounds"],
      ["result", "An open pull request, or the reason the run stopped"],
      ["important", "It never merges"],
    ],
  },
];

/** The two stages of the workflow, as the reference groups its steps. */
export const stages = [
  { id: "plan-the-project", title: "Plan the project", note: "Once at the start, and again when the plan changes.", steps: planning },
  { id: "build-each-feature", title: "Build each feature", note: "For every roadmap feature, in its own branch and worktree.", steps: feature },
];

/**
 * The fields of the reference, in their fixed order, and the field of each
 * label of a fact; a label not named here is a stop, a retry or an exception.
 * A fact keeps its label inside its field, so nothing of the step is lost.
 */
export const fields = [
  ["who", "Who acts"],
  ["command", "Command"],
  ["io", "Inputs and outputs"],
  ["gate", "Gate or decision"],
  ["stops", "Stops, retries and exceptions"],
] as const;
export type Field = (typeof fields)[number][0];
const fieldOf: Record<string, Field> = {
  who: "who",
  script: "command",
  input: "io", result: "io", "after the merge": "io",
  "your decision": "gate", rule: "gate", next: "gate",
};

/** The steps of the reference behind each station of the map that has details. */
export const stations: Record<string, string[]> = {
  "p-idea": ["describe-the-idea"],
  "p-req": ["clarify-the-requirements"],
  "p-approve-req": ["clarify-the-requirements"],
  "p-plan": ["create-the-plan"],
  "p-review": ["review-the-plan", "address-the-findings"],
  "p-approve": ["approve-the-plan"],
  "p-merge": ["merge-the-plan"],
  "f-issue": ["create-a-feature-issue"],
  "f-implement": ["implement-the-feature"],
  "f-checks": ["run-the-checks"],
  "f-review": ["review-the-code"],
  "f-findings": ["decide-on-the-findings", "apply-the-fixes"],
  "f-commit": ["commit-the-feature"],
  "f-pr": ["open-the-pull-request"],
  "f-merge": ["merge"],
};

/** The tabs of the step detail panel and the fields each shows. */
export const tabs = [
  { id: "overview", name: "Overview", fields: ["who", "gate"] },
  { id: "technical", name: "Technical", fields: ["command", "io"] },
  { id: "failure", name: "Failure states", fields: ["stops"] },
] as const satisfies readonly { id: string; name: string; fields: readonly Field[] }[];

export interface Row {
  label: string;
  /** The facts of the field, each with its original label (shown when it says more than the field). */
  facts: { label: string; value: string; shown: boolean }[];
}

/** The facts in the fields of the given keys, in the fixed order; a field without facts is omitted. */
function rows(facts: [string, string][], keys: readonly Field[]): Row[] {
  return fields.filter(([field]) => keys.includes(field)).flatMap(([field, label]) => {
    const mine = facts.filter(([term]) => (fieldOf[term] ?? "stops") === field);
    if (!mine.length) return [];
    const shown = mine.length > 1 || !["who", "command"].includes(field);
    return [{ label, facts: mine.map(([term, value]) => ({ label: term, value, shown })) }];
  });
}

/** A step of the reference: its facts in all five fields. */
export const reference = (step: Step): Row[] => rows(step.facts, fields.map(([field]) => field));

/** The detail of a station: its title, the summaries of its steps, its rows per tab, and its steps. */
export function details(key: string) {
  const steps = (stations[key] ?? []).map((id) => {
    const step = [...planning, ...feature].find((s) => s.id === id);
    if (!step) throw new Error(`stations: ${key} names ${id}, which is not a step`);
    return step;
  });
  if (!steps.length) return undefined;
  const facts = steps.flatMap((step) => step.facts);
  return {
    title: steps[0].title,
    summaries: steps.map((step) => step.text),
    tabs: tabs.map((tab) => ({ ...tab, rows: rows(facts, tab.fields) })),
    steps: steps.map(({ id, title }) => ({ id, title })),
  };
}
