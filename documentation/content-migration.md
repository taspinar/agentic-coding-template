# Docs migration record — Issue #240

Source: the [owner's audit on #235](https://github.com/taspinar/agentic-coding-template/issues/235), checked against the repository. Legacy sections were recovered from commit `6a62f84`, immediately before the Astro migration, including the licence instruction from PR #244. The source files remain authoritative; the website summarizes them.

## Inventory coverage

| Legacy content / source | Destination under Docs |
| --- | --- |
| Getting started: prerequisites, sign in, create repository, check setup, choose agents, plan project, first feature | getting-started |
| Getting started: update; Configuration: keeping up to date; Development: taking over template changes | updating |
| Getting started: failures; Workflow: situations handled | troubleshooting |
| Configuration: attribution, permissions, owner gate | configuration-and-security |
| Configuration: agent roles and models; Development: configuring agents | agent-roles |
| Workflow: risk level and workflow profiles; Configuration: risk policy; Development: levels, requirements and profiles | risk-policy |
| Workflow: every planning and feature step; Development: bootstrap, planning changes, feature Issues, canonical workflow, linking a plan | detailed-workflow |
| Development: owner-directed triage, earlier rounds, explicit review skip | detailed-workflow |
| Configuration: project/workflow checks; Development: verification and completion gate | verification-and-completion |
| Configuration: GitHub enforcement; repository setup settings | github-setup |
| Home: repository tree; Configuration: local records; Workflow: learning; Development: run records; project map | technical-reference |

The navigation replaces the legacy “Where to go next” and “Reference documentation” lists, as the audit directs. The interactive walkthrough and running modes belong to `/workflow` (#239). History, research, experimental parallel features and possible improvements belong to `/about` (#241); their source history remains in Git and they are not recategorized as Docs here.

## Corrections

| Audit item | Treatment |
| --- | --- |
| 1–2, 4: review coverage and provider requirement | Docs introduction, getting-started and detailed-workflow state the shipped policy, Low exceptions, explicit owner skip, and second provider requirement. Home and Research copy belongs to their respective website steps. |
| 3: prerequisites | getting-started requires both shipped providers; doctor checks the selected tools. |
| 5: gate is not a label | github-setup distinguishes the Guardrails signal from required CI and the merge-approval statement. |
| 6: risk hints | risk-policy describes labels and `--risk`, which can only raise risk. |
| 7: existing-file escalation | risk-policy distinguishes existing files, newly added files and shared fixtures. |
| 8–15: research and future statuses | About inventory belongs to #241. Docs describes clarification, risk-based models, partial checks, budgets, configured GitHub enforcement and the open separate-identity work as they exist now. |
| 16: risk versus merge approval | Separate risk-policy and configuration-and-security explanations; neither mechanism can be relaxed by the feature. |
| 17: prompts and schemas | technical-reference includes the current project map and links to source files on main. |
| 18: history additions | History belongs to #241; Docs covers the mechanisms themselves, including attribution, runtime directories, approval requests, durations, stops, model filtering, test escalation, risk hints and review history. |
| 19: source inaccuracies | docs/development.md now describes clarification as available and grouped intermediate checks at any level whose policy selects them. Migrated explanations agree. |

The owner's comments on #240 explicitly include the licence instruction in getting-started and authorize both source corrections. Shipped agent and risk configuration blocks reproduce the active lines of the repository files; application-specific risk classes are labelled as examples.

## Validation

`documentation/check.sh --build` builds both base paths, checks links and anchors, requires repository links to name main, checks named scripts at their actual paths, and runs `search-test.mjs` against each generated index. The checker regression tests cover missing files, wrong repository refs and qualified script paths. Search indexes rendered HTML, including MDX, code and tables, locally after the build; no external service is required. Sidebar, contents and previous/next navigation remain ordinary links without JavaScript.
