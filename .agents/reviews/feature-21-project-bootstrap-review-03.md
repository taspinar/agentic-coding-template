# Final Independent Re-review — feature/21-project-bootstrap

Issue: #21
Base: `origin/main` (`3f2c9b896f4e23b7ed5c250f51646398e8582886`)
Prior reviews:
- `.agents/reviews/feature-21-project-bootstrap-review-01.md`
- `.agents/reviews/feature-21-project-bootstrap-review-02.md`

## Prior finding verification

- Review 01 M1–M7 and Minor 1–2 remain resolved.
- Review 02 M1 is resolved: the filesystem snapshot includes tracked, untracked, and ignored entries and the tests reject ignored Grill and planner output.
- Review 02 M2 is resolved: architecture and roadmap must be nonempty regular non-symlink files, with directory and symlink tests.
- Review 02 M3 is resolved: changed ADR paths are limited to direct `.md` children and must be regular non-symlink files; non-Markdown and nested paths are tested.
- Review 02 Minor 1 is resolved: representative safety tests now assert identifying diagnostics, preservation guidance, and branch/path postconditions.
- Review 02 Minor 2 is resolved: both existing paths and dangling symlinks are rejected before branch creation.

## Critical

None.

## Major

### M1. Snapshot serialization allows tab-containing paths to spoof the allowlist

`snapshot_tree` writes records as tab-separated text at `scripts/start-planning.sh:148-166`, and `changed_paths_since_base` parses only `$1` and `$2` with `awk -F '\t'` at `scripts/start-planning.sh:169-191`. Unix filenames may contain tabs. An agent can therefore create an out-of-scope file named, for example, `docs/PROJECT_REQUIREMENTS.md<TAB>extra`; the parser reports only `docs/PROJECT_REQUIREMENTS.md`, which the Grill allowlist accepts. The planner can similarly spoof `docs/architecture.md`, `docs/roadmap.md`, or a permitted ADR path. Newlines in filenames also corrupt the line-oriented `find`/`read` format.

This reopens the phase-scope bypass that the filesystem snapshot was intended to close.

Recommended action: serialize paths and signatures with a filename-safe format, such as NUL-delimited records with compatible parsing, or encode paths reversibly before comparison. Add tab- and newline-containing out-of-scope filename cases for both phases.

### M2. Mode-only changes satisfy required architecture and roadmap updates

`scripts/start-planning.sh:457-462` uses `git diff --quiet` to decide whether each required artifact changed. Git treats a mode-only change as a diff. In an `architecture-refresh` run against already populated, non-template documents, a planner that only runs `chmod` on both files passes the regular-file, diff, and placeholder checks and the workflow reports successful project planning without changing either artifact's content.

Issue #21 requires the planning session to produce or refine architecture and roadmap content from the approved requirements; executable-bit changes are not planning output.

Recommended action: compare the content blob of each artifact with its base version independently from mode, require a content change, and enforce the intended non-executable documentation mode. Add a populated-base case where the planner changes only modes.

## Minor

None.

## Suggestions

None.

## Verdict

CHANGES REQUIRED
