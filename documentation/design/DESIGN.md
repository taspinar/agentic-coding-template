---
name: Agentic Coding Template (ACT)
description: Autonomous coding. Accountable engineering. A transit-map design system for the ACT website.
colors:
  ground: "#f4f5f4"
  ground-2: "#e9ebea"
  ink: "#141617"
  ink-2: "#4c5357"
  ink-3: "#5f676c"
  rule: "#c9cdcf"
  rule-strong: "#7a8186"
  line: "#00804a"
  line-ink: "#006b3e"
  line-soft: "#d4ebdf"
  off: "#b3b8bb"
  select: "#bfe3cf"
  ground-dark: "#121415"
  ground-2-dark: "#1b1e20"
  ink-dark: "#e9ebec"
  ink-2-dark: "#b3babe"
  ink-3-dark: "#8e969b"
  rule-dark: "#33393c"
  rule-strong-dark: "#687075"
  line-dark: "#34c27c"
  line-ink-dark: "#5fd598"
  line-soft-dark: "#173426"
  off-dark: "#474e52"
  select-dark: "#1f5038"
  terminal-ground: "#141617"
  terminal-ground-dark: "#000000"
  terminal-ink: "#e4e6e7"
  terminal-comment: "#8e989d"
  terminal-prompt: "#5fd598"
typography:
  display:
    fontFamily: "Overpass, Helvetica Neue, Arial, sans-serif"
    fontSize: "clamp(2.5rem, 1.3rem + 3.9vw, 4.6rem)"
    fontWeight: 800
    lineHeight: 0.98
    letterSpacing: "-0.035em"
  headline:
    fontFamily: "Overpass, Helvetica Neue, Arial, sans-serif"
    fontSize: "2.4rem"
    fontWeight: 800
    lineHeight: 1.08
    letterSpacing: "-0.02em"
  title:
    fontFamily: "Overpass, Helvetica Neue, Arial, sans-serif"
    fontSize: "1.3rem"
    fontWeight: 700
    lineHeight: 1.08
    letterSpacing: "-0.01em"
  lede:
    fontFamily: "Overpass, Helvetica Neue, Arial, sans-serif"
    fontSize: "1.3rem"
    fontWeight: 400
    lineHeight: 1.45
  body:
    fontFamily: "Overpass, Helvetica Neue, Arial, sans-serif"
    fontSize: "1.0625rem"
    fontWeight: 400
    lineHeight: 1.6
  body-sm:
    fontFamily: "Overpass, Helvetica Neue, Arial, sans-serif"
    fontSize: "0.9rem"
    fontWeight: 400
    lineHeight: 1.6
  label:
    fontFamily: "Overpass, Helvetica Neue, Arial, sans-serif"
    fontSize: "0.8rem"
    fontWeight: 700
    lineHeight: 1.6
  data:
    fontFamily: "Overpass Mono, ui-monospace, SFMono-Regular, Menlo, monospace"
    fontSize: "0.9rem"
    fontWeight: 600
    lineHeight: 1.6
  code-block:
    fontFamily: "Overpass Mono, ui-monospace, SFMono-Regular, Menlo, monospace"
    fontSize: "0.88rem"
    fontWeight: 400
    lineHeight: 1.75
rounded:
  hair: "2px"
  round: "50%"
spacing:
  s-1: "0.25rem"
  s-2: "0.5rem"
  s-3: "0.75rem"
  s-4: "1rem"
  s-5: "1.5rem"
  s-6: "2rem"
  s-7: "3rem"
  s-8: "4.5rem"
  s-9: "7rem"
  gutter: "clamp(1rem, 0.4rem + 2.4vw, 2.5rem)"
  page: "78rem"
  measure: "68ch"
  stroke: "6px"
components:
  button-primary:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.ground}"
    rounded: "{rounded.hair}"
    padding: "0.8rem 1.25rem 0.7rem"
  button-primary-hover:
    backgroundColor: "{colors.line-ink}"
    textColor: "{colors.ground}"
  switch:
    textColor: "{colors.ink-2}"
    typography: "{typography.data}"
    rounded: "{rounded.hair}"
    padding: "0.25rem 0.6rem 0.15rem"
  switch-checked:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.ground}"
  theme-toggle:
    textColor: "{colors.ink-2}"
    rounded: "{rounded.hair}"
    padding: "0.3rem 0.55rem"
  header:
    backgroundColor: "{colors.ground}"
    height: "3.75rem"
  record:
    backgroundColor: "{colors.ground-2}"
    textColor: "{colors.ink}"
    padding: "1rem 1rem 0.75rem"
  pin:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.ground}"
    rounded: "{rounded.round}"
    size: "1.35rem"
  terminal:
    backgroundColor: "{colors.terminal-ground}"
    textColor: "{colors.terminal-ink}"
    typography: "{typography.code-block}"
    rounded: "{rounded.hair}"
    padding: "1.5rem"
