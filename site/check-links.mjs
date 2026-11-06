import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parse } from 'parse5';
import { SITE_URL } from './posts.mjs';

export function checkLinks(directory) {
  const root = path.resolve(directory);
  const pages = new Map();
  const errors = [];
  let references = 0;
  for (const entry of fs.readdirSync(root, { recursive: true, withFileTypes: true })) {
    if (!entry.isFile() || !entry.name.endsWith('.html')) continue;
    const file = path.join(entry.parentPath, entry.name);
    const page = { ids: new Set(), links: [] };
    const visit = (node) => {
      const attrs = Object.fromEntries((node.attrs ?? []).map(({ name, value }) => [name, value]));
      if (attrs.id !== undefined) {
        if (page.ids.has(attrs.id)) errors.push(`${path.relative(root, file)}: duplicate id "${attrs.id}"`);
        page.ids.add(attrs.id);
      }
      for (const key of ['href', 'src']) {
        if (attrs[key] !== undefined) page.links.push(attrs[key]);
      }
      for (const child of node.childNodes ?? []) visit(child);
    };
    visit(parse(fs.readFileSync(file, 'utf8')));
    pages.set(file, page);
  }
  for (const [file, page] of pages) {
    const base = new URL(path.relative(root, file).split(path.sep).join('/'), `${SITE_URL}/`);
    for (const link of page.links) {
      const fail = (message) => errors.push(`${path.relative(root, file)}: ${message} (${link})`);
      let url;
      let target;
      let fragment;
      try {
        url = new URL(link, base);
        if (url.origin !== new URL(SITE_URL).origin) continue;
        target = path.resolve(root, `.${decodeURIComponent(url.pathname)}`);
        fragment = decodeURIComponent(url.hash.slice(1));
      } catch {
        fail('invalid URL');
        continue;
      }
      references++;
      if (!target.startsWith(`${root}${path.sep}`) && target !== root) {
        fail('path escapes site');
        continue;
      }
      if (fs.existsSync(target) && fs.statSync(target).isDirectory()) target = path.join(target, 'index.html');
      if (!fs.existsSync(target)) fail('missing file');
      else if (fragment && pages.has(target) && !pages.get(target).ids.has(fragment)) fail(`missing fragment "${fragment}"`);
    }
  }
  if (errors.length) throw new Error(errors.join('\n'));
  return { pages: pages.size, references };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const result = checkLinks(fileURLToPath(new URL('./_site/', import.meta.url)));
  console.log(`Checked ${result.pages} pages and ${result.references} local references`);
}
