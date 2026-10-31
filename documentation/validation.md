# Documentation validation

Run `npm ci` in this directory, then `npm run check`. The documentation check
is also run by the repository's existing verification and the Pages workflow.
It builds and link-checks the project path (currently
`/agentic-coding-template/`) and `/`, runs the site's
unit and search tests, and uses Playwright Chromium and axe-core on every
built HTML page, including 404, in light and dark themes at 375, 768 and
1440 pixels. Serious/critical violations and text contrast failures fail the
check. Horizontal page overflow and third-party requests also fail it.
Before the build, the check starts Playwright Chromium once
(`browser-ready.mjs`; `./check.sh --browser` runs only this step). It
downloads Chromium only when it is not installed, so a run with the browser in
place needs no network. When the download fails, or Chromium does not start
because Linux system libraries are missing, it stops with the command to run:
`npx playwright install --with-deps chromium`, or
`sudo npx playwright install-deps chromium` for the libraries alone. CI
installs the browser with its dependencies before the check.

After a rename, update the project path in `check.sh`'s `for base in … /`
list (retain `/`), its usage comment and this guide. Keep
`default_site_url` in `check.sh` in sync with the site origin in
`site.config.ts`. These validation defaults are separate from the site
configuration; CI uses them through `check.sh --build`.

`browser-check.mjs` walks the skip link, site navigation, theme toggle,
workflow radio groups, the workflow's step detail panel (from a station of the
map and from the words list: its tabs, its close button and where the focus
returns, with axe on the open panel), walkthrough and desktop text-list toggle
by keyboard, checking focus outlines; a station of the map shows its focus as
the 6px line-coloured stroke of its symbol. It checks the documentation disclosures at 760 px,
the desktop navigation at 768 px, and the no-JavaScript fallback. On the
workflow reference it checks that an old step anchor of `/workflow` leads to
its step and that "On this page" stays beside the text at 1440 px; on a docs
page, that the copy button of a code block copies the code. Native
summaries keep both navigation lists usable with JavaScript disabled.

The check writes full-page screenshots and `report.json` under
`documentation/reports/{project,root}/` (ignored by Git). Set
`DOCUMENTATION_REPORT_DIR` to retain them elsewhere. Reports include axe
results and cases requiring manual inspection, total JavaScript bytes per
page (inline plus loaded scripts), and the largest total page weight (HTML
plus all loaded resources). These are uncompressed cold-load resource bytes,
not transfer-compressed sizes or a speed score. There is no performance
budget or change to the ACT verification policy.

CI uploads `documentation-review` on the pull request's check run, even on
failure, and links the review instructions in its summary. Open the PR's CI
check, download that artifact and inspect its screenshots; link the check
run/artifact in the PR description when publishing. An artifact exists only
after CI has run. It expires after 30 days; retain a copy for a longer review.

## Visual review

Review every page in both themes at all three widths against
`design/PRODUCT.md` and `design/DESIGN.md`:

- Does each diagram communicate an actual mechanism, with a readable text
  alternative at narrow widths? Are labels separated and content unclipped?
- Does typography and alignment establish hierarchy without decorative
  illustrations, cards, icons, shadows, gradients or extra accent colours?
- Are there any invented claims, numbers, testimonials or superlatives?
- Are navigation, focus, code and tables readable in both themes? Does the
  narrow Docs layout place search above the collapsed navigation lists?
- Is the content available without JavaScript and without animation?

Automated axe results are evidence, not a complete WCAG certification. Review
its incomplete results (especially SVG text contrast), keyboard focus in the
sticky/scrolling header, and the screenshots alongside the browser checks.
Publication evidence is the successful Documentation workflow after merge
and the live nested routes, not a local build. No deployment is needed for
local validation. Future rename and domain instructions are in
`docs/repository-setup.md` and the site's GitHub setup page.
