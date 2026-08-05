#!/usr/bin/env node
// Sift for Windows and Linux: the same idea as the macOS app, served to a browser.
//
// SwiftUI does not exist off Apple platforms, so the interface could not be carried over.
// What did carry over is the part that matters: scan the transcripts Claude Code already
// writes, keep a SQLite FTS5 index beside them, and hand a session back to a real terminal.
//
//     node web/sift.mjs
//
// No dependencies. SQLite comes with Node 22+.

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';
import { spawn } from 'node:child_process';

import { listTranscripts, parseTranscript, displayName, decodeProjectDir } from './lib/scanner.mjs';
import { IndexStore } from './lib/index-store.mjs';
import { openSession, revealFolder, isWindows } from './lib/terminal.mjs';
import { keep, restore, archiveSize, archivePathFor, currentRetentionDays, setRetentionDays, FOREVER }
  from './lib/archive.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));

export function config(env = process.env) {
  const home = homedir();
  return {
    projectsRoot: env.SIFT_PROJECTS_ROOT || join(home, '.claude', 'projects'),
    supportDir: env.SIFT_SUPPORT_DIR || defaultSupportDir(home, env),
    port: Number(env.SIFT_PORT || 4319),
    claude: env.SIFT_CLAUDE || 'claude',
    open: env.SIFT_NO_OPEN !== '1',
  };
}

function defaultSupportDir(home, env) {
  if (process.platform === 'win32') return join(env.LOCALAPPDATA || join(home, 'AppData', 'Local'), 'Sift');
  if (process.platform === 'darwin') return join(home, 'Library', 'Application Support', 'Sift');
  return join(env.XDG_DATA_HOME || join(home, '.local', 'share'), 'sift');
}

/// Indexes every transcript that changed since last time. Unchanged files are skipped on
/// (size, mtime), so a rescan over thousands of sessions costs almost nothing.
export async function reindex(store, projectsRoot, onProgress = () => {}, supportDir = null) {
  const found = await listTranscripts(projectsRoot);
  const known = store.fingerprints();
  let indexed = 0;
  let archived = 0;

  for (const [i, file] of found.entries()) {
    const seen = known.get(file.filePath);
    if (seen && seen.size === file.size && seen.mtime === file.mtime) continue;
    try {
      const meta = await parseTranscript(file.filePath);
      store.upsert({ ...meta, fileSize: file.size, fileMtime: file.mtime }, file.projectId);
      indexed += 1;
      // Kept before anything else can remove it: a search tool whose corpus evaporates
      // after thirty days is not a search tool.
      if (supportDir && await keep(supportDir, file.filePath, file.projectId, meta.sessionId)) {
        archived += 1;
      }
    } catch { /* a transcript being written right now can be unreadable for a moment */ }
    if (i % 200 === 0) onProgress(i, found.length);
  }
  // A transcript that has left ~/.claude/projects is not gone from Sift: the row stays and
  // points at the archived copy.
  const vanished = supportDir
    ? store.repointMissing(found.map((f) => f.filePath), (p, s) => archivePathFor(supportDir, p, s))
    : store.removeMissing(found.map((f) => f.filePath));
  return { total: found.length, indexed, archived, vanished };
}

function json(res, body, status = 200) {
  const text = JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8' });
  res.end(text);
}

async function readBody(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  if (!chunks.length) return {};
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { return {}; }
}

