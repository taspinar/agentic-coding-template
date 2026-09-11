# Repository Setup

This document lists the GitHub repository settings that should be
configured for every new project created from this template.

These settings are intentionally not all encoded in repository files,
because some GitHub settings and rulesets are not inherited
automatically when creating a new repository from a template.

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

------------------------------------------------------------------------

## 4. Required status checks

Do not configure required status checks until the project's CI jobs
exist.

Once CI is configured, add the relevant checks to the `main` ruleset.

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

## 7. GCP authentication

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

## 8. GitHub Issues as the system of record

Enable GitHub Issues and use them for:

-   backlog
-   features
-   bugs
-   acceptance criteria
-   priority
-   discussion
-   linking implementation work

The repository should follow this separation:

``` text
GitHub Issue
= what needs to be done

.agents/plans/
= how a complex issue will be implemented

Git history
= what actually changed

Pull Request
= review, discussion and integration record
```

Do not replace GitHub Issues with local feature files.

------------------------------------------------------------------------

## 9. Recommended branch workflow

Never implement directly on `main`.

Use:

``` text
main
  |
  +-- feature/12-authentication
  |
  +-- feature/13-user-profile
```

For parallel agents, use separate worktrees:

``` text
project/
project-12-authentication/
project-13-user-profile/
```

One writing agent per worktree.

Multiple read-only reviewers may inspect the same stable branch or
commit.

------------------------------------------------------------------------

## 10. Pull Request workflow

Recommended lifecycle:

``` text
GitHub Issue
    ↓
Feature plan when warranted
    ↓
Feature branch / worktree
    ↓
Implementation
    ↓
Local verification
    ↓
Independent AI review when required
    ↓
Fix findings or explicitly defer eligible findings
    ↓
Verification
    ↓
Commit
    ↓
Push
    ↓
Pull Request
    ↓
GitHub Actions
    ↓
Merge
    ↓
Automatic Issue closure
    ↓
Worktree cleanup
```

Pull Requests should reference their issue.

Example:

``` text
Closes #12
```

------------------------------------------------------------------------

## 11. AI-generated work

AI agents are contributors, not authorities.

For substantial changes:

-   implementation should be attributable to an agent or human
-   independent review should be performed when required by the
    project's risk model
-   deterministic CI remains the final technical verification gate
-   high-risk actions may require explicit human approval

Recommended PR metadata:

``` md
## Agent involvement

Planner:
Implementer:
Reviewer:

## Verification

- [ ] Independent review completed
- [ ] `./scripts/verify.sh` passed
- [ ] GitHub Actions passed
```

------------------------------------------------------------------------

## 12. Production deployment

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

## 13. Production database controls

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

## 14. Recommended repository checklist

Complete this checklist after creating a new repository from the
template.

### General

-   [ ] Repository created from template
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

## 15. Template repository specific setting

Only for the template repository itself:

Go to:

**Settings → General**

Enable:

-   **Template repository**

Repositories created from this template should normally not themselves
be marked as template repositories unless they are intentionally
intended to become new templates.
