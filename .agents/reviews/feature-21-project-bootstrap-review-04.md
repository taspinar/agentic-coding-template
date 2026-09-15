# Final Readiness Review — feature/21-project-bootstrap

Issue: #21
Base: `origin/main` (`3f2c9b896f4e23b7ed5c250f51646398e8582886`)
Prior reviews:
- `.agents/reviews/feature-21-project-bootstrap-review-01.md`
- `.agents/reviews/feature-21-project-bootstrap-review-02.md`
- `.agents/reviews/feature-21-project-bootstrap-review-03.md`

## Prior finding verification

- All Critical, Major, and Minor findings from reviews 01 and 02 remain resolved.
- Review 03 M1 is resolved: snapshot input is NUL-delimited, paths are keyed by their Git blob hash and shell-escaped for stable comparison/diagnostics, and both phases reject ignored, tab-containing, and newline-containing paths.
- Review 03 M2 is resolved: architecture and roadmap must be nonempty regular non-symlink files, executable modes are rejected, and content blob hashes—not Git mode diffs—must differ from the base.
- The direct-Markdown ADR allowlist, dangling-path handling, approval integrity, no-commit check, phase ordering, explicit model forwarding/no fallback, and preserved-worktree failures remain enforced.
- `./scripts/verify.sh`, `git diff --check origin/main`, and the planning suite with system/global Git configuration disabled all pass on macOS. The checked Bash constructs and utilities have macOS/GNU Linux-compatible forms, and CI runs the verifier on `ubuntu-latest`.

## Critical

None.

## Major

None.

## Minor

### Minor 1. Optional ADR directory produces a false error on successful runs

The final ADR scan at `scripts/start-planning.sh:467-474` invokes `find "$worktree/docs/decisions"` unconditionally through process substitution. When no `docs/decisions` directory exists, `find` prints `No such file or directory`, but its failure is not propagated by the `while` loop. Both successful provider scenarios in `tests/start-planning-test.sh` currently emit this error because the fixture creates an empty, therefore untracked, directory.

The workflow still returns success and the repository template normally tracks `docs/decisions/README.md`, but an optional no-ADR state should not produce a false failure diagnostic.

Recommended action: guard the scan with `[[ -d "$worktree/docs/decisions" ]]`, while separately rejecting a non-directory entry at that path. Update the happy-path tests to assert clean stderr.

### Minor 2. The mode-only test does not isolate content-hash validation

The `mode-only` fake planner at `tests/start-planning-test.sh:194-195` changes both documents to mode `755`. The script rejects those files at the executable-mode check (`scripts/start-planning.sh:447-449`) before reaching the base/current blob comparison at lines 451-454. The content-vs-mode implementation is correct, but this test would still pass if the content-hash guard regressed.

Recommended action: use a non-executable mode-only change such as `chmod 600` for this scenario, and keep a separate executable-document mode case.

## Suggestions

None.

## Verdict

PASS WITH MINOR FINDINGS
