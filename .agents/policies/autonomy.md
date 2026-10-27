# Risk-Based Autonomy

The rules that classify a feature are in `.agents/policies/risk.conf`, the one
source of the path classes, the default, the test files, and the manifests;
`scripts/check-risk.sh` computes the level from them. This file describes what
the levels mean.

## Low risk
Examples: docs, formatting, isolated cosmetic UI, tests with no behavior change. Self-check + CI may be sufficient.

## Medium risk
Examples: normal features, business logic, APIs, non-destructive DB changes. Require independent AI review + CI.

## High risk
Examples: authentication/authorization, payments, destructive migrations, production data, IAM/secrets, production infrastructure/deployment. Require strong independent review, relevant security evaluation, CI, and explicit human approval at the risky boundary.
