// Static site generator: posts/*/post.md -> site/_site
// Usage: node build.mjs [--drafts]

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Marked } from 'marked';
import hljs from 'highlight.js';

const SITE = {
  title: 'Maksim Grishchenko',
  description: 'Data engineering, databases and software: notes from my day-to-day work.',
  url: 'https://maksim-gr.github.io',
  repo: 'https://github.com/Maksim-Gr/Maksim-Gr.github.io',
  github: 'https://github.com/Maksim-Gr',
  email: 'maksim.g.grishchenko@gmail.com',
  telegram: 'MaxXGr',
};

const siteDir = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(siteDir, '..');
const postsDir = path.join(rootDir, 'posts');
const outDir = path.join(siteDir, '_site');
const includeDrafts = process.argv.includes('--drafts');

// Files next to post.md that are published with the post (scripts, images).
const PUBLISHED_EXTENSIONS = new Set(['.sql', '.json', '.sh', '.py', '.yml', '.png', '.jpg', '.jpeg', '.svg', '.gif', '.webp']);

const escapeHtml = (s) => String(s)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;').replace(/'/g, '&#39;');

const decodeEntities = (s) => s
  .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
  .replace(/&#39;/g, "'").replace(/&amp;/g, '&');

const slugify = (s) => s.toLowerCase()
  .replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');

function parseFrontMatter(src) {
  if (!src.startsWith('---\n')) {
    return { meta: {}, body: src };
  }
  const end = src.indexOf('\n---\n', 4);
  if (end === -1) {
    throw new Error('Unterminated front matter');
  }
  const meta = {};
  for (const line of src.slice(4, end).split('\n')) {
    const m = line.match(/^(\w+):\s*(.*)$/);
    if (!m) continue;
    let value = m[2].trim();
    if (value.startsWith('[') && value.endsWith(']')) {
      value = value.slice(1, -1).split(',').map((v) => v.trim()).filter(Boolean);
    } else if (value === 'true' || value === 'false') {
      value = value === 'true';
    } else {
      value = value.replace(/^["']|["']$/g, '');
    }
    meta[m[1]] = value;
  }
  return { meta, body: src.slice(end + 5) };
}

let usedIds = new Map();

const marked = new Marked({
  gfm: true,
  renderer: {
    heading({ tokens, depth }) {
      const html = this.parser.parseInline(tokens);
      const base = slugify(decodeEntities(html.replace(/<[^>]+>/g, ''))) || 'section';
      const n = usedIds.get(base) ?? 0;
      usedIds.set(base, n + 1);
      const id = n === 0 ? base : `${base}-${n}`;
      return `<h${depth} id="${id}">${html} <a class="anchor" href="#${id}" aria-label="Link to this section">#</a></h${depth}>\n`;
    },
    code({ text, lang }) {
      const language = (lang || '').trim().split(/\s+/)[0];
      const body = language && hljs.getLanguage(language)
        ? hljs.highlight(text, { language }).value
        : escapeHtml(text);
      return `<pre><code class="hljs${language ? ` language-${language}` : ''}">${body}</code></pre>\n`;
    },
  },
});

// The opening of a post for the home page: the first few blocks before the first "##" heading.
function renderExcerpt(md, postUrl, maxBlocks = 3) {
  const blocks = [];
  for (const token of marked.lexer(md)) {
    if (token.type === 'heading' && token.depth <= 2) break;
    if (token.type === 'space' || token.type === 'html') continue;
    blocks.push(token);
    if (blocks.length === maxBlocks) break;
  }
  usedIds = new Map();
  // Relative links (scripts next to the post) must point into the post's folder.
  return marked.parser(blocks)
    .replace(/href="(?!https?:|\/|#|mailto:)([^"]+)"/g, `href="${postUrl}$1"`);
}

function renderMarkdown(md) {
  usedIds = new Map();
  return marked.parse(md)
    .replace(/<!--[\s\S]*?-->\n?/g, '') // notes to self (TODOs) stay out of the published page
    .replace(/<table>/g, '<div class="table-wrap"><table>')
    .replace(/<\/table>/g, '</table></div>');
}

function layout({ title, description, url, body, type = 'website', jsonLd }) {
  const pageTitle = url === '/' ? SITE.title : `${title} · ${SITE.title}`;
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(pageTitle)}</title>
<meta name="description" content="${escapeHtml(description)}">
<link rel="canonical" href="${SITE.url}${url}">
<meta property="og:site_name" content="${escapeHtml(SITE.title)}">
<meta property="og:title" content="${escapeHtml(title)}">
<meta property="og:description" content="${escapeHtml(description)}">
<meta property="og:url" content="${SITE.url}${url}">
<meta property="og:type" content="${type}">
<meta name="twitter:card" content="summary">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="icon" href="/favicon-32.png" sizes="32x32" type="image/png">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="stylesheet" href="/style.css">
${jsonLd ? `<script type="application/ld+json">${JSON.stringify(jsonLd).replace(/</g, '\\u003c')}</script>\n` : ''}</head>
<body>
<header class="site">
  <a class="name" href="/">${escapeHtml(SITE.title)}</a>
  <nav><a href="/">Posts</a><a href="/topics/">Topics</a></nav>
</header>
<main>
${body}
</main>
<footer class="site">
  <p class="asterism" aria-hidden="true">* * *</p>
  <p class="links"><a href="mailto:${SITE.email}">Email</a><a href="https://t.me/${SITE.telegram}">Telegram</a><a href="${SITE.github}">GitHub</a></p>
</footer>
</body>
</html>
`;
}

const topicLinks = (tags) => tags
  .map((t) => `<a class="tag" href="/topics/${slugify(t)}/">${escapeHtml(t)}</a>`)
  .join(' ');

function postList(posts) {
  return `<ul class="posts">
${posts.map((p) => `  <li>
    <time datetime="${p.date}">${p.date}</time>
    <a class="title" href="${p.url}">${escapeHtml(p.title)}</a>
    <span class="tags">${topicLinks(p.tags)}${p.draft ? ' <span class="draft">draft</span>' : ''}</span>
  </li>`).join('\n')}
</ul>`;
}

function postEntries(posts) {
  return posts.map((p) => {
    const meta = [
      `<time datetime="${p.date}">${p.date}</time>`,
      p.series ? `Part ${p.part} of <em>${escapeHtml(p.series)}</em>` : '',
      `${p.minutes} min read`,
      topicLinks(p.tags),
      p.draft ? '<span class="draft">draft</span>' : '',
    ].filter(Boolean).join(' · ');
    return `<section class="entry">
  <h2 class="entry-title"><a href="${p.url}">${escapeHtml(p.title)}</a></h2>
  <p class="entry-meta">${meta}</p>
  <div class="excerpt">
${p.excerpt}  </div>
  <p class="readmore"><a href="${p.url}">Read more ⟶</a></p>
</section>`;
  }).join('\n');
}

function writeFile(rel, content) {
  const file = path.join(outDir, rel);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content);
}

// Collect posts. Drafts left out of the build are remembered, so links and series
// boxes can show them as "coming soon" instead of linking to a missing page.
const posts = [];
const unpublished = [];
for (const dir of fs.readdirSync(postsDir).sort()) {
  const mdFile = path.join(postsDir, dir, 'post.md');
  if (!fs.existsSync(mdFile)) continue;
  const { meta, body } = parseFrontMatter(fs.readFileSync(mdFile, 'utf8'));
  if (meta.draft && !includeDrafts) {
    const slug = dir.replace(/^\d{4}-\d{2}-\d{2}-/, '');
    unpublished.push({ url: `/posts/${slug}/`, title: meta.title, series: meta.series, part: meta.part ? Number(meta.part) : undefined });
    continue;
  }
  for (const key of ['title', 'date', 'description']) {
    if (!meta[key]) {
      throw new Error(`${mdFile}: front matter is missing "${key}"`);
    }
  }
  const slug = dir.replace(/^\d{4}-\d{2}-\d{2}-/, '');
  const html = renderMarkdown(body);
  const words = body.replace(/```[\s\S]*?```/g, '').split(/\s+/).length;
  posts.push({
    dir,
    slug,
    url: `/posts/${slug}/`,
    title: meta.title,
    date: meta.date,
    description: meta.description,
    testedOn: meta.tested_on,
    tags: Array.isArray(meta.tags) ? meta.tags : [],
    draft: Boolean(meta.draft),
    series: meta.series,
    part: meta.part ? Number(meta.part) : undefined,
    minutes: Math.max(1, Math.round(words / 230)),
    html,
    excerpt: renderExcerpt(body, `/posts/${slug}/`),
  });
}
posts.sort((a, b) => b.date.localeCompare(a.date));

// Links between posts: a link to a built post stays, a link to a draft that isn't built becomes
// plain text marked "coming soon", and a link to a post that doesn't exist at all fails the build.
const builtUrls = new Set(posts.map((p) => p.url));
const unpublishedUrls = new Set(unpublished.map((p) => p.url));
const postLink = /<a href="(\/posts\/[^"#]+?\/)(?:#[^"]*)?">(.*?)<\/a>/g;
for (const p of posts) {
  const resolve = (html) => html.replace(postLink, (link, url, text) => {
    if (builtUrls.has(url)) return link;
    if (unpublishedUrls.has(url)) return `<span class="soon">${text} (coming soon)</span>`;
    throw new Error(`posts/${p.dir}/post.md links to ${url}, which doesn't exist`);
  });
  p.html = resolve(p.html);
  p.excerpt = resolve(p.excerpt);
}

