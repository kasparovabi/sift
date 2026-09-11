// Isolated portfolio entry point. Uses the real index, search and session reader.
import { createServer } from 'node:http';
import { mkdir, readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createApp, reindex } from './sift.mjs';
import { IndexStore } from './lib/index-store.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const data = join(here, '..', '.portfolio-data');
const projectsRoot = join(data, 'projects');
const supportDir = join(data, 'support');
const codexRoot = join(data, 'empty-codex');
await mkdir(supportDir, { recursive: true });
await mkdir(codexRoot, { recursive: true });
const store = new IndexStore(join(supportDir, 'index.sqlite'));
await reindex(store, projectsRoot, () => {}, supportDir, codexRoot);
const app = createApp(store, { projectsRoot, supportDir, open: false });
createServer(async (req, res) => {
  const pathname = new URL(req.url, 'http://localhost').pathname;
  if (req.method !== 'GET') {
    res.writeHead(403, { 'content-type': 'application/json' });
    return res.end(JSON.stringify({ error: 'Offline portfolio preview: this action is disabled.' }));
  }
  if (pathname === '/api/retention') {
    res.writeHead(200, { 'content-type': 'application/json' });
    return res.end(JSON.stringify({ days: 36500, files: 0, bytes: 0, portfolio: true }));
  }
  if (pathname === '/') {
    const html = await readFile(join(here, 'ui.html'), 'utf8');
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    return res.end(html.replace('<aside>', '<div style="position:fixed;bottom:0;left:0;right:0;z-index:9999;padding:7px;text-align:center;background:#173b35;color:white;font:12px system-ui">Portfolio preview · synthetic sessions · terminal actions disabled</div><aside>'));
  }
  return app(req, res);
}).listen(8916, '127.0.0.1', () => console.log('Sift portfolio: http://127.0.0.1:8916'));
