import { readdir, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join, relative, sep } from 'node:path';

export function plainText(html) {
  const entities = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' };
  return html.replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/gi, '')
    .replace(/<[^>]*>/g, ' ')
    .replace(/&(#x[\da-f]+|#\d+|amp|lt|gt|quot|apos|nbsp);/gi, (_, entity) => {
      if (entity[0] !== '#') return entities[entity.toLowerCase()];
      const value = entity[1].toLowerCase() === 'x'
        ? parseInt(entity.slice(2), 16) : parseInt(entity.slice(1), 10);
      return value <= 0x10ffff ? String.fromCodePoint(value) : '';
    }).replace(/\s+/g, ' ').trim();
}

/** Index the rendered output, so MDX, tables and code are searchable too. */
export default function searchIndex() {
  let base;
  return { name: 'local-search', hooks: {
    'astro:config:done': ({ config }) => { base = config.base.replace(/\/?$/, '/'); },
    'astro:build:done': async ({ dir }) => {
      const root = fileURLToPath(dir);
      const pages = [];
      async function walk(directory) {
        for (const entry of await readdir(directory, { withFileTypes: true })) {
          const path = join(directory, entry.name);
          if (entry.isDirectory()) await walk(path);
          else if (entry.name === 'index.html') {
            const html = await readFile(path, 'utf8');
            const main = html.match(/<main\b[^>]*>([\s\S]*?)<\/main>/i)?.[1];
            if (!main) continue;
            pages.push({
              title: plainText(html.match(/<h1\b[^>]*>([\s\S]*?)<\/h1>/i)?.[1] || ''),
              url: base + relative(root, path).split(sep).join('/').replace(/index\.html$/, ''),
              text: plainText(main.match(/<article\b[^>]*\bdata-search\b[^>]*>([\s\S]*?)<\/article>/i)?.[1] || main),
            });
          }
        }
      }
      await walk(root);
      await writeFile(join(root, 'search-index.json'), JSON.stringify(pages));
    },
  } };
}