const seriesParts = (p) => [...posts, ...unpublished.map((q) => ({ ...q, unpublished: true }))]
  .filter((q) => q.series && q.series === p.series)
  .sort((a, b) => a.part - b.part);

function seriesNav(p) {
  if (!p.series) return '';
  const items = seriesParts(p).map((q) => {
    if (q === p) return `<li><span class="current">${escapeHtml(q.title)}</span></li>`;
    if (q.unpublished) return `<li><span class="soon">${escapeHtml(q.title)} (coming soon)</span></li>`;
    return `<li><a href="${q.url}">${escapeHtml(q.title)}</a></li>`;
  }).join('');
  return `<nav class="series" aria-label="Series"><p>Part ${p.part} of the series <em>${escapeHtml(p.series)}</em></p><ol>${items}</ol></nav>`;
}

function seriesNext(p) {
  if (!p.series) return '';
  const next = seriesParts(p).find((q) => q.part === p.part + 1);
  if (!next) return '';
  const title = `Part ${next.part}: ${escapeHtml(next.title)}`;
  return `<p class="series-next">Next in <em>${escapeHtml(p.series)}</em>: ${next.unpublished ? `<span class="soon">${title} (coming soon)</span>` : `<a href="${next.url}">${title}</a>`}</p>`;
}

