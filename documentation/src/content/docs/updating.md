---
title: "Updating an existing project"
description: "Take over template changes while keeping your project settings."
order: 8
---

## Update an existing project

A repository created from the template does not receive later improvements of the workflow. To bring them over, run this from your repository, with no uncommitted changes:

```
./scripts/sync-template.sh
```

It updates only the files that belong to the template, and never commits or pushes. On `main` it first creates a branch; on another branch it works there, so start from `main` to keep the update apart from other work. Your code, your plan, and your own checks are not touched. <a href="../updating/#sync">More about updates</a>.

<a id="sync"></a>

## Keeping a project up to date

A repository created from the template does not receive the template's later improvements. `./scripts/sync-template.sh` brings them over:

- It touches only the files listed under `paths:` in [`.agents/template.conf`](https://github.com/taspinar/agentic-coding-template/blob/main/.agents/template.conf): the workflow scripts, prompts, policies, schemas, the CI and guardrails workflows, and the workflow documentation. Your code, your requirements, your roadmap, and your `scripts/verify.conf` stay yours.
- A file you did not change is replaced. A file both sides changed is merged, and a conflict is left in the file and reported. A file the template removed is reported, never deleted.
- To keep a listed file as your own, add `:(exclude)<path>` to the list.
- The script never commits or pushes: you review the result and open a pull request.

What each file in the repository is for is in the [project map](https://github.com/taspinar/agentic-coding-template/blob/main/docs/project-map.md).

## Versions and conflicts

Work on a branch and inspect the listed template commits. `--from <commit>` chooses a known starting version, `--to <ref>` a target, and `--template <url-or-path>` another source. Without a recorded version, the script compares files to historical template versions; an ambiguous match stops for your `--from` choice, with the oldest the safe choice. It records the new version in `.agents/template.conf`.

A conflict exits with status 1 and leaves the conflict for you to resolve. Files removed upstream are reported, never deleted automatically. Newly owned files are copied only when absent or safely matched; local content is protected. Review the result, resolve conflicts, run `./scripts/verify.sh --all`, commit and open a pull request. The script never commits or pushes. `LICENSE` stays yours.

See [Taking over template changes](https://github.com/taspinar/agentic-coding-template/blob/main/docs/development.md#taking-over-template-changes) for the full merge table and version-selection rules.
