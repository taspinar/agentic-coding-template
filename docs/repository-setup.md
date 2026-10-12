# Repository Setup

This document lists the GitHub repository settings that should be
configured for every new project created from this template.

These settings are intentionally not all encoded in repository files,
because some GitHub settings and rulesets are not inherited
automatically when creating a new repository from a template.

**What GitHub enforces, and what the scripts only detect.** The workflow
scripts check and report: `check-guardrails.sh` flags a change that needs
the owner, `doctor.sh` warns when `main` has no required check, and no
script of the workflow merges a pull request. None of that stops a person,
or an agent that runs with your GitHub permissions, from merging. Only the
settings below do: a ruleset for `main`, a required status check, and, in a
team, required reviews.

How the workflow itself runs is not described here: the steps are in
[`docs/workflow.md`](workflow.md) and the commands in
[`docs/development.md`](development.md).

A new repository also holds the website of the template itself. Delete
`documentation/` and `.github/workflows/pages.yml`: they are not part of
your project.

------------------------------------------------------------------------

## 1. General repository settings

### Features

Enable:

-   Issues

Optional:

-   Projects

Disable unless explicitly needed:

-   Wiki
-   Discussions

------------------------------------------------------------------------

## 2. Pull Request settings

Go to:

**Settings → General → Pull Requests**

Recommended configuration:

-   Enable **Allow squash merging**
-   Disable **Allow merge commits**
-   Disable **Allow rebase merging**
-   Enable **Automatically delete head branches**

Why:

Feature branches may contain multiple implementation and review-fix
commits, while `main` stays clean with one logical commit per merged
feature.

Example:

``` text
feature/12-authentication

- implementation
- fix tests
- address reviewer findings
- fix edge case
```

After squash merge:

``` text
main

- Feature #12: authentication
```

------------------------------------------------------------------------

## 3. Protect the default branch

Go to:

**Settings → Rules → Rulesets → New branch ruleset**

Recommended name:

`Protect main`

Target:

-   Default branch

Enable:

-   Restrict deletions
-   Block force pushes
-   Require a pull request before merging

Do not require human approvals by default for single-developer projects.

Human approval can be added later for:

-   team projects
-   production-critical repositories
-   regulated environments
-   high-risk production deployments

### Code owners

`.github/CODEOWNERS` lists the paths that need the owner: the rules for
agents, the policies, the CI workflows, and the decision records. It ships
with the placeholder `@YOUR_GITHUB_USERNAME`. Replace it with your account,
or with a team; until then the file names nobody and has no effect.

The file takes effect only when the ruleset of `main` requires a review from
code owners. For one developer that would mean approving your own pull
requests, which GitHub does not allow, so leave that setting off and rely on
the merge approval gate of the workflow, which flags these paths in the
commit message and the pull request. In a team, turn it on.

------------------------------------------------------------------------

## 4. Required status checks

The template ships one CI job, `verify`, which runs
`./scripts/verify.sh --all`. Add it to the `main` ruleset as a required status
check: enable "Require status checks to pass" and add `verify`. GitHub lists a
check only after it ran once, so open a first pull request before adding it.

Without a required check a pull request can be merged while CI fails.
`./scripts/doctor.sh` warns when `main` has no such rule, and
`./scripts/publish-feature.sh` warns when it opens a pull request into a
branch without one, but only the ruleset refuses the merge.

A project that splits its CI into more jobs adds those checks as well.

Typical required checks:

-   lint
-   type-check
-   unit tests
-   integration tests
-   build

Example flow:

``` text
PR
→ GitHub Actions
→ required checks pass
→ merge allowed
```

Never configure a required check that is not actually produced by a
workflow, because this may block merges.

------------------------------------------------------------------------

## 5. GitHub Actions permissions

Go to:

**Settings → Actions → General**

Enable GitHub Actions.

Use the most restrictive default workflow permissions available.

Prefer read-only permissions by default.

Workflows that need write access should request it explicitly.

Example:

``` yaml
permissions:
  contents: read
```

A workflow that needs to comment on a pull request may instead use:

``` yaml
permissions:
  contents: read
  pull-requests: write
```

Follow the principle of least privilege.

------------------------------------------------------------------------

## 6. Security settings

Enable where available:

-   Dependency graph
-   Dependabot alerts
-   Dependabot security updates
-   Secret scanning
-   Push protection

