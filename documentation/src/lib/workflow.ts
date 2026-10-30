// The states of the workflow map on /workflow: what the drawing, its words
// list, its caption and its walkthrough show for a part of the workflow, a
// way of running it, a risk level, a profile and a situation. The page
// renders the initial state at build time and the map's script renders every
// other state from the same function, so the drawing without JavaScript is
// the initial state, complete.
//
// The facts are those of docs/development.md ("Project bootstrap workflow",
// "Clarifying a feature", "Running a feature with one command", "What each
// level requires", "Workflow profiles", "The merge approval gate"); the
// models are read from .agents/agents.conf at build time (parseAgents).

export type Part = "all" | "planning" | "feature";
export type Run = "steps" | "unattended";
export type Risk = "low" | "medium" | "high";
export type Profile = "standard" | "light";
export type Situation = "none" | "repair" | "unclear" | "findings" | "protected";

export interface State {
  part: Part;
  run: Run;
  risk: Risk;
  profile: Profile;
  situation: Situation;
}

/** The finished drawing: the whole workflow, medium risk, standard profile. */
export const initial: State = { part: "all", run: "steps", risk: "medium", profile: "standard", situation: "none" };

/** The switches of the map, in the order they are shown. */
export const switches = [
  { name: "part", legend: "part", options: [["all", "both"], ["planning", "planning"], ["feature", "feature"]] },
  { name: "run", legend: "run", options: [["steps", "step by step"], ["unattended", "unattended"]] },
  { name: "risk", legend: "risk", options: [["low", "low"], ["medium", "medium"], ["high", "high"]] },
  { name: "profile", legend: "profile", options: [["standard", "standard"], ["light", "light"]] },
  {
    name: "situation",
    legend: "situation",
    options: [["none", "all paths"], ["unclear", "unclear Issue"], ["repair", "checks fail"], ["findings", "findings"], ["protected", "protected path"]],
  },
] as const;

/** Reads a state from the values of the switches; anything unknown is the initial value. */
export function stateOf(values: Record<string, string | undefined>): State {
  const pick = <K extends keyof State>(name: K): State[K] => {
    const known = switches.find((s) => s.name === name)!.options.map(([value]) => value as string);
    const value = values[name];
    return (value !== undefined && known.includes(value) ? value : initial[name]) as State[K];
  };
  return { part: pick("part"), run: pick("run"), risk: pick("risk"), profile: pick("profile"), situation: pick("situation") };
}

/** The provider and model of each role, per risk level ("" is the plain line). */
export type Models = Record<string, Record<string, string>>;

/** Parses .agents/agents.conf: "<role>: <provider> <model>" and "<role>@<level>: ...". */
export function parseAgents(text: string): Models {
  const models: Models = {};
  for (const line of text.split("\n")) {
    const match = /^([a-z-]+)(?:@(low|medium|high))?:\s*(\S+)\s+(\S+)\s*$/.exec(line.trim());
    if (!match) continue;
    const [, role, level = "", provider, model] = match;
    (models[role] ??= {})[level] = `${provider} ${model}`;
  }
  return models;
}

/** The agent of a role at a level: the line of the level, otherwise the plain line. */
export function agent(models: Models, role: string, level: Risk): string {
  const lines = models[role] ?? {};
  return lines[level] ?? lines[""] ?? role;
}

export interface Step {
  /** The element of the map and the words list that this step reaches. */
  key: string;
  /** The elements that are on the route once this step is reached. */
  lights: string[];
  /** What happens, for the caption. */
  text: string;
}

export interface View {
  /** Elements drawn off the route in this state. */
  off: string[];
  /** Conditional branches that this state takes. */
  taken: string[];
  /** Elements not shown in this state (the other shape of a station, a note). */
  hidden: string[];
  /** Stations drawn as an owner gate in this state, of those whose shape changes. */
  gates: string[];
  /** The text of every label that changes with the state. */
  labels: Record<string, string>;
  caption: { lead: string; text: string };
  /** The walkthrough of this state, in order. */
  walk: Step[];
}

/** The stations of each line, in the order of the route. */
export const planning = ["p-idea", "p-req", "p-approve-req", "p-plan", "p-review", "p-approve", "p-merge"];
export const feature = ["f-issue", "f-implement", "f-checks", "f-review", "f-findings", "f-commit", "f-pr", "f-merge"];