---

# Design System: Agentic Coding Template (ACT)

## Overview

**Creative North Star: "The Route Map of a Change"**

The site is drawn in Vignelli/Beck network-map grammar. A change is a transit line: steps are stations, owner decisions are diamonds, conditional paths are dashed branches, and one signal green marks the route. Everything else is ink on a neutral, slightly cool map-paper ground (never cream), divided by hairline rules. Diagrams are the real mechanism, not a metaphor laid over it; every station and branch corresponds to a script, a policy or a gate that exists.

Density is that of a reference map: flat, typographic, many small labelled facts, generous section spacing. Structure comes from rules and alignment, never from boxes. Light and dark themes are equal citizens and neither uses gradient or glow.

**Key Characteristics:**
- One line colour (signal green) on ink and grey; green is the route, ink is the stops.
- Overpass (highway-signage lineage) for prose and labels; Overpass Mono only for data.
- Hairline rules for division, 2px ink rules to head a structure; no elevation.
- 45/90-degree strokes, round stations, diamond owner gates.
- Every map has a words twin that is both its text alternative and its narrow-screen form.

## Colors

Near-monochrome map paper and ink with a single signal green.

### Primary
- **Signal Green** (`line`): the route of a change. Map trunk strokes, the words-list spine, link underlines, the focus outline, nav current/hover underline, the ring in the ACT mark. 4.59:1 on ground (light), 8.05:1 (dark).
- **Deep Signal Green** (`line-ink`): green used as text or as a filled hover state: the second clause of the hero headline, link hover text, primary button hover, the "changed" label in tables. 6.06:1 (light), 10.08:1 (dark).
- **Green Wash** (`line-soft`): low-half highlighter behind quoted phrases in an annotated record. Never a fill for areas.
- **Selection Green** (`select`): text selection background only.

### Neutral
- **Map Paper** (`ground`): page ground, sticky header ground, station fill, text on filled ink.
- **Paper Shade** (`ground-2`): ground for verbatim artifacts only: the annotated record and inline code.
- **Ink** (`ink`): text, station rings, owner-gate diamonds, pins, primary button, checked switch, the 2px structure rules.
- **Ink Grey** (`ink-2`): secondary text: lede, captions, station sub-labels, nav at rest, ledger lists.
- **Label Grey** (`ink-3`): smallest labels: table heads, switch legends, map notes, record source line, absent values. 5.27:1 (light), 6.15:1 (dark).
- **Hairline** (`rule`): 1px dividers and resting borders of switches and the theme toggle.
- **Strong Hairline** (`rule-strong`): dashed conditional branches and hover borders.
- **Off Route** (`off`): a trunk segment and its station rings not taken in the current state (review bypass).

Dark theme swaps every token to its `-dark` value via `prefers-color-scheme: dark` unless `data-theme="light"` is set, or via `data-theme="dark"`. The terminal keeps its own dark ground in both themes (`terminal-ground`; `terminal-ground-dark` with a 1px `rule` border in dark).

### Named Rules
**The One Line Rule.** Green means the route. It appears only on route strokes, link underlines, focus, the mark ring, record highlights, the "changed" label and the hero's second clause. No green backgrounds, panels, badges or decoration.

**The Ink Decides Rule.** Stations and owner gates are ink, never green. The line is green; what happens on it is black (white in dark).

## Typography

**Display Font:** Overpass 800 (with Helvetica Neue, Arial, sans-serif)
**Body Font:** Overpass 400/600/700 (same stack)
**Label/Mono Font:** Overpass Mono 400/600 (with ui-monospace, SFMono-Regular, Menlo, monospace)

**Character:** Signage sans with tight negative tracking at display sizes; its mono sibling marks anything a machine reads or a person types. Fonts are self-hosted woff2 (OFL), `font-display: swap`, Overpass 800 preloaded. Kerning and ligatures on.

### Hierarchy
- **Display** (800, clamp 2.5–4.6rem, 0.98, -0.035em): the hero headline only, max 14ch.
- **Headline** (800, 2.4rem, 1.08, -0.02em): section h2, balanced wrapping.
- **Title** (700, 1.3rem, -0.01em): h3 and the route-map heading (tracking 0 there). Inside ledgers and splits h3 drops to 1.0625rem.
- **Lede** (400, 1.3rem, 1.45): hero lede (46ch, ink-2) and the first paragraph of a section body (1.5 line height).
- **Body** (400, 1.0625rem, 1.6): prose, max 68ch, pretty wrapping.
- **Body small** (0.9rem): captions, section-header notes, tables, ledger and note lists, nav (600).
- **Label** (600–700, 0.8rem, lowercase): table heads, switch legends, stacked-cell labels, legend items.
- **Map labels** (SVG px): station name 17px/700 (15px in secondary maps), sub-label 14px/600 ink-2, branch note 13.5px/600 ink-3.

