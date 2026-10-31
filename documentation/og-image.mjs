// Renders og-image.svg, the social preview image, to public/og.png at
// 1200 × 630 with the site's own fonts. Run it after changing the drawing:
//   node og-image.mjs
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const here = (path) => fileURLToPath(new URL(path, import.meta.url));
// The fonts go in as data: a page set from a string may not load file URLs.
const font = async (file, weight) => {
  const data = (await readFile(here(`src/fonts/${file}`))).toString('base64');
  return `@font-face { font-family: "Overpass"; font-weight: ${weight}; src: url(data:font/woff2;base64,${data}); }`;
};
const svg = await readFile(here('og-image.svg'), 'utf8');
const page = `<!doctype html><style>
${await font('overpass-latin-600-normal.woff2', 600)}
${await font('overpass-latin-700-normal.woff2', 700)}
${await font('overpass-latin-800-normal.woff2', 800)}
html, body { margin: 0; }
</style>${svg}`;

const browser = await chromium.launch();
try {
  const tab = await browser.newPage({ viewport: { width: 1200, height: 630 } });
  await tab.setContent(page);
  await tab.evaluate(() => document.fonts.ready);
  await tab.locator('svg').screenshot({ path: here('public/og.png') });
} finally {
  await browser.close();
}