/** The segments of the route that lead to each station, on its usual path. */
const into: Record<string, string[]> = {
  "p-idea": [],
  "p-req": ["s-p-req"],
  "p-approve-req": ["s-p-approve-req"],
  "p-plan": ["s-p-plan"],
  "p-review": ["s-p-review"],
  "p-approve": ["s-p-approve"],
  "p-merge": ["s-p-merge"],
  "f-issue": ["s-f-issue"],
  "f-implement": ["s-f-implement"],
  "f-checks": ["s-f-checks"],
  "f-review": ["s-f-out", "s-f-review"],
  "f-findings": ["s-f-findings"],
  "f-commit": ["s-f-in", "s-f-commit"],
  "f-pr": ["s-f-pr"],
  "f-merge": ["s-f-merge"],
};

/** Every element the walkthrough moves along. */
export const route = [
  ...Object.keys(into),
  ...Object.values(into).flat(),
  "b-revise", "b-clarify", "f-answer", "b-repair", "b-fix", "b-bypass",
];

const levelName = { low: "Low", medium: "Medium", high: "High" } as const;

export function describe(state: State, models: Models): View {
  const { part, run, risk, profile, situation } = state;
  const unattended = run === "unattended";
  const noReview = risk === "low" && profile === "light";
  const lightTriage = profile === "light" && risk !== "high";
  const implementer = agent(models, "implementer", risk);
  const reviewer = agent(models, "reviewer", risk);
  const triage = agent(models, "triage", risk);
  const approval = noReview || situation === "protected";

  const off = new Set<string>();
  const taken = new Set<string>();
  const hidden = new Set<string>();

  const planningKeys = ["t-planning", ...planning, "s-p-req", "s-p-approve-req", "s-p-plan", "s-p-review", "s-p-approve", "s-p-merge", "s-f-issue", "b-revise"];
  const featureKeys = [
    "t-feature", ...feature, "s-f-implement", "s-f-checks", "s-f-out", "s-f-review", "s-f-findings", "s-f-in", "s-f-commit", "s-f-pr", "s-f-merge",
    "b-clarify", "f-answer", "b-repair", "b-fix", "b-bypass",
  ];
  if (part === "feature") {
    planningKeys.forEach((key) => off.add(key));
    hidden.add("w-planning");
  }
  if (part === "planning") {
    featureKeys.forEach((key) => off.add(key));
    hidden.add("w-feature");
  }

  // The review and its triage, and the bypass that only low risk under a
  // policy with low: review: none takes.
  if (noReview) {
    ["s-f-review", "f-review", "s-f-findings", "f-findings", "s-f-in", "b-fix"].forEach((key) => off.add(key));
    hidden.add("w-f-review").add("w-f-findings");
    taken.add("b-bypass");
  } else {
    hidden.add("b-bypass").add("n-bypass");
  }
  // Step by step you approve the triage (a diamond); unattended an agent does (a ring).
  hidden.add(unattended ? "f-findings-gate" : "f-findings-ring");
  if (!unattended) hidden.add("n-unattended");
  if (!approval) hidden.add("f-merge-approval");

  if (part !== "planning") {
    if (situation === "unclear") {
      taken.add("b-clarify");
      ["s-f-checks", "f-checks", "s-f-out", "s-f-review", "f-review", "s-f-findings", "f-findings", "s-f-in", "s-f-commit", "f-commit",
        "s-f-pr", "f-pr", "s-f-merge", "f-merge", "b-repair", "b-fix", "b-bypass"].forEach((key) => off.add(key));
      taken.delete("b-bypass");
    }
    if (situation === "repair") taken.add("b-repair");
    if (situation === "findings" && !noReview) taken.add("b-fix");
  }
  if (situation !== "unclear") hidden.add("n-stop");

  const triageMode = lightTriage ? "light triage" : "full triage";
  const labels: Record<string, string> = {
    "f-implement.sub": implementer,
    "f-review.sub": noReview ? "not reviewed" : reviewer,
    "f-findings.sub": noReview ? "no triage" : unattended ? `${triageMode}, an agent` : `${triageMode}, you approve`,
    "f-commit.sub": noReview ? "not reviewed" : "completion gate",
    "f-merge.sub": "by you",
    "p-review.sub2": agent(models, "planning-reviewer", "medium"),
    "p-req.sub2": agent(models, "project-grill", "medium"),

    "w-f-implement.cond": [
      "If the Issue leaves a decision open that matters, the implementer changes nothing, writes its questions in the handoff note and stops; nothing is reviewed or committed until you answer.",
      unattended ? "The run stops with status 3; answer in the note or in a comment on the Issue and run the feature again." : "Answer in the note or in a comment on the Issue, then resume with start-feature.sh <issue> --resume.",
    ].join(" "),
    "w-f-checks.cond": [
      `If a check fails, the implementer repairs it and the checks run again${unattended ? " (at most three repairs in a run)" : ""}.`,
      noReview ? "Low risk with low: review: none goes from here to the commit, without a reviewer or a triage; a repair that makes the feature medium sends it to the review after all." : "",
    ].filter(Boolean).join(" "),
    "w-f-review.cond": `Another provider than the implementer, read-only: every acceptance criterion against the code and the tests, and the impact on the architecture.${risk === "high" ? " A high-risk feature is always reviewed, under every profile." : ""}`,
    "w-f-findings.cond": [
      "Per finding: fix now, defer to a follow-up Issue, or accept with a reason; critical and major findings are always fixed.",
      lightTriage ? "The light triage prefers to defer or accept suggestions and minor findings over a fix round." : "",
      unattended ? `The triage agent (${triage}) decides without you; read its decisions on the Issue afterwards.` : "You approve the decisions, which are published on the Issue.",
      "Findings to fix are fixed, checked and reviewed again: the changes, then the complete feature.",
    ].filter(Boolean).join(" "),
    "w-f-commit.cond": noReview
      ? "Records Review: not reviewed: Low risk by project policy. Refused unless the completion record says complete or awaiting evidence and the verification passed for this content."
      : "Refused unless the completion record says complete or awaiting evidence, the verification passed for this content, and the latest review is current, covers the complete feature and has no critical or major finding.",
    "w-f-merge.cond": noReview
      ? "Nobody rated the impact on the architecture, so the merge needs your approval. No script merges."
      : situation === "protected"
        ? "A protected path changed, so the merge needs your approval; the commit carries an approval request that names the content tree. No script merges."
        : "Your approval is needed when a protected path changed or the reviewer rated the impact on the architecture major or breaking. No script merges.",
  };

  // The caption: what this state shows, in two or three sentences.
  let lead: string;
  const text: string[] = [];
  if (part === "planning") {
    lead = "Project planning.";
    text.push(
      "Once at the start, and again for each change of the plan: requirements that you approve, a plan, an independent review, your approval and your merge.",
      "The risk level, the profile and the way of running apply to features.",
    );
  } else {
    const level = part === "feature" ? `Feature execution, ${risk}` : levelName[risk];
    lead = `${level} risk, ${profile} profile${unattended ? ", unattended" : ""}.`;
    if (noReview) text.push("No review by policy (low: review: none, which the light profile sets): the commit says not reviewed, and the merge needs your approval.");
    else if (risk === "low") text.push("Reviewed like any other feature: the standard profile has no low: review: none. As shipped no path is low; a project adds a low class in risk.conf.");
    else if (risk === "high") text.push(`The implementer is ${implementer}; the review and the full triage always apply, whatever the profile.`);
    else if (lightTriage) text.push(`Reviewed by ${reviewer}; the light triage prefers to defer or accept suggestions and minor findings over another fix round.`);
    else text.push(`The implementer is ${implementer} and the reviewer ${reviewer}, an agent of another provider; the findings get the full triage.`);
    text.push(
      unattended
        ? "run-feature.sh runs from the implementation to the pull request, and the triage agent decides about the findings without you. It never merges."
        : noReview
          ? "You run each script."
          : "You run each script and approve the triage of every review with findings.",
    );
    if (situation === "unclear") text.push("Here the Issue leaves a decision open: implementation stops with a question, and nothing goes on until you answer.");
    if (situation === "repair") text.push("Here a check fails: the implementer repairs it before anything is reviewed.");
    if (situation === "findings") text.push(noReview ? "Without a review there are no findings to triage." : "Here the review finds something to fix: the fix is checked and reviewed again.");
    if (situation === "protected") text.push("Here a protected path changed: whatever the review says, the merge needs your approval.");
  }

  return {
    off: [...off],
    taken: [...taken],
    hidden: [...hidden],
    gates: unattended ? [] : ["f-findings"],
    labels,
    caption: { lead, text: text.join(" ") },
    walk: walk(state, models),
  };
}