### Named Rules
**The Value in Mono Rule.** Overpass Mono is for code, file/script/model/agent names, setting values, verification seconds and the terminal. Prose, headings, labels, station names and condition notes stay in Overpass. A map sub-label is mono only when it is a value (`verify.sh`, `claude opus`), sans when it is a description (`full triage`, `by you`).

**The Lowercase Label Rule.** Field labels are small, bold, lowercase sans in ink-3. No uppercase tracked labels, no eyebrow text above headings.

## Layout

- **Frame:** content max 78rem, centred, side gutter `clamp(1rem, 0.4rem + 2.4vw, 2.5rem)`. Spacing on a 4px base (`s-1`…`s-9`).
- **Hero:** two-column grid (1.35fr / 1fr, gap s-5 × s-7, bottom-aligned): headline left; lede, actions right. The route map figure spans the full width below, between hairlines.
- **Section grid:** each section is s-8 vertical padding with a 1px top rule (first section none). Inside, a 15rem header column (h2 plus one short ink-2 note naming the source, with links) and a fluid body column, gap s-6. Body children are spaced s-5. While the grid has two columns (above 1100px) the header column is sticky at 5.5rem from the top.
- **Breakpoints:**
  - **≤1100px:** hero, section grid and annotated record collapse to one column; every SVG map and its legend are hidden and the words list is shown in its place; the mark's tagline hides; the record stops wrapping and scrolls horizontally.
  - **≤760px:** header nav moves to a full-width second row that scrolls horizontally (theme toggle pushed right); ledger and split go to one column; tables stack; section padding drops to s-7, hero top to s-6.
- **Measures:** prose 68ch, lede 46ch, caption 80ch, display 14ch.

## Elevation & Depth

Flat. No box shadows for elevation, no glows, no blur. Depth is expressed by rule weight and ground tint: a 1px `rule` hairline divides; a 2px `ink` rule heads a structure (table head, ledger, record, split heading, stacked row, footer); `ground-2` marks verbatim artifacts. The sticky header separates by its ground fill and a hairline.

### Named Rules
**The Hairline Rule.** If something needs separating, draw a rule. Inset box-shadows are allowed only as drawn strokes (nav underline 3px green, record highlighter), never as offset or blurred shadows.

## Shapes

- **Corners:** 2px (`hair`) on interactive and inline elements only: buttons, switches, theme toggle, inline code, terminal, focus outline. Content regions are square.
- **Circles:** stations, the mark ring, pins and risk-level discs. Level discs: outlined = low, half-filled (hard 50% split) = medium, filled = high.
- **Diamonds:** squares rotated 45°, for owner gates only.
- **Strokes:** route 6px (`stroke`) with round caps and joins; branches 3px dashed (7/7); every direction change is 45° or 90°.

## Components

### Header and navigation
Sticky, `ground` fill, 1px bottom hairline, min height 3.75rem. The mark is a 3px green ring, "ACT" in 800 at 1.35rem, then the full name in body-small ink-2 (hidden ≤1100px). Nav links: 600, body small, ink-2, no underline at rest; hover and `aria-current` turn ink with a 3px green underline. The theme toggle is a mono xs button with a 1px hairline border naming the theme it switches to ("Dark"/"Light"); the choice persists in `localStorage` (`act-theme`) and is applied in `<head>` before paint.

### Buttons and links
- **Primary:** one filled button for the page's main action: ink fill, ground text, 700, 2px corners; hover fills `line-ink`.
- **Secondary actions:** plain text links (600) beside it, not ghost buttons.
- **Links:** ink text, 2px green underline offset 0.22em; hover turns the text `line-ink`.
- **Focus:** 3px green outline, 3px offset, on every focusable element.

### Route map with switches (signature)
A `figure` between hairlines: title-level heading left, switches right, SVG map, legend, live caption.
- **Grammar:** green trunk left to right; ring stations (r 10, ground fill, 3.5px ink) with the name below and one sub-label under it; filled ink diamond = owner gate where you decide (merge, plan approval); outlined diamond = you answer, only when asked; dashed `rule-strong` branch = only when needed, loops above the line with a short ink-3 note, bypasses below; steps not taken in the current state dim to `off`. A second line in the same map is ink (planning), the feature line green.
- **Switches:** radio groups in fieldsets with lowercase ink-3 legends (`risk`, `profile`); options are mono pills, checked = ink fill. State is written to `data-risk` / `data-profile` on the container; CSS redraws the route, script swaps labels and the caption (`aria-live="polite"`).
- **Legend:** one row of the actual map symbols with words; `aria-hidden` because the words list carries the content.
- **Motion:** stroke colour only, 160ms ease-out, and only under `prefers-reduced-motion: no-preference`.

