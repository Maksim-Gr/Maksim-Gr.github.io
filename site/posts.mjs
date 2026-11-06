import fs from 'node:fs';
import path from 'node:path';
import { parse } from 'yaml';

export const SITE_URL = 'https://maksim-gr.github.io';
export const slugify = (text) => text.toLowerCase()
  .replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');

export function parseFrontMatter(source, file = 'post.md') {
  const match = source.replace(/\r\n/g, '\n').match(/^---\n([\s\S]*?)\n---(?:\n|$)([\s\S]*)$/);
  if (!match) throw new Error(`${file}: expected a front matter block`);
  const meta = parse(match[1]);
  const fail = (message) => { throw new Error(`${file}: ${message}`); };
  if (!meta || typeof meta !== 'object' || Array.isArray(meta)) fail('expected metadata fields');
  for (const key of ['title', 'date', 'description']) {
    if (typeof meta[key] !== 'string' || !meta[key].trim()) fail(`"${key}" must be a nonempty string`);
  }
  if (!/^\d{4}-\d{2}-\d{2}$/.test(meta.date)
      || !Number.isFinite(Date.parse(meta.date))
      || new Date(meta.date).toISOString().slice(0, 10) !== meta.date) fail('"date" must be a valid YYYY-MM-DD date');
  if (meta.tags === undefined) meta.tags = [];
  if (!Array.isArray(meta.tags) || meta.tags.some((tag) => typeof tag !== 'string' || !slugify(tag))) {
    fail('"tags" must be an array of strings with usable slugs');
  }
  if (meta.draft !== undefined && typeof meta.draft !== 'boolean') fail('"draft" must be a boolean');
  for (const key of ['series', 'tested_on']) {
    if (meta[key] !== undefined && (typeof meta[key] !== 'string' || !meta[key].trim())) fail(`"${key}" must be a nonempty string`);
  }
  if (meta.series !== undefined || meta.part !== undefined) {
    if (!meta.series || !Number.isSafeInteger(meta.part) || meta.part < 1) fail('a series requires a name and a positive integer "part"');
  }
  return { meta, body: match[2] };
}

// Validate the whole collection, including drafts, before either exporter writes files.
export function readPosts(postsDir) {
  const slugs = new Set();
  const topics = new Map();
  const series = new Map();
  return fs.readdirSync(postsDir).sort().flatMap((dir) => {
    const file = path.join(postsDir, dir, 'post.md');
    if (!fs.existsSync(file)) return [];
    const { meta, body } = parseFrontMatter(fs.readFileSync(file, 'utf8'), file);
    const slug = dir.replace(/^\d{4}-\d{2}-\d{2}-/, '');
    if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug) || slugs.has(slug)) throw new Error(`${file}: invalid or duplicate post slug "${slug}"`);
    slugs.add(slug);
    for (const tag of meta.tags) {
      const topic = slugify(tag);
      if (topics.has(topic) && topics.get(topic) !== tag) throw new Error(`${file}: topic slug collision for "${tag}" and "${topics.get(topic)}"`);
      topics.set(topic, tag);
    }
    if (meta.series) {
      const parts = series.get(meta.series) ?? new Set();
      if (parts.has(meta.part)) throw new Error(`${file}: duplicate part ${meta.part} in "${meta.series}"`);
      parts.add(meta.part);
      series.set(meta.series, parts);
    }
    return [{ dir, slug, meta, body }];
  });
}