Availability may depend on repository visibility and GitHub plan.

Never rely solely on GitHub secret scanning.

The repository must never contain:

-   `.env`
-   private keys
-   service account JSON files
-   API credentials
-   database passwords
-   production secrets

Only example configuration files should be committed.

Example:

`.env.example`

------------------------------------------------------------------------

## 7. Optional: GCP authentication

For projects deployed to Google Cloud, prefer:

``` text
GitHub Actions
→ OpenID Connect
→ Google Cloud Workload Identity Federation
→ GCP
```

Avoid storing long-lived GCP service account keys in GitHub Secrets
whenever Workload Identity Federation can be used instead.

Agents must not receive unnecessary production credentials.

------------------------------------------------------------------------

## 8. How work reaches `main`

Enable GitHub Issues: an Issue says what has to be done, and a pull request
that closes it is the record of review and integration. Nobody implements on
`main`; planning and every feature get their own branch and worktree, with
one writing agent per worktree.

``` text
GitHub Issue    what needs to be done, and its acceptance criteria
.agents/plans/  how a complex Issue will be implemented
Git history     what actually changed
Pull request    review, checks, and the decision to merge
```

A pull request references its Issue (`Closes #12`), carries the result of
the verification and of the independent review, and is merged by a person.
The steps in between, who acts in each, and what is recorded are in
[`docs/workflow.md`](workflow.md); the commands are in
[`docs/development.md`](development.md).

Agents are contributors, not authorities. CI remains the final technical
check, and a high-risk action needs explicit human approval; the rules are in
`AGENTS.md` and `.agents/policies/`.

------------------------------------------------------------------------

## 9. Optional: production deployment

For applications with production infrastructure, avoid direct deployment
from feature branches.

Recommended flow:

``` text
feature branch
    ↓
Pull Request
    ↓
CI
    ↓
merge to main
    ↓
deploy staging
    ↓
smoke tests
    ↓
production approval
    ↓
deploy production
```

For higher-risk systems, use GitHub Environments for production and
configure required approval before deployment.

------------------------------------------------------------------------

## 10. Optional: production database controls

Agents may:

-   create migration files
-   test migrations locally
-   test migrations in staging
-   generate rollback procedures

Agents must not autonomously:

-   run destructive production SQL
-   execute `DROP`, `TRUNCATE`, or unrestricted `DELETE`
-   change production Cloud SQL configuration
-   retrieve production database credentials
-   perform irreversible production migrations

Production database changes require explicit approval.

------------------------------------------------------------------------

## 11. Recommended repository checklist

Complete this checklist after creating a new repository from the
template.

### General

-   [ ] Repository created from template
-   [ ] `documentation/` and `.github/workflows/pages.yml` deleted
-   [ ] Correct visibility configured
-   [ ] Issues enabled

### Pull Requests

-   [ ] Squash merge enabled
-   [ ] Merge commits disabled
-   [ ] Rebase merge disabled
-   [ ] Automatically delete head branches enabled

### Branch protection

-   [ ] `main` ruleset created
-   [ ] Deletion of `main` blocked
-   [ ] Force pushes blocked
-   [ ] Pull Request required before merge
-   [ ] `@YOUR_GITHUB_USERNAME` replaced in `.github/CODEOWNERS`
-   [ ] In a team: code owner review required for the paths in `CODEOWNERS`

### CI

-   [ ] GitHub Actions enabled
-   [ ] Workflow permissions restricted
-   [ ] CI implemented
-   [ ] Required status checks configured after CI exists

### Security

-   [ ] Dependency graph enabled
-   [ ] Dependabot alerts enabled
-   [ ] Secret scanning enabled if available
-   [ ] Push protection enabled if available
-   [ ] Repository contains no secrets

### Deployment

If applicable:

-   [ ] Staging environment configured
-   [ ] Production environment configured
-   [ ] Production approval gate configured
-   [ ] GCP Workload Identity Federation configured
-   [ ] No long-lived GCP credentials stored unnecessarily

------------------------------------------------------------------------

## 12. Template repository specific setting

Only for the template repository itself:

Go to:

**Settings → General**

Enable:

-   **Template repository**

Repositories created from this template should normally not themselves
be marked as template repositories unless they are intentionally
intended to become new templates.
