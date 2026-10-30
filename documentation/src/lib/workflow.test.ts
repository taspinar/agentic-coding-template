// Tests of the states of the workflow map against the rules of
// docs/development.md that each state draws. Run by check.sh --build:
//   node --test "src/**/*.test.ts"  (in documentation/)
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { agent, describe, initial, parseAgents, route, stateOf, switches, type State } from "./workflow.ts";

const models = parseAgents(readFileSync(new URL("../../../.agents/agents.conf", import.meta.url), "utf8"));
const view = (change: Partial<State>) => describe({ ...initial, ...change }, models);
const keys = (state: Partial<State>) => view(state).walk.map((step) => step.key);

test("the initial state is the complete drawing: nothing off, no branch taken, no bypass", () => {
  const v = view({});
  assert.deepEqual(v.off, []);
  assert.deepEqual(v.taken, []);
  assert.ok(v.hidden.includes("b-bypass"));
  assert.ok(v.hidden.includes("f-merge-approval"), "the approval flag shows only when it is required");
  assert.match(v.caption.lead, /^Medium risk, standard profile\.$/);
});

test("low risk skips the review only under a policy with low: review: none (light)", () => {
  const light = view({ risk: "low", profile: "light" });
  for (const key of ["f-review", "f-findings", "s-f-review", "s-f-findings"]) assert.ok(light.off.includes(key), key);
  assert.ok(light.taken.includes("b-bypass"));
  assert.ok(light.hidden.includes("w-f-review") && light.hidden.includes("w-f-findings"));
  assert.ok(!light.hidden.includes("f-merge-approval"), "without a review the merge needs the owner's approval");
  assert.ok(!keys({ risk: "low", profile: "light" }).includes("f-review"));

  const standard = view({ risk: "low", profile: "standard" });
  assert.ok(!standard.off.includes("f-review"));
  assert.ok(keys({ risk: "low" }).includes("f-review"));
  assert.ok(standard.hidden.includes("f-merge-approval"));
});

test("high risk is never lighter: reviewed and fully triaged under every profile", () => {
  for (const profile of ["standard", "light"] as const) {
    const v = view({ risk: "high", profile });
    assert.ok(!v.off.includes("f-review"), profile);
    assert.match(v.labels["f-findings.sub"], /^full triage/, profile);
  }
  assert.match(view({ risk: "medium", profile: "light" }).labels["f-findings.sub"], /^light triage/);
  assert.match(view({ risk: "low", profile: "light" }).labels["f-findings.sub"], /^no triage/);
});

test("the implementer's model follows the risk level of agents.conf", () => {
  assert.equal(view({ risk: "high" }).labels["f-implement.sub"], agent(models, "implementer", "high"));
  assert.equal(view({ risk: "medium" }).labels["f-implement.sub"], agent(models, "implementer", "medium"));
  assert.equal(agent({ implementer: { "": "claude opus", high: "claude fable" } }, "implementer", "low"), "claude opus");
});

test("the shipped reviewer is of another provider than the implementer at every level, as the map says", () => {
  for (const level of ["low", "medium", "high"] as const) {
    const provider = (role: string) => agent(models, role, level).split(" ")[0];
    assert.notEqual(provider("reviewer"), provider("implementer"), level);
  }
});

test("an unclear Issue stops the implementation until the owner answers", () => {
  const v = view({ situation: "unclear" });
  assert.ok(v.taken.includes("b-clarify"));
  for (const key of ["f-checks", "f-review", "f-commit", "f-merge"]) assert.ok(v.off.includes(key), key);
  const walk = keys({ situation: "unclear", part: "feature" });
  assert.deepEqual(walk.slice(0, 5), ["f-issue", "f-implement", "b-clarify", "f-answer", "f-implement"]);
  assert.match(view({ situation: "unclear", run: "unattended" }).labels["w-f-implement.cond"], /status 3/);
});

test("a failed check is repaired before anything is reviewed", () => {
  const walk = keys({ situation: "repair", part: "feature" });
  assert.ok(walk.indexOf("b-repair") > walk.indexOf("f-checks"));
  assert.ok(walk.indexOf("b-repair") < walk.indexOf("f-review"));
  assert.ok(view({ situation: "repair" }).taken.includes("b-repair"));
});

test("findings are fixed, checked and reviewed again; without a review there are none", () => {
  const walk = keys({ situation: "findings", part: "feature" });
  const fix = walk.indexOf("b-fix");
  assert.ok(fix > walk.indexOf("f-findings"));
  assert.deepEqual(walk.slice(fix + 1, fix + 3), ["f-checks", "f-review"]);
  assert.ok(!view({ situation: "findings", risk: "low", profile: "light" }).taken.includes("b-fix"));
});

test("a protected path needs the owner's approval of the merge", () => {
  const v = view({ situation: "protected" });
  assert.ok(!v.hidden.includes("f-merge-approval"));
  assert.match(v.labels["w-f-merge.cond"], /protected path/);
});

test("step by step the owner approves the triage; unattended an agent decides", () => {
  const steps = view({ run: "steps" });
  assert.deepEqual(steps.gates, ["f-findings"]);
  assert.ok(steps.hidden.includes("f-findings-ring"));
  const unattended = view({ run: "unattended" });
  assert.deepEqual(unattended.gates, []);
  assert.ok(unattended.hidden.includes("f-findings-gate"));
  assert.ok(!unattended.hidden.includes("n-unattended"));
});

test("planning and feature execution are each shown alone", () => {
  const planning = view({ part: "planning" });
  assert.ok(planning.off.includes("f-implement") && !planning.off.includes("p-plan"));
  assert.ok(planning.hidden.includes("w-feature"));
  assert.ok(planning.walk.every((step) => step.key.startsWith("p-")));
  const feature = view({ part: "feature" });
  assert.ok(feature.off.includes("p-plan") && !feature.off.includes("f-implement"));
  assert.ok(feature.walk.every((step) => !step.key.startsWith("p-")));
});

test("every state's walkthrough moves only along elements of the map", () => {
  const values = (name: string) => switches.find((s) => s.name === name)!.options.map(([value]) => value);
  for (const part of values("part")) for (const run of values("run")) for (const risk of values("risk"))
    for (const profile of values("profile")) for (const situation of values("situation")) {
      const v = describe(stateOf({ part, run, risk, profile, situation }), models);
      assert.ok(v.walk.length > 0);
      for (const step of v.walk) for (const key of [step.key, ...step.lights]) assert.ok(route.includes(key), `${key} in ${part}/${risk}/${profile}/${situation}`);
      assert.equal(v.walk.at(-1)!.key, part === "planning" ? "p-merge" : "f-merge");
    }
});

test("an unknown switch value falls back to the initial state", () => {
  assert.deepEqual(stateOf({ risk: "extreme", part: "feature" }), { ...initial, part: "feature" });
});