function walk(state: State, models: Models): Step[] {
  const { part, run, risk, profile, situation } = state;
  const unattended = run === "unattended";
  const noReview = risk === "low" && profile === "light";
  const steps: Step[] = [];
  const reach = (key: string, text: string, lights = into[key] ?? []) => steps.push({ key, lights: [...lights, key], text });

  if (part !== "feature") {
    reach("p-idea", "You describe the project in your own words, in docs/PROJECT_DESCRIPTION.md.");
    reach("p-req", `start-planning.sh: Project Grill (${agent(models, "project-grill", "medium")}) asks about the goals, the users, the scope and the constraints, and drafts the requirements.`);
    reach("p-approve-req", "You approve the requirements; the planning goes on only after that.");
    reach("p-plan", `A fresh planning session (${agent(models, "project-planner", "medium")}) writes the architecture, the roadmap and the necessary ADRs.`);
    reach("p-review", `review-planning.sh: ${agent(models, "planning-reviewer", "medium")} reviews the plan, read-only. With findings, revise-planning.sh proposes a decision per finding, you approve them, and the plan is reviewed again.`);
    reach("p-approve", "finish-planning.sh records your approval with a fingerprint of the requirements and the roadmap; a later change to them makes it stale.");
    reach("p-merge", "You merge the planning pull request. Features start from that plan.");
  }
  if (part === "planning") return steps;

  const implementer = agent(models, "implementer", risk);
  reach("f-issue", "create-feature-issue.sh turns a roadmap feature into a GitHub Issue; it refuses while the approval of the plan is stale.", part === "all" ? ["s-f-issue"] : []);
  reach(
    "f-implement",
    `${unattended ? "run-feature.sh starts" : "start-feature.sh creates the branch and the worktree and starts"} the implementer (${implementer}). It first decides whether the Issue is clear, then writes the code and the tests and records how far the Issue is done.`,
  );
  if (situation === "unclear") {
    reach("b-clarify", `The Issue leaves a decision open that matters: the implementer changes nothing, writes its questions in the handoff note and stops. ${unattended ? "run-feature.sh stops with status 3." : "The session ends blocked."} Nothing is reviewed or committed.`, []);
    reach("f-answer", `You answer, in the handoff note or in a comment on the Issue, and ${unattended ? "run run-feature.sh <issue> again" : "resume with start-feature.sh <issue> --resume"}.`, ["b-clarify"]);
    reach("f-implement", "The next session reads your answers and implements; it asks again only about a decision the answers left open.", ["b-clarify", "f-answer"]);
  }
  reach("f-checks", "verify.sh runs the checks of scripts/verify.conf; the pass is recorded for exactly this content.");
  if (situation === "repair") {
    reach("b-repair", `A check fails. The implementer repairs it${unattended ? "; the run resumes it with the failing checks, at most three times" : ""}.`, []);
    reach("f-checks", "The checks run again and pass. Nothing is reviewed before they do.", ["b-repair"]);
  }
  if (noReview) {
    reach("f-commit", "Low risk with low: review: none: no reviewer and no triage. finish-feature.sh commits with Review: not reviewed: Low risk by project policy.", ["s-f-out", "b-bypass", "s-f-commit"]);
  } else {
    const reviewer = agent(models, "reviewer", risk);
    const lightTriage = profile === "light" && risk !== "high";
    reach("f-review", `review-feature.sh: ${reviewer}, another provider than the implementer and read-only, checks every acceptance criterion and rates the impact on the architecture.`);
    reach(
      "f-findings",
      `${unattended ? `The triage agent (${agent(models, "triage", risk)}) decides` : "triage-review.sh proposes, and you approve,"} per finding: fix now, defer or accept${lightTriage ? ", with the light triage" : ""}. The decisions are published on the Issue.`,
    );
    if (situation === "findings") {
      reach("b-fix", "apply-triage.sh: the implementer fixes the findings to fix now.", []);
      reach("f-checks", "The checks run again on the fixes.", ["b-fix"]);
      reach("f-review", "The review again: the changes, then the complete feature. No finding is left to fix.", ["s-f-out", "s-f-review"]);
      reach("f-findings", "The last round leaves nothing to fix.", ["s-f-findings"]);
    }
    reach("f-commit", "finish-feature.sh commits, with the completion, the verification, the review and the risk level recorded.", ["s-f-in", "s-f-commit"]);
  }
  reach("f-pr", "publish-feature.sh pushes the branch and opens the pull request with the evidence; CI runs the checks again.");
  reach(
    "f-merge",
    noReview
      ? "You merge. Nobody rated the impact on the architecture, so the merge needs your approval."
      : situation === "protected"
        ? "You merge. A protected path changed, so the merge needs your approval; check-guardrails.sh names it."
        : "You merge, by your repository's rules. Your approval is needed for a protected path or a major impact on the architecture.",
  );
  return steps;
}

/**
 * The state classes of an element of the map or the words list. With `lit`,
 * the walkthrough is on and an element of the route that it has not reached
 * yet is ahead.
 */
export function classesOf(view: View, key: string, lit?: Set<string>): Record<string, boolean> {
  return {
    "is-off": view.off.includes(key),
    "is-taken": view.taken.includes(key),
    "is-hidden": view.hidden.includes(key),
    "is-ahead": lit !== undefined && route.includes(key) && !lit.has(key),
    you: view.gates.includes(key),
  };
}
