# Execution Limits

Stop and escalate when:
- a major architecture change or accepted ADR violation appears necessary;
- requirements materially conflict or cannot be inferred safely;
- production access/destructive action is required;
- the task is expanding beyond its issue/plan;
- three materially different repair attempts fail;
- changes unexpectedly span many unrelated components.

Do not repeatedly retry the same approach or refactor unrelated code to make a local task pass.
