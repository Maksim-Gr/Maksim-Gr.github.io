import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { parseFrontMatter, readPosts } from './posts.mjs';
import { checkLinks } from './check-links.mjs';

const site = path.dirname(fileURLToPath(import.meta.url));
const source = (extra = '', body = 'Opening paragraph.') => `---
title: "Example: a post"
date: 2026-10-10
description: An example
tags: [clickhouse, kafka]
${extra}
---
${body}
`;

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'blog-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.mkdirSync(path.join(root, 'posts'));
  fs.mkdirSync(path.join(root, 'site'));
  return root;
}

function post(root, dir, content) {
  const folder = path.join(root, 'posts', dir);
  fs.mkdirSync(folder, { recursive: true });
  fs.writeFileSync(path.join(folder, 'post.md'), content);
  return folder;
}

test('YAML supports README comments, quoted tags, escapes, and CRLF', () => {
  const { meta } = parseFrontMatter(source('series: Inside ClickHouse # optional\npart: 1 # required\ndraft: false # publish').replaceAll('\n', '\r\n'));
  assert.equal(meta.part, 1);
  assert.equal(meta.series, 'Inside ClickHouse');
  assert.equal(meta.draft, false);
  const quoted = parseFrontMatter(source().replace('[clickhouse, kafka]', '["clickhouse", "kafka"]'));
  assert.deepEqual(quoted.meta.tags, ['clickhouse', 'kafka']);
  assert.equal(parseFrontMatter(source().replace('An example', '"An \\"example\\" # here"')).meta.description, 'An "example" # here');
});

test('invalid metadata fails with a source filename', () => {
  for (const invalid of [
    source().replace('2026-10-10', '2026-02-30'),
    source().replace('[clickhouse, kafka]', 'clickhouse'),
    source().replace('[clickhouse, kafka]', 'null'),
    source('series: Series\npart: 0'),
    source('series: Series\npart: 1.5'),
    source('part: 1'),
    source('draft: "false"'),
    source().replace('title: "Example: a post"', 'title: ""'),
    source().replace('description: An example', 'description: false'),
  ]) assert.throws(() => parseFrontMatter(invalid, 'broken/post.md'), /broken\/post\.md:/);
});

test('collection rejects post, topic, and series collisions including drafts', (t) => {
  const root = fixture(t);
  const first = post(root, '2026-10-10-example', source());
  const second = post(root, '2026-10-11-example', source('draft: true'));
  assert.throws(() => readPosts(path.join(root, 'posts')), /duplicate post slug/);
  fs.renameSync(second, path.join(root, 'posts', '2026-10-11-other'));
  fs.writeFileSync(path.join(first, 'post.md'), source().replace('clickhouse, kafka', 'C++'));
  fs.writeFileSync(path.join(root, 'posts', '2026-10-11-other', 'post.md'), source().replace('clickhouse, kafka', 'C#'));
  assert.throws(() => readPosts(path.join(root, 'posts')), /topic slug collision/);
  for (const dir of fs.readdirSync(path.join(root, 'posts'))) {
    fs.writeFileSync(path.join(root, 'posts', dir, 'post.md'), source('series: Series\npart: 1\ndraft: true'));
  }
  assert.throws(() => readPosts(path.join(root, 'posts')), /duplicate part/);
});

test('build and exporter agree on drafts, series, assets, and explicit tags', (t) => {
  const root = fixture(t);
  const isolatedSite = path.join(root, 'site');
  for (const file of ['build.mjs', 'devto.mjs', 'posts.mjs', 'style.css', 'static']) {
    fs.cpSync(path.join(site, file), path.join(isolatedSite, file), { recursive: true });
  }
  fs.symlinkSync(path.join(site, 'node_modules'), path.join(isolatedSite, 'node_modules'), 'dir');
  const folder = post(root, '2026-10-10-example', source('series: Example\npart: 1 # comment',
    '![Image](images/chart.svg)\n\n[Next](/posts/next/)\n\n## Details\n\n[SQL](sample.sql)'));
  fs.mkdirSync(path.join(folder, 'images'));
  fs.writeFileSync(path.join(folder, 'images/chart.svg'), '<svg xmlns="http://www.w3.org/2000/svg"/>');
  fs.writeFileSync(path.join(folder, 'sample.sql'), 'SELECT 1;');
  post(root, '2026-10-11-next', source('series: Example\npart: 2\ndraft: true # unpublished'));
  const run = (script, ...args) => execFileSync(process.execPath, [path.join(isolatedSite, script), ...args], { encoding: 'utf8' });
  run('build.mjs');
  const out = path.join(isolatedSite, '_site');
  const home = fs.readFileSync(path.join(out, 'index.html'), 'utf8');
  assert.match(home, /src="\/posts\/example\/images\/chart.svg"/);
  assert.match(home, /coming soon/);
  assert.equal(fs.existsSync(path.join(out, 'posts/next/index.html')), false);
  assert.equal(checkLinks(out).pages, 5);
  run('devto.mjs');
  const exported = fs.readFileSync(path.join(root, 'devto/part1-example.md'), 'utf8');
  assert.match(exported, /tags: clickhouse, kafka, database, dataengineering/);
  assert.match(exported, /https:\/\/maksim-gr.github.io\/posts\/example\/images\/chart.svg/);
  assert.equal(fs.readdirSync(path.join(root, 'devto')).length, 1);
  run('build.mjs', '--drafts');
  assert.equal(checkLinks(out).pages, 6);
  const builtHome = fs.readFileSync(path.join(out, 'index.html'), 'utf8');
  post(root, '2026-10-11-next', source('draft: true\nseries: Example\npart: invalid'));
  for (const script of ['build.mjs', 'devto.mjs']) {
    assert.throws(() => execFileSync(process.execPath, [path.join(isolatedSite, script)], { stdio: 'pipe' }));
  }
  assert.equal(fs.readFileSync(path.join(out, 'index.html'), 'utf8'), builtHome);
  assert.equal(fs.readFileSync(path.join(root, 'devto/part1-example.md'), 'utf8'), exported);
});

test('link checker catches missing files, fragments, duplicate IDs, and decodes HTML attributes', (t) => {
  const root = fixture(t);
  const page = path.join(root, 'index.html');
  fs.writeFileSync(page, '<h1 id="hello">Hello</h1><a href="/#hello">OK</a><a href="https://example.org/absent">External</a><img src="a&amp;b.svg">');
  fs.writeFileSync(path.join(root, 'a&b.svg'), '<svg/>');
  assert.equal(checkLinks(root).references, 2);
  fs.appendFileSync(page, '<a href="/missing/">Missing</a><a href="#absent">Fragment</a><p id="hello">Duplicate</p>');
  assert.throws(() => checkLinks(root), (error) => {
    assert.match(error.message, /missing file/);
    assert.match(error.message, /missing fragment/);
    assert.match(error.message, /duplicate id/);
    return true;
  });
});