// Output
fs.rmSync(outDir, { recursive: true, force: true });
fs.mkdirSync(outDir, { recursive: true });
fs.copyFileSync(path.join(siteDir, 'style.css'), path.join(outDir, 'style.css'));
// Files served from the site root as they are (icons).
fs.cpSync(path.join(siteDir, 'static'), outDir, { recursive: true });
writeFile('.nojekyll', '');

for (const p of posts) {
  const meta = [
    `<time datetime="${p.date}">${p.date}</time>`,
    `${p.minutes} min read`,
    p.testedOn ? `Tested on ${escapeHtml(p.testedOn)}` : '',
    topicLinks(p.tags),
  ].filter(Boolean).join(' · ');
  const body = `<article>
<header class="post-head">
  <h1>${escapeHtml(p.title)}</h1>
  <p class="post-meta">${meta}</p>
</header>
${seriesNav(p)}
${p.html}
${seriesNext(p)}
</article>`;
  writeFile(`posts/${p.slug}/index.html`, layout({
    title: p.title,
    description: p.description,
    url: p.url,
    body,
    type: 'article',
    jsonLd: {
      '@context': 'https://schema.org',
      '@type': 'BlogPosting',
      headline: p.title,
      description: p.description,
      datePublished: p.date,
      url: `${SITE.url}${p.url}`,
      mainEntityOfPage: `${SITE.url}${p.url}`,
      author: { '@type': 'Person', name: SITE.title, url: SITE.github },
      keywords: p.tags.join(', '),
      ...(p.series ? { isPartOf: { '@type': 'CreativeWorkSeries', name: p.series }, position: p.part } : {}),
    },
  }));
  for (const f of fs.readdirSync(path.join(postsDir, p.dir))) {
    if (PUBLISHED_EXTENSIONS.has(path.extname(f).toLowerCase())) {
      fs.copyFileSync(path.join(postsDir, p.dir, f), path.join(outDir, 'posts', p.slug, f));
    }
  }
}

writeFile('index.html', layout({
  title: SITE.title,
  description: SITE.description,
  url: '/',
  body: `<p class="intro">${escapeHtml(SITE.description)}</p>\n${postEntries(posts)}`,
}));

const tags = [...new Set(posts.flatMap((p) => p.tags))].sort();
writeFile('topics/index.html', layout({
  title: 'Topics',
  description: `Posts by topic on ${SITE.title}`,
  url: '/topics/',
  body: `<h1>Topics</h1>\n<ul class="topics">\n${tags.map((t) => {
    const n = posts.filter((p) => p.tags.includes(t)).length;
    return `  <li><a href="/topics/${slugify(t)}/">${escapeHtml(t)}</a> <span class="count">${n}</span></li>`;
  }).join('\n')}\n</ul>`,
}));
for (const t of tags) {
  writeFile(`topics/${slugify(t)}/index.html`, layout({
    title: `Topic: ${t}`,
    description: `Posts about ${t} on ${SITE.title}`,
    url: `/topics/${slugify(t)}/`,
    body: `<h1>${escapeHtml(t)}</h1>\n${postList(posts.filter((p) => p.tags.includes(t)))}`,
  }));
}

console.log(`Built ${posts.length} post(s) into ${path.relative(rootDir, outDir)}${includeDrafts ? ' (including drafts)' : ''}`);
