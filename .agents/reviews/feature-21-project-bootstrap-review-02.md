# Independent Re-review — feature/21-project-bootstrap

Issue: #21
Base: `origin/main` (`3f2c9b896f4e23b7ed5c250f51646398e8582886`)
Prior review: `.agents/reviews/feature-21-project-bootstrap-review-01.md`

## Prior finding verification

- M1 resolved: both phases now require HEAD to remain at the worktree base and scope checks compare against that base.
- M2 resolved: approved requirements are checked by file type, mode, and content signature.
- M3 resolved: the approval temporary file is created beside the requirements artifact and renamed in place.
- M4 resolved: required headings must occur exactly once and required sections must contain permitted content.
- M5 resolved: architecture and roadmap must each differ from the base and known template markers are rejected.
- M6 resolved: the bare test remote is initialized with `main`; the expanded planning suite passes with system and global Git configuration disabled.
- M7 resolved: the expanded suite exercises the previously missing dispatch, validation, failure, commit, scope, duplicate-resource, and artifact-integrity paths.
- Minor 1 resolved: post-creation failures consistently report the preserved worktree and an inspection/continuation action.
- Minor 2 resolved: model identifiers now use a conservative provider-neutral syntax.

## Critical

None.

## Major

### M1. Phase scope checks ignore untracked files matched by `.gitignore`

`changed_paths_since_base` at `scripts/start-planning.sh:134-139` combines the tracked diff with `git ls-files --others --exclude-standard`. `--exclude-standard` deliberately omits ignored files. Consequently either write-capable phase can create or modify untracked ignored content such as `.env`, `credentials.json`, `service-account.json`, `*.pem`, `*.key`, or files under build/cache directories without appearing in the scope result. The workflow can then report success despite files outside the phase allowlist, including potentially sensitive artifacts.

This violates the Grill's single-file boundary and the planner's planning-artifact-only boundary.

Recommended action: snapshot all pre-existing files in the fresh worktree and compare the filesystem after each phase, including ignored paths, while excluding only explicitly understood tool metadata if necessary. Add Grill and planner cases that create ignored files such as `.env` and verify rejection and worktree preservation.

### M2. Required planner artifacts can be directories or symlinks

`scripts/start-planning.sh:398-414` validates architecture and roadmap with `[[ -s path ]]`, `git diff --quiet`, and `grep`. Bash `-s` is true for ordinary nonempty directory entries on macOS, and it follows symlinks. If a planner replaces `docs/architecture.md` with an empty directory, the deletion differs from the base, `-s` succeeds, and `grep`'s directory error occurs inside an `if` condition and does not fail the script. A symlink to any nonempty external file also passes when it lacks the template marker. The same applies to `docs/roadmap.md`.

The workflow can therefore succeed without producing the required in-worktree Markdown files, and a symlink weakens the intended worktree boundary.

Recommended action: require each artifact to be a nonempty regular non-symlink file before diff or content checks. Add directory and symlink integration cases for both required artifacts.

### M3. The ADR allowlist accepts arbitrary files and nested content

The planner allowlist at `scripts/start-planning.sh:383-390` accepts every path beginning with `docs/decisions/`. Issue #21 and the plan permit necessary `docs/decisions/*.md` planning artifacts, but this check also accepts scripts, binaries, credentials, and arbitrarily nested files under that directory.

This leaves a direct bypass in the scope enforcement added to protect the project-planner boundary.

Recommended action: allow only direct Markdown files matching `docs/decisions/*.md`, require them to be regular non-symlink files, and decide explicitly whether the existing `docs/decisions/README.md` may change. Add rejected non-Markdown and nested-path cases.

## Minor

### Minor 1. Expanded failure tests do not verify actionable diagnostics

Most negative cases in `tests/start-planning-test.sh:462-581` redirect all output to `/dev/null` and assert only a nonzero result. They do not verify the specific error, selected phase/agent/model, preserved worktree guidance, or whether pre-creation failures avoided creating both branch and path. A generic early failure could satisfy several cases while regressing Issue #21's actionable-error requirement.

Recommended action: capture output for each safety class and assert the identifying diagnostic and relevant branch/worktree postconditions.

### Minor 2. A dangling symlink bypasses the target-path precheck

`scripts/start-planning.sh:70-72` checks the target with `[[ -e "$worktree" ]]`. Bash `-e` is false for a dangling symlink, so such a pre-existing directory entry reaches `git worktree add` rather than producing the intended explicit duplicate-path rejection.

Recommended action: reject `[[ -e "$worktree" || -L "$worktree" ]]` and add a dangling-symlink test.

## Suggestions

None.

## Verdict

CHANGES REQUIRED
