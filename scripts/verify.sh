#!/usr/bin/env bash
set -euo pipefail

echo "== Agentic project verification =="
# Keep this script as the stable interface. Replace/extend detection for your stack.
if [[ -f package.json ]]; then
  command -v npm >/dev/null || { echo "npm is required"; exit 1; }
  [[ -d node_modules ]] || npm ci
  npm run lint --if-present
  npm run type-check --if-present
  npm test --if-present
  npm run build --if-present
elif [[ -f pyproject.toml ]]; then
  command -v python >/dev/null || { echo "python is required"; exit 1; }
  command -v ruff >/dev/null && ruff check . || true
  command -v pytest >/dev/null && pytest || true
else
  echo "No stack-specific verifier configured yet; checking template structure."
  test -f AGENTS.md
  test -f docs/architecture.md
  test -f .agents/prompts/reviewer.md
fi

echo "Checking shell scripts."
shell_files=(scripts/*.sh tests/*.sh)
for shell_file in "${shell_files[@]}"; do
  [[ -f "$shell_file" ]] || continue
  bash -n "$shell_file"
done

if [[ -x tests/triage-review-test.sh ]]; then
  ./tests/triage-review-test.sh
fi

if [[ -x tests/apply-triage-test.sh && "${APPLY_TRIAGE_TEST_ACTIVE:-0}" != "1" ]]; then
  ./tests/apply-triage-test.sh
fi

if [[ -x tests/start-planning-test.sh && "${APPLY_TRIAGE_TEST_ACTIVE:-0}" != "1" ]]; then
  ./tests/start-planning-test.sh
fi

echo "Verification completed. Customize scripts/verify.sh for this project's stack."
