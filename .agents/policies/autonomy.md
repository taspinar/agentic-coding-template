# Risk-Based Autonomy

## Low risk
Examples: docs, formatting, isolated cosmetic UI, tests with no behavior change. Self-check + CI may be sufficient.

## Medium risk
Examples: normal features, business logic, APIs, non-destructive DB changes. Require independent AI review + CI.

## High risk
Examples: authentication/authorization, payments, destructive migrations, production data, IAM/secrets, production infrastructure/deployment. Require strong independent review, relevant security evaluation, CI, and explicit human approval at the risky boundary.
