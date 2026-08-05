import { createReadStream } from 'node:fs';
import { readdir, stat } from 'node:fs/promises';
import { join } from 'node:path';

/// Claude Code encodes a project's path into its directory name by turning separators
/// into dashes. The decode is lossy, which is why a session's own `cwd` field wins and
/// this is only the fallback.
export function decodeProjectDir(name) {
  return name.replace(/-/g, '/');
}

export function displayName(path) {
  const trimmed = path.endsWith('/') && path.length > 1 ? path.slice(0, -1) : path;
  const last = trimmed.split('/').filter(Boolean).pop();
  return last || trimmed;
}

const NOT_TYPED_BY_ANYONE = [
  '<command-', '<local-command', '<task-notification',
  '<scheduled-wakeup', '<background-task', '<system-reminder',
];

/// The text of a message a person actually typed, or null. Tool results arrive as "user"
/// messages and injected reminders look like them too; neither belongs in a transcript.
export function humanText(obj) {
  if (obj.isMeta || obj.isSidechain) return null;
  const content = obj.message?.content;
  let text;
  if (typeof content === 'string') {
    text = content;
  } else if (Array.isArray(content)) {
    const parts = content.filter((b) => b.type === 'text').map((b) => b.text);
    if (!parts.length) return null;
    text = parts.join('\n');
  } else {
    return null;
  }
  const trimmed = text.trim();
  if (!trimmed) return null;
  if (NOT_TYPED_BY_ANYONE.some((p) => trimmed.startsWith(p))) return null;
  return trimmed;
}

/// What the assistant said. A turn carrying only tool calls has no prose, so it yields
/// nothing rather than a placeholder.
export function assistantText(obj) {
  const content = obj.message?.content;
  if (typeof content === 'string') return content.trim() || null;
  if (!Array.isArray(content)) return null;
  const joined = content.filter((b) => b.type === 'text').map((b) => b.text).join('\n').trim();
  return joined || null;
}

export function hasToolUse(obj) {
  const content = obj.message?.content;
  return Array.isArray(content) && content.some((b) => b.type === 'tool_use');
}

const FULL_TEXT_CAP = 100_000;

/// Reads one transcript into the row the index stores. Streams the file so a 20 MB
/// session costs no more memory than a small one.
export async function parseTranscript(filePath) {
  const meta = {
    filePath,
    sessionId: null, cwd: null, gitBranch: null, entrypoint: null, version: null,
    title: null, firstMessage: null, startedAt: null, lastActivity: null,
    messageCount: 0, toolCallCount: 0, fullText: '',
  };
  let full = [];
  let fullLength = 0;

  for await (const line of readLines(filePath)) {
    let obj;
    try { obj = JSON.parse(line); } catch { continue; }

    meta.sessionId ??= obj.sessionId ?? null;
    meta.cwd ??= obj.cwd ?? null;
    meta.gitBranch ??= obj.gitBranch ?? null;
    meta.entrypoint ??= obj.entrypoint ?? null;
    meta.version ??= obj.version ?? null;

    const ts = obj.timestamp ? Date.parse(obj.timestamp) : NaN;
    if (!Number.isNaN(ts)) {
      meta.startedAt ??= ts;
      if (meta.lastActivity === null || ts > meta.lastActivity) meta.lastActivity = ts;
    }

    let text = null;
    if (obj.type === 'user') {
      text = humanText(obj);
      if (text) {
        meta.firstMessage ??= text.slice(0, 2000);
        meta.messageCount += 1;
      }
    } else if (obj.type === 'assistant') {
      if (hasToolUse(obj)) meta.toolCallCount += 1;
      // Counted only when the turn carries prose, so the number agrees with the transcript.
      text = assistantText(obj);
      if (text) meta.messageCount += 1;
    } else if (obj.type === 'ai-title') {
      meta.title = obj.title ?? meta.title;
    }

    if (text && fullLength < FULL_TEXT_CAP) {
      full.push(text);
      fullLength += text.length;
    }
  }

  meta.fullText = full.join('\n').slice(0, FULL_TEXT_CAP);
  if (!meta.sessionId) {
    meta.sessionId = filePath.split(/[\\/]/).pop().replace(/\.jsonl$/, '');
  }
  return meta;
}

async function* readLines(filePath) {
  let carry = '';
  for await (const chunk of createReadStream(filePath, { encoding: 'utf8' })) {
    const parts = (carry + chunk).split('\n');
    carry = parts.pop();
    for (const p of parts) if (p.trim()) yield p;
  }
  if (carry.trim()) yield carry;
}

/// Walks the projects root and returns one entry per transcript, with the fingerprint the
/// index uses to skip files that have not changed.
export async function listTranscripts(projectsRoot) {
  let dirs;
  try {
    dirs = await readdir(projectsRoot, { withFileTypes: true });
  } catch {
    return [];
  }
  const out = [];
  for (const dir of dirs) {
    if (!dir.isDirectory()) continue;
    const dirPath = join(projectsRoot, dir.name);
    let files;
    try { files = await readdir(dirPath); } catch { continue; }
    for (const file of files) {
      if (!file.endsWith('.jsonl')) continue;
      const filePath = join(dirPath, file);
      try {
        const s = await stat(filePath);
        out.push({
          filePath,
          projectId: dir.name,
          decodedPath: decodeProjectDir(dir.name),
          size: s.size,
          mtime: Math.floor(s.mtimeMs),
        });
      } catch { /* vanished between readdir and stat */ }
    }
  }
  return out;
}
