// Check the actual static output, including 404, at both configured base paths.
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile, readdir, mkdir, writeFile } from 'node:fs/promises';
import { resolve, join, extname } from 'node:path';
import { chromium } from 'playwright';
import AxeBuilder from '@axe-core/playwright';

const [output, base] = process.argv.slice(2);
assert(output && base, 'Usage: node browser-check.mjs <output> <base>');
const reportDir = resolve(process.env.DOCUMENTATION_REPORT_DIR || 'reports', base === '/' ? 'root' : 'project');
await mkdir(reportDir, { recursive: true });
async function pagesIn(dir, prefix = '') {
  const entries = await readdir(dir, { withFileTypes: true });
  return (await Promise.all(entries.map(e => e.isDirectory() ? pagesIn(join(dir, e.name), `${prefix}${e.name}/`) : e.name.endsWith('.html') ? [`${prefix}${e.name}`] : []))).flat().sort();
}
const files = await pagesIn(output);
const types = { '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript', '.json': 'application/json', '.woff2': 'font/woff2' };
const server = createServer(async (req, res) => {
  try {
    const path = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
    assert(path.startsWith(base));
    const file = resolve(output, path.slice(base.length) + (path.endsWith('/') ? 'index.html' : ''));
    assert(file.startsWith(resolve(output) + '/'));
    res.setHeader('Content-Type', types[extname(file)] || 'application/octet-stream');
    res.end(await readFile(file));
  } catch { res.writeHead(404).end('Not found'); }
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const origin = `http://127.0.0.1:${server.address().port}`;
let browser;
const report = { base, pages: [], accessibility: [], screenshots: [], keyboard: [] };
try {
  browser = await chromium.launch();
  const context = await browser.newContext({ reducedMotion: 'reduce' });
  const page = await context.newPage();
  const external = new Set();
  await context.route('**/*', route => {
    if (new URL(route.request().url()).origin !== origin) { external.add(route.request().url()); return route.abort(); }
    return route.continue();
  });
  await page.addInitScript(() => {
    const theme = new URL(location.href).searchParams.get('theme');
    if (theme) localStorage.setItem('act-theme', theme);
  });
  // Tab through actual navigation, radio groups and buttons; no focus() or mouse.
  async function tabTo(selector) {
    for (let i = 0; i < 160; i++) {
      await page.keyboard.press('Tab');
      const matched = await page.evaluate(s => document.activeElement?.matches(s), selector);
      const focused = await page.evaluate(() => {
        const e = document.activeElement;
        if (!e || e === document.body) return true;
        // A station of the workflow map shows focus on its symbol: the stroke turns to the line, 6px wide.
        if (e.matches('g.station')) return [...e.querySelectorAll('.dot, .gate, .gate-o')].some(s => parseFloat(getComputedStyle(s).strokeWidth) >= 6);
        const visible = e.matches('input[type=radio]') ? e.nextElementSibling : e;
        const style = getComputedStyle(visible);
        return style.outlineStyle !== 'none' && parseFloat(style.outlineWidth) >= 2;
      });
      assert(focused, `Missing keyboard focus indicator while seeking ${selector}`);
      if (matched) return;
    }
    assert.fail(`Cannot reach ${selector} with Tab`);
  }
  const panelAccessible = async () => {
    const results = await new AxeBuilder({ page }).include('#step-panel').withTags(['wcag2a', 'wcag2aa', 'wcag21aa', 'wcag22aa']).analyze();
    assert.deepEqual(results.violations.filter(v => ['serious', 'critical'].includes(v.impact) || v.id === 'color-contrast'), [], 'Accessibility of the step detail panel');
  };
  for (const theme of ['light', 'dark']) {
    for (const width of [375, 1440]) {
      await page.setViewportSize({ width, height: 900 });

      await page.goto(origin + base + '?theme=' + theme);
      await tabTo('.skip');
      await page.keyboard.press('Enter');
      assert.equal(await page.evaluate(() => document.activeElement.id), 'main');
      // The home page map: the review bypass is hidden wherever policy
      // excludes it and shows, solid, only under low risk with the light profile.
      if (width === 1440) {
        for (const risk of ['low', 'medium', 'high']) {
          for (const profile of ['standard', 'light']) {
            await page.locator(`#lifecycle label:has(input[name="risk"][value="${risk}"])`).click();
            await page.locator(`#lifecycle label:has(input[name="profile"][value="${profile}"])`).click();
            const shown = await page.evaluate(() => [...document.querySelectorAll('#lifecycle .map :is(.bypass, .bypass-note)')]
              .map(e => ({ display: getComputedStyle(e).display, dash: getComputedStyle(e).strokeDasharray })));
            assert(shown.length > 0);
            const at = `home page bypass at ${risk} risk, ${profile} profile`;
            if (risk === 'low' && profile === 'light') {
              for (const r of shown) assert.notEqual(r.display, 'none', at);
              assert.equal(shown[0].dash, 'none', at);
            } else {
              for (const r of shown) assert.equal(r.display, 'none', at);
            }
          }
        }
      }
      await page.goto(origin + base + '?theme=' + theme);
      await tabTo('.nav a');
      await page.keyboard.press('Enter');
      await page.waitForURL(origin + base + 'workflow/');
      await tabTo('.theme');
      await page.keyboard.press('Enter');
      assert.equal(await page.locator('html').getAttribute('data-theme'), theme === 'light' ? 'dark' : 'light');
      await page.keyboard.press('Enter');
      for (const name of ['risk', 'profile', 'run', 'part', 'situation']) {
        const radios = page.locator(`input[name="${name}"]`);
        assert(await radios.count() > 1);
        await tabTo(`input[name="${name}"]`);
        const before = await page.locator(`input[name="${name}"]:checked`).inputValue();
        await page.keyboard.press('ArrowRight');
        assert.notEqual(await page.locator(`input[name="${name}"]:checked`).inputValue(), before);
      }
      assert.match(await page.locator('[data-summary]').innerText(), /High risk.*light profile.*unattended.*planning only.*unclear Issue/s);
      // The step detail panel from a station of the map: Enter opens it with
      // the focus on its heading, the arrow keys move between its tabs, Close
      // returns the focus to the station.
      if (width === 1440) {
        await tabTo('svg g.station[data-key="f-review"]');
        await page.keyboard.press('Enter');
        assert(await page.locator('#step-panel').isVisible());
        assert.equal(await page.evaluate(() => document.activeElement.id), 'step-panel-h');
        assert.equal(await page.locator('#step-panel-h').innerText(), 'Review the code');
        assert(await page.locator('svg g[data-key="f-review"]').evaluate(e => e.classList.contains('is-selected')));
        await tabTo('#step-panel [role="tab"][aria-selected="true"]');
        await page.keyboard.press('ArrowRight');
        assert.equal(await page.evaluate(() => document.activeElement.dataset.tab), 'technical');
        assert.match(await page.locator('#step-tab-body').innerText(), /Command\s+\.\/scripts\/review-feature\.sh/);
        await page.keyboard.press('ArrowRight');
        assert.match(await page.locator('#step-tab-body').innerText(), /Stops, retries and exceptions/);
        await panelAccessible();
        await page.keyboard.press('Shift+Tab');
        await page.keyboard.press('Enter');
        assert(!await page.locator('#step-panel').isVisible());
        assert.equal(await page.evaluate(() => document.activeElement.dataset.key), 'f-review');
      }
      await page.locator('[data-action="reset"]').press('Enter');
      assert.equal(await page.locator('input[name="part"]:checked').inputValue(), 'all');
      assert.match(await page.locator('[data-summary]').innerText(), /^Medium risk.*standard profile.*step by step$/s);
      // The review bypass as rendered. Policy excludes it at medium and high
      // risk and under the standard profile, so there it is off the route: the
      // off colour, solid, never the dashed style of a route that can happen.
      // Only low risk with the light profile draws it at full strength (at
      // 1440 px: at 375 px the list is the map).
      if (width === 1440) {
        const bypass = () => page.evaluate(() => ['b-bypass', 'n-bypass'].map(key => {
          const e = document.querySelector(`svg.map [data-key="${key}"]`);
          const s = getComputedStyle(e);
          return { key, display: s.display, width: e.getBBox().width, off: e.classList.contains('is-off'), taken: e.classList.contains('is-taken'), dash: s.strokeDasharray, stroke: s.stroke, fill: s.fill };
        }));
        const color = name => page.evaluate(name => { const p = document.createElement('p'); p.style.color = `var(${name})`; document.body.append(p); const c = getComputedStyle(p).color; p.remove(); return c; }, name);
        const ink = await color('--ink'), off = await color('--off');
        const choose = async (name, value) => page.locator(`label:has(input[name="${name}"][value="${value}"])`).click();
        for (const risk of ['low', 'medium', 'high']) {
          for (const profile of ['standard', 'light']) {
            await choose('risk', risk);
            await choose('profile', profile);
            const [branch, note] = await bypass();
            const at = `at ${risk} risk, ${profile} profile`;
            if (risk === 'low' && profile === 'light') {
              for (const r of [branch, note]) assert(r.display !== 'none' && r.width > 0 && r.taken && !r.off, `${r.key} taken ${at}`);
              assert.equal(branch.dash, 'none', `b-bypass solid ${at}`);
              assert.notEqual(branch.stroke, off, `b-bypass at full strength ${at}`);
              assert.equal(note.fill, ink, `n-bypass in ink ${at}`);
            } else {
              for (const r of [branch, note]) assert(r.off && !r.taken, `${r.key} off ${at}`);
              assert.equal(branch.dash, 'none', `b-bypass not dashed ${at}`);
              assert.equal(branch.stroke, off, `b-bypass in the off colour ${at}`);
              assert.notEqual(note.fill, ink, `n-bypass not in ink ${at}`);
            }
          }
        }
        await page.locator('[data-action="reset"]').click();
      }
      await tabTo('[data-action="play"]');
      await page.keyboard.press('Enter');
      assert(await page.locator('[data-workflow]').evaluate(e => e.classList.contains('walking')));
      await tabTo('[data-action="next"]');
      await page.keyboard.press('Enter');
      assert.match(await page.locator('[data-caption="lead"]').innerText(), /Step 2/);
      await tabTo('[data-action="finish"]');
      await page.keyboard.press('Enter');
      assert(!await page.locator('[data-workflow]').evaluate(e => e.classList.contains('walking')));
      if (width === 1440) {
        await tabTo('[data-action="list"]');
        await page.keyboard.press('Enter');
        assert.equal(await page.locator('[data-action="list"]').getAttribute('aria-expanded'), 'true');
      }
      // The same panel from the words list, inside the item that opened it.
      await tabTo('.words li[data-key="f-checks"] .detail-btn');
      await page.keyboard.press('Enter');
      assert(await page.locator('.words li[data-key="f-checks"] #step-panel').isVisible());
      assert.equal(await page.evaluate(() => document.activeElement.id), 'step-panel-h');
      await panelAccessible();
      await tabTo('.panel-close');
      await page.keyboard.press('Enter');
      assert(!await page.locator('#step-panel').isVisible());
      assert(await page.evaluate(() => document.activeElement.matches('.words li[data-key="f-checks"] .detail-btn')));
      await page.goto(origin + base + 'docs/?theme=' + theme);
      await tabTo('.docs-search input');
      if (width <= 760) {
        await tabTo('.docs-sidebar summary');
        await page.keyboard.press('Enter');
        assert.notEqual(await page.locator('.docs-sidebar details').getAttribute('open'), null);
      }
      await tabTo('.docs-sidebar nav a');
      if (width <= 760) {
        await tabTo('.docs-toc summary');
        await page.keyboard.press('Enter');
        assert.notEqual(await page.locator('.docs-toc').getAttribute('open'), null);
      }
      await tabTo('.docs-toc a');
      await tabTo('.docs-pagination a');

      await page.goto(origin + base + 'examples/?theme=' + theme);
      await tabTo('.contents a');
      // Reaching the final footer link walks every intervening content link too.
      await tabTo('footer nav a:last-child');
      report.keyboard.push({ theme, width, pages: ['home', 'workflow', 'docs', 'examples'], passed: true });
    }
  }
  // Disclosure breakpoint and no-JS fallback, including search-before-navigation.
  for (const javaScriptEnabled of [true, false]) {
    const docs = await browser.newContext({ javaScriptEnabled, viewport: { width: 760, height: 900 } });
    const p = await docs.newPage();
    await p.goto(origin + base + 'docs/');
    const disclosure = p.locator('.docs-sidebar details');
    assert.equal(await disclosure.getAttribute('open'), null);
    assert.equal(await p.locator('.docs-toc').getAttribute('open'), null);
    await p.locator('.docs-sidebar summary').press('Enter');
    assert.notEqual(await disclosure.getAttribute('open'), null);
    await p.locator('.docs-sidebar summary').press('Enter');
    assert((await p.locator('article').boundingBox()).y < 900, 'Docs article starts below the first screen');
    if (javaScriptEnabled) {
      const search = await p.locator('.docs-search').boundingBox();
      const nav = await disclosure.boundingBox();
      assert(search.y + search.height <= nav.y, 'Search must precede the disclosure');
    }
    await p.setViewportSize({ width: 768, height: 900 });
    if (javaScriptEnabled) {
      assert(await p.locator('.docs-sidebar nav').isVisible());
    } else {
      // Summaries must remain reachable even when ::details-content is unsupported.
      for (const selector of ['.docs-sidebar', '.docs-toc']) {
        const summary = p.locator(`${selector} summary`);
        assert(await summary.isVisible(), `No-JS desktop summary hidden: ${selector}`);
        const nav = p.locator(`${selector} nav`);
        assert(!await nav.isVisible(), `No-JS closed desktop content visible: ${selector}`);
        await summary.press('Enter');
        assert(await nav.isVisible(), `No-JS desktop content did not open: ${selector}`);
        await summary.press('Enter');
        assert(!await nav.isVisible(), `No-JS desktop content did not close: ${selector}`);
      }
      await p.goto(origin + base + 'workflow/');
      assert(await p.locator('#workflow-words').isVisible());
      assert(!await p.locator('.map-actions').isVisible());
      assert(!await p.locator('.hint').isVisible() && !await p.locator('.reset').isVisible());
      assert.equal(await p.locator('.station, .detail-btn').count(), 0, 'Without JavaScript nothing pretends to open the step detail');
    }
    await docs.close();
  }
  for (const file of files) {
    const path = base + file.replace(/index\.html$/, '');
    const slug = file.replace(/\/index\.html$/, '').replace(/\.html$/, '').replaceAll('/', '-');
    for (const theme of ['light', 'dark']) {
      await page.emulateMedia({ colorScheme: theme });

      for (const width of [375, 768, 1440]) {
        await page.setViewportSize({ width, height: 900 });
        await page.goto(origin + path + '?theme=' + theme);
        await page.evaluate(() => document.fonts.ready);
        assert.equal(await page.locator('html').getAttribute('data-theme'), theme);
        assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), `Horizontal overflow: ${path} ${width}`);
        const results = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21aa', 'wcag22aa']).analyze();
        const violations = results.violations.filter(v => ['serious', 'critical'].includes(v.impact) || v.id === 'color-contrast');
        report.accessibility.push({ path, theme, width, violations, incomplete: results.incomplete.map(v => ({ id: v.id, targets: v.nodes.map(n => n.target) })) });
        assert.deepEqual(violations, [], `Accessibility: ${path} ${theme} ${width}`);
        if (width === 1440) {
          const lowContrast = await page.locator('svg text').evaluateAll(elements => {
            const luminance = color => {
              const rgb = color.match(/[\d.]+/g).slice(0, 3).map(Number).map(v => v / 255).map(v => v <= .04045 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4);
              return rgb[0] * .2126 + rgb[1] * .7152 + rgb[2] * .0722;
            };
            const ground = luminance(getComputedStyle(document.body).backgroundColor);
            return elements.filter(e => e.getBoundingClientRect().width && e.checkVisibility()).flatMap(e => {
              const ink = luminance(getComputedStyle(e).fill);
              const ratio = (Math.max(ink, ground) + .05) / (Math.min(ink, ground) + .05);
              return ratio < 4.5 ? [{ text: e.textContent, ratio }] : [];
            });
          });
          assert.deepEqual(lowContrast, [], `SVG text contrast: ${path} ${theme}`);
        }
        const screenshot = `${slug}-${theme}-${width}.png`;
        await page.screenshot({ path: join(reportDir, screenshot), fullPage: true });
        report.screenshots.push(screenshot);
        if (theme === 'light' && width === 1440) {
          const resources = await page.evaluate(() => performance.getEntriesByType('resource').map(r => ({ url: r.name, bytes: r.decodedBodySize, kind: r.initiatorType })));
          const html = await readFile(join(output, file), 'utf8');
          const inlineJS = [...html.matchAll(/<script\b(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)].reduce((sum, m) => sum + Buffer.byteLength(m[1]), 0);
          report.pages.push({ path, javascriptBytes: inlineJS + resources.filter(r => r.kind === 'script').reduce((s, r) => s + r.bytes, 0), pageBytes: Buffer.byteLength(html) + resources.reduce((s, r) => s + r.bytes, 0), resources });
        }
      }
    }
    console.log(`  Checked ${path} in both themes at all three widths.`);
  }
  assert.deepEqual([...external], [], 'Third-party resources are forbidden');

  report.largestPage = report.pages.reduce((a, b) => a.pageBytes > b.pageBytes ? a : b);
  console.log(`browser-check: ${files.length} pages, both themes, three widths; keyboard checks passed (${base}).`);
  for (const p of report.pages) console.log(`  ${p.path}: JS ${p.javascriptBytes} bytes; page ${p.pageBytes} bytes (uncompressed, cold load)`);
  console.log(`  Largest page: ${report.largestPage.path}, ${report.largestPage.pageBytes} bytes. No third-party requests.`);
} finally {
  await writeFile(join(reportDir, 'report.json'), JSON.stringify(report, null, 2));
  await browser?.close();
  await new Promise(r => server.close(r));
}
