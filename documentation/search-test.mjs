import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { plainText } from './integrations/search.mjs';
import { searchPages } from './src/lib/search.mjs';
import { feature, planning } from './src/lib/steps.ts';

assert.equal(plainText('<p>A &amp; B &#x3c; C</p><script>secret</script>'), 'A & B < C');
const example = [{ title: 'Risk policy', text: 'verification: groups', url: '/docs/risk/' }];
assert.equal(searchPages(example, 'RISK groups').length, 1);
assert.equal(searchPages(example, 'risk absent').length, 0);
assert.equal(searchPages(example, '  ').length, 0);

if (process.argv[2]) {
  const [output, base] = process.argv.slice(2);
  const pages = JSON.parse(await readFile(join(output, 'search-index.json'), 'utf8'));
  const docs = pages.filter(p => p.url.startsWith(`${base}docs/`));
  assert.equal(docs.length, 12);
  for (const [query, slug] of [['Troubleshooting', 'troubleshooting'], ['GitHub setup', 'github-setup']]) {
    const results = searchPages(docs, query);
    assert(results.some(p => p.url === `${base}docs/${slug}/`));
    assert(results.length < docs.length, `Navigation leaked into search: ${query}`);
    assert(!results.some(p => p.url === `${base}docs/agent-roles/`), `Sidebar-only match: ${query}`);
  }
  assert(searchPages(pages, 'LICENSE').some(p => p.url === `${base}docs/getting-started/`));
  assert(searchPages(pages, 'owner-directed').some(p => p.url === `${base}docs/detailed-workflow/`));
  // Every step is in the workflow reference, and its old anchor on /workflow leads there.
  const reference = await readFile(join(output, 'docs/reference/workflow/index.html'), 'utf8');
  const workflow = await readFile(join(output, 'workflow/index.html'), 'utf8');
  assert(workflow.includes('id="steps"'), 'The section anchor of /workflow is gone');
  for (const { id } of [...planning, ...feature]) {
    assert(reference.includes(`<section class="ref-step" id="${id}"`), `Not in the reference: ${id}`);
    assert(workflow.includes(`<a id="${id}" href="${base}docs/reference/workflow/#${id}">`), `Old anchor lost: /workflow/#${id}`);
  }
  for (const page of pages) {
    assert(page.url.startsWith(base));
    const html = await readFile(join(output, page.url.slice(base.length), 'index.html'), 'utf8');
    const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(m => m[1]);
    assert.equal(new Set(ids).size, ids.length, `Duplicate anchors: ${page.url}`);
    if (page.url.startsWith(`${base}docs/`)) {
      assert(html.includes('aria-label="Documentation"'));
      assert(html.includes('aria-current="page"'));
      assert(html.includes('aria-label="Previous and next pages"'));
    }
  }
}

// Shipped examples must move with their source configuration.
for (const [slug, source] of [['agent-roles', '.agents/agents.conf'], ['risk-policy', '.agents/policies/risk.conf']]) {
  const config = await readFile(new URL(`../${source}`, import.meta.url), 'utf8');
  const active = config.split('\n').filter(line => line && !line.startsWith('#')).join('\n');
  const content = await readFile(new URL(`./src/content/docs/${slug}.md`, import.meta.url), 'utf8');
  assert(content.includes('```text\n' + active + '\n```'), `Stale shipped example: ${slug}`);
}

console.log('search-test: passed');
