---
title: "GitHub setup"
description: "Configure the settings that enforce pull requests, checks and owner review."
order: 7
---

<a id="github"></a>

## What GitHub has to enforce

The gate is a check and a statement. `check-guardrails.sh` checks locally; the Guardrails job (`pull_request_target`, `--fail-on-protected`) signals protected changes, rather than serving as the required CI check. The commit and pull request carry a “Merge approval: required” statement. It tells you which pull requests need your attention, and the workflow's own scripts will not merge them. It does **not** stop someone, or an agent with your credentials, from merging on GitHub. To enforce the rules, configure the repository:

- **A ruleset for `main`** that requires a pull request and the CI check before a merge. `./scripts/doctor.sh` warns you when the check is not required. The [repository setup guide](https://github.com/taspinar/agentic-coding-template/blob/main/docs/repository-setup.md) lists the settings.
- **`.github/CODEOWNERS`** ships with the placeholder `@YOUR_GITHUB_USERNAME`. Replace it with your own account before you require code owner reviews; until then the file has no effect.
- **Bypass rights:** a repository administrator can usually bypass a ruleset. Decide whether that should apply to you.

The complete list of settings is the [repository setup checklist](https://github.com/taspinar/agentic-coding-template/blob/main/docs/repository-setup.md). What to keep out of a repository, and how to report a security problem, is in [`SECURITY.md`](https://github.com/taspinar/agentic-coding-template/blob/main/SECURITY.md).

**One identity:** an agent runs with the GitHub permissions of the account that started it. If that account may merge, so may the agent, and no script can prevent it. A separate GitHub identity with limited permissions for agents is not built yet ([Issue 99](https://github.com/taspinar/agentic-coding-template/issues/99)).

## Repository setup checklist

Enable Issues and GitHub Actions. Prefer squash merging, disable merge and rebase commits, and automatically delete merged branches. For `main`, block force pushes and deletion and require pull requests. After the first CI run, require the actual `verify` check; do not require a check no workflow produces. Keep Actions permissions read-only by default and grant write permissions only to jobs that need them.

Replace `@YOUR_GITHUB_USERNAME` in `.github/CODEOWNERS`. In a team require code-owner reviews; a solo owner cannot approve their own pull request, so leave that requirement off and inspect the workflow's merge approval statement. Configure bypass rights deliberately. Separate agent identity remains open work ([#99](https://github.com/taspinar/agentic-coding-template/issues/99)).

Enable dependency alerts, secret scanning and push protection where available. Keep secrets out of Git. For production, use environment approvals and short-lived identity federation where supported; production data and infrastructure changes need explicit human approval.

The [repository setup guide](https://github.com/taspinar/agentic-coding-template/blob/main/docs/repository-setup.md) is the full checklist, including optional Google Cloud, database and deployment controls. Only the template repository itself needs the “Template repository” setting.