### Converging map and rules list (Learn from your runs)
The same line grammar for many-to-one: short green feature lines end in ring stations (the run records) and join the trunk at 45° into one station (`Analysis`, sub-label `analyze-runs.sh` in mono, `read-only` in sans). A filled diamond (`You decide`) follows on the ink line, which then fans out at 45° into the places a proposal can go, each ending in a ring with its label to the right. Text in this map is set larger (station 18, sub 16, note 15 viewBox units) because its viewBox is wider. Below 1100px it gives way to its words list. The rules beneath it use `.rules`: a two-column list (one column ≤760px) headed by a 2px ink rule, with each item a bold lead-in sentence in ink followed by ink-2 text.

### Words list (map fallback and text alternative)
An ordered list with a 6px green spine; each item gets a ring marker (0.95rem, 3.5px ink); owner-gate items get a filled ink diamond. Station name in 700, sub-label in body-small ink-2 (mono when a value), conditions as small ink-2 sentences. It is referenced by the map's `aria-describedby`, is shown instead of the map at ≤1100px, and follows the switch state (bypassed stations hidden).

### Ledger
Three equal columns under a 2px ink rule, separated by 1px hairlines; h3 at body size, small ink-2 bullet lists. Used for "who does what". One column with hairlines between at ≤760px.

### Tables (stacked)
Small text, tabular figures, left-aligned, hairline row rules; lowercase label heads above a 2px ink rule; row headers 700, no wrap; values mono; numbers mono and right-aligned; captions below in small ink-2; absent values ink-3 with an en dash. At ≤760px rows become blocks headed by a 2px ink rule and each cell is labelled from `data-col`. Wide tables sit in a horizontal scroll wrapper.

### Matrix
A level × profile table with the same rules. Cells differing from the baseline start with a `line-ink` "changed" word label, so the difference is stated in text, not by colour alone. Stacks like tables at ≤760px.

### Annotated record with pins
A verbatim artifact (e.g. a PR description) in a mono `pre` on `ground-2` under a 2px ink rule, source URL in xs mono ink-3 first. Key phrases get the green-wash lower-half highlight and a numbered pin (1.35rem ink disc, sans numeral, `aria-hidden`). Beside it (1.25fr / 1fr), a numbered notes list with hairlines explains each pin. One column ≤1100px.

### Split
Two columns, each headed by a body-size h3 over a 2px ink rule, small bullet lists. Used to separate what ACT enforces from what repository settings enforce. One column ≤760px.

### Terminal
Dark block in both themes, 2px corners, s-5 padding, mono 0.88rem/1.75; comments in `terminal-comment`, `$` prompt in `terminal-prompt` and not selectable. Real commands only. A short small ink-2 requirements note may follow it.

### Footer
2px ink top rule, small ink-2 text, one line of project description and a nav of plain links, wrapping with space-between; padding s-6 top, s-8 bottom.

## Do's and Don'ts

### Do:
- **Do** draw every process as a line map with stations, owner-gate diamonds (filled = you decide, outlined = you answer) and dashed conditional branches at 45/90 degrees.
- **Do** keep one green, for the route and its direct signals; stations and gates stay ink.
- **Do** pair every map with an ordered words list carrying the same stations and conditions, and give the SVG `role="img"`, a `<title>` and `aria-describedby` pointing at that list.
- **Do** make the no-JS state complete: the hero map defaults to medium risk under the standard profile, switches are hidden without the `js` class, nothing depends on script to be readable.
- **Do** meet WCAG 2.2 AA in both themes: 4.5:1 for text (ink-3 is the lightest text token), 3:1 for meaningful strokes and UI borders, visible 3px focus, keyboard-operable switches, and any dimmed route paired with text stating the state.
- **Do** use Overpass Mono only for code, file, script and model names, values and seconds.
- **Do** separate with 1px hairlines and head structures with 2px ink rules.
- **Do** use real evidence only: linked Issues, PRs, review rounds and measured verification seconds.

### Don't:
- **Don't** use cards: no bordered, rounded or raised boxes around content groups; tinted grounds are for verbatim artifacts only.
- **Don't** use icons. The only symbols are the map's own (ring, diamond, level disc, pin), each explained by a legend or adjacent text.
- **Don't** use visible gradients, box shadows for elevation, glows, glassmorphism or blur.
- **Don't** animate on scroll, reveal on scroll, or move anything; motion is limited to a 160ms stroke-colour change.
- **Don't** invent statistics, testimonials, user counts or benchmarks.
- **Don't** put eyebrow or kicker text above headings, or use uppercase tracked labels.
- **Don't** add a second accent colour or encode meaning in colour alone.
