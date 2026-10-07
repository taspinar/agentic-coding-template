# Recovery Policy

On failure: inspect the diff and evidence, preserve useful diagnostics, revert only the smallest failing change when possible, and return to a known-good commit if necessary. Never force-push a shared branch as a recovery shortcut. After repeated failure, update the handoff note of the Issue (`.agents/handoffs/<issue-number>.md`) with attempts, evidence, current state, and the exact next recommended action.
