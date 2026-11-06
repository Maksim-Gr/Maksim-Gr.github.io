// Turns published posts into dev.to-ready Markdown: posts/*/post.md -> devto/<slug>.md
// Usage: node devto.mjs
// The files are for pasting into dev.to's editor. Each one starts as `published: false`
// and points its canonical URL at the post on this site, so search engines credit the original.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { readPosts, SITE_URL } from './posts.mjs';
// dev.to allows at most 4 tags: lowercase letters and digits only.
const TAGS = {
  clickhouse: ['clickhouse', 'database', 'dataengineering', 'sql'],
};

const siteDir = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(siteDir, '..');
const postsDir = path.join(rootDir, 'posts');
const outDir = path.join(rootDir, 'devto');

const yamlString = (s) => `"${String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;

const posts = readPosts(postsDir);

fs.rmSync(outDir, { recursive: true, force: true });
fs.mkdirSync(outDir, { recursive: true });

for (const { slug, meta, body } of posts) {
  if (meta.draft) continue;

  const postUrl = `${SITE_URL}/posts/${slug}/`;
  const tags = [...new Set([...meta.tags, ...meta.tags.flatMap((tag) => TAGS[tag] ?? [])]
    .map((tag) => tag.toLowerCase().replace(/[^a-z0-9]/g, ''))
    .filter(Boolean))].slice(0, 4);

  const text = body
    .replace(/<!--[\s\S]*?-->\n?/g, '')                       // notes to self
    .replace(/\]\(\/(?!\/)/g, `](${SITE_URL}/`)                // site links: /posts/... -> absolute
    .replace(/\]\((?![a-z]+:|\/|#)([^)\s]+)\)/g, `](${postUrl}$1)`) // files next to the post
    .replace(/\n{3,}/g, '\n\n')
    .trim();

  const front = [
    '---',
    `title: ${yamlString(meta.title)}`,
    'published: false',
    `description: ${yamlString(meta.description)}`,
    `tags: ${tags.join(', ')}`,
    `canonical_url: ${postUrl}`,
    ...(meta.series ? [`series: ${yamlString(meta.series)}`] : []),
    '---',
  ].join('\n');

  const file = path.join(outDir, `${meta.part ? `part${meta.part}-` : ''}${slug}.md`);
  fs.writeFileSync(file, `${front}\n\n${text}\n`);
  console.log(`${path.relative(rootDir, file)}  (${text.split(/\s+/).length} words)`);
}