export function createApp(store, cfg) {
  return async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    try {
      if (url.pathname === '/') {
        const html = await readFile(join(HERE, 'ui.html'), 'utf8');
        res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
        return res.end(html);
      }

      if (url.pathname === '/api/stats') {
        return json(res, {
          sessions: store.count(),
          projects: store.projects().length,
          activity: store.activityByDay(Date.now() - 14 * 864e5),
          platform: process.platform,
          projectsRoot: cfg.projectsRoot,
        });
      }

      if (url.pathname === '/api/projects') {
        return json(res, store.projects().map((p) => ({
          id: p.projectId,
          path: p.cwd || decodeProjectDir(p.projectId),
          name: displayName(p.cwd || decodeProjectDir(p.projectId)),
          count: p.n,
          lastActivity: p.last,
        })));
      }

      if (url.pathname === '/api/search') {
        const rows = store.search({
          query: url.searchParams.get('q') || '',
          projectId: url.searchParams.get('project') || null,
          since: url.searchParams.get('since') ? Number(url.searchParams.get('since')) : null,
          limit: Math.min(200, Number(url.searchParams.get('limit') || 60)),
        });
        return json(res, rows.map(shapeSession));
      }

      if (url.pathname === '/api/session') {
        const row = store.get(url.searchParams.get('id'));
        if (!row) return json(res, { error: 'not found' }, 404);
        const turns = await loadTurns(row.filePath);
        return json(res, { ...shapeSession(row), turns });
      }

      if (url.pathname === '/api/open' && req.method === 'POST') {
        const body = await readBody(req);
        const row = store.get(body.id);
        if (!row) return json(res, { error: 'not found' }, 404);
        // `claude --resume` looks for the transcript on disk, so a session Claude Code has
        // cleaned up has to be put back before it can be resumed.
        await restore(cfg.supportDir, cfg.projectsRoot, row.projectId, row.sessionId);
        const how = openSession({
          cwd: row.cwd, sessionId: row.sessionId, claude: cfg.claude,
        });
        return json(res, { ok: true, ...how });
      }

      if (url.pathname === '/api/retention') {
        if (req.method === 'POST') {
          await setRetentionDays(FOREVER);
          return json(res, { days: FOREVER, ...(await archiveSize(cfg.supportDir)) });
        }
        return json(res, {
          days: await currentRetentionDays(),
          ...(await archiveSize(cfg.supportDir)),
        });
      }

      if (url.pathname === '/api/reveal' && req.method === 'POST') {
        const body = await readBody(req);
        const row = store.get(body.id);
        revealFolder(row?.cwd);
        return json(res, { ok: true });
      }

      if (url.pathname === '/api/rescan' && req.method === 'POST') {
        const result = await reindex(store, cfg.projectsRoot, () => {}, cfg.supportDir);
        return json(res, result);
      }

      res.writeHead(404).end('not found');
    } catch (error) {
      json(res, { error: String(error && error.message || error) }, 500);
    }
  };
}

function shapeSession(r) {
  return {
    id: r.sessionId,
    projectId: r.projectId,
    project: displayName(r.cwd || decodeProjectDir(r.projectId)),
    cwd: r.cwd,
    branch: r.gitBranch,
    title: r.title || firstLine(r.firstMessage) || 'Untitled session',
    preview: r.firstMessage || '',
    snippet: r.snippet || null,
    messages: r.messageCount,
    lastActivity: r.lastActivity,
  };
}

function firstLine(text) {
  if (!text) return null;
  const line = text.split('\n').find((l) => l.trim());
  return line ? line.trim().slice(0, 120) : null;
}

/// The two sides of the conversation, nothing else — same rule as the macOS app.
async function loadTurns(filePath, maxTurns = 200) {
  const { humanText, assistantText } = await import('./lib/scanner.mjs');
  const text = await readFile(filePath, 'utf8').catch(() => '');
  const turns = [];
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    let obj;
    try { obj = JSON.parse(line); } catch { continue; }
    const at = obj.timestamp ? Date.parse(obj.timestamp) : null;
    if (obj.type === 'user') {
      const t = humanText(obj);
      if (t) turns.push({ role: 'you', text: t, at });
    } else if (obj.type === 'assistant') {
      const t = assistantText(obj);
      if (t) turns.push({ role: 'claude', text: t, at });
    }
  }
  return turns.slice(-maxTurns);
}

export async function main() {
  const cfg = config();
  const store = new IndexStore(join(cfg.supportDir, 'index.sqlite'));

  process.stdout.write(`Sift · reading ${cfg.projectsRoot}\n`);
  const started = Date.now();
  const result = await reindex(store, cfg.projectsRoot, (done, total) => {
    process.stdout.write(`\r  indexing ${done}/${total}`);
  }, cfg.supportDir);
  process.stdout.write(`\r  ${result.total} sessions, ${result.indexed} updated in ${Date.now() - started} ms\n`);
  const retention = await currentRetentionDays();
  if (retention < 3650) {
    process.stdout.write(`  Claude Code removes transcripts after ${retention} days; Sift keeps its own copy\n`);
  }

  const server = createServer(createApp(store, cfg));
  server.listen(cfg.port, '127.0.0.1', () => {
    const address = `http://127.0.0.1:${cfg.port}`;
    process.stdout.write(`  ready on ${address}\n`);
    if (cfg.open) {
      const opener = isWindows ? ['cmd', ['/c', 'start', '', address]] : ['open', [address]];
      spawn(opener[0], opener[1], { detached: true, stdio: 'ignore' }).unref();
    }
  });
}

if (import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith('sift.mjs')) {
  main();
}
