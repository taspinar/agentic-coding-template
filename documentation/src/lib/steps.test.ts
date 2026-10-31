// Tests of the step detail of the workflow map against the steps of "Every
// step in detail", which both show. Run by check.sh --build:
//   node --test "src/**/*.test.ts"  (in documentation/)
import { test } from "node:test";
import assert from "node:assert/strict";
import { details, feature, fields, planning, stations, tabs } from "./steps.ts";
import { feature as featureLine, planning as planningLine } from "./workflow.ts";

test("every station of the map opens a detail, and every step it names exists", () => {
  assert.deepEqual(Object.keys(stations).sort(), [...planningLine, ...featureLine].sort());
  for (const key of Object.keys(stations)) assert.ok(details(key), key);
  assert.equal(details("t-planning"), undefined, "a stage title is not a station");
});

test("the detail keeps every fact of its steps, each in exactly one field, in the fixed order of each tab", () => {
  for (const key of Object.keys(stations)) {
    const detail = details(key)!;
    const steps = [...planning, ...feature].filter((step) => stations[key].includes(step.id));
    const shown = detail.tabs.flatMap((tab) => tab.rows.flatMap((row) => row.facts.map((fact) => `${fact.label}: ${fact.value}`)));
    assert.deepEqual(shown.sort(), steps.flatMap((step) => step.facts.map(([term, value]) => `${term}: ${value}`)).sort(), key);
    for (const tab of detail.tabs) {
      const order = tab.rows.map((row) => fields.findIndex(([, label]) => label === row.label));
      assert.deepEqual(order, [...order].sort((a, b) => a - b), `${key} ${tab.id}`);
    }
    assert.deepEqual(detail.summaries, steps.map((step) => step.text), key);
  }
});

test("the tabs: who acts and the decision; the command and what goes in and out; the stops", () => {
  assert.deepEqual(tabs.map((tab) => tab.name), ["Overview", "Technical", "Failure states"]);
  const review = details("f-review")!;
  const rows = (id: string) => review.tabs.find((tab) => tab.id === id)!.rows;
  assert.deepEqual(rows("overview").map((row) => row.label), ["Who acts"]);
  assert.deepEqual(rows("technical").map((row) => row.label), ["Command", "Inputs and outputs"]);
  assert.deepEqual(rows("failure").map((row) => row.label), ["Stops, retries and exceptions"]);
  assert.deepEqual(rows("failure")[0].facts.map((fact) => fact.label), ["refused if", "refused if"]);
  assert.equal(rows("technical")[0].facts[0].shown, false, "a single command needs no sub-label");
  assert.equal(rows("technical")[1].facts[0].shown, true, "inputs and outputs keep their label");
});

test("a station with two steps shows both, titled by the first", () => {
  const findings = details("f-findings")!;
  assert.equal(findings.title, "Decide on the findings");
  assert.deepEqual(findings.steps.map((step) => step.id), ["decide-on-the-findings", "apply-the-fixes"]);
  const gate = findings.tabs[0].rows.find((row) => row.label === "Gate or decision")!;
  assert.deepEqual(gate.facts.map((fact) => fact.label), ["your decision", "next"]);
});
