import { readdir, stat, open } from 'node:fs/promises';
import { join } from 'node:path';
import { homedir } from 'node:os';

export const AGENTS = { claude: 'Claude Code', codex: 'Codex' };

/// The executable and arguments that reopen one session by the id its own transcript records.
export function resumeArguments(agent, sessionId) {
  return agent === 'codex' ? ['resume', sessionId] : ['--resume', sessionId];
}

export function agentCommand(agent, claude) {
  return agent === 'codex' ? 'codex' : claude;
}

export function codexRoot(env = process.env) {
  return env.SIFT_CODEX_ROOT || join(homedir(), '.codex', 'sessions');
}

// Codex prepends its own preamble to the user's words. Left in, every session in a repository
// ends up with the same title.
const INJECTED = [
  '# AGENTS.md instructions', '<permissions instructions>', '<INSTRUCTIONS>',
  '<environment_context>', '<user_instructions>', '<recommended_plugins>',
];

/// A thread Codex spawned for itself, the equivalent of Claude Code's sidechains. On the
/// library this was built against, 64 of 76 rollouts were these.
export function isSubagent(meta) {
  return meta?.thread_source === 'subagent' ||
    (meta?.source !== undefined && meta?.parent_thread_id !== undefined);
}

function textOf(content) {
  if (typeof content === 'string') return content.trim();
  if (!Array.isArray(content)) return '';
  return content
    .filter((b) => b && ['input_text', 'output_text', 'text'].includes(b.type) && b.text)
    .map((b) => b.text)
    .join('\n')
    .trim();
}

/// Codex writes one JSONL per session under `~/.codex/sessions/YYYY/MM/DD/`, nested by date
/// rather than by project. Every line is {timestamp, type, payload}. Returns null when the
/// file is a thread Codex spawned for itself, or holds nothing anyone said.
export async function parseTranscript(filePath) {
  const handle = await open(filePath, 'r');
  // Every field the store binds has to exist. An undefined one makes node:sqlite throw,
  // and the caller's catch turns that into a session that silently never appears.
  const meta = {
    sessionId: null, filePath, cwd: null, gitBranch: null, entrypoint: null, version: null,
    title: null, firstMessage: null, fullText: '', startedAt: null, lastActivity: null,
    messageCount: 0, toolCallCount: 0, agent: 'codex',
  };
  const texts = [];
  let subagent = false;

  try {
    for await (const line of handle.readLines({ encoding: 'utf8' })) {
      if (!line.trim()) continue;
      let obj;
      try { obj = JSON.parse(line); } catch { continue; }
      if (!obj || typeof obj !== 'object') continue;

      const at = obj.timestamp ? Date.parse(obj.timestamp) : NaN;
      if (!Number.isNaN(at)) {
        meta.startedAt ??= at;
        meta.lastActivity = at;
      }
      const payload = obj.payload;
      if (!payload || typeof payload !== 'object') continue;

      if (obj.type === 'session_meta') {
        if (isSubagent(payload)) subagent = true;
        meta.sessionId = payload.id || payload.session_id || null;
        meta.cwd = payload.cwd || null;
        meta.entrypoint = payload.originator || null;
        meta.version = payload.cli_version || null;
        meta.gitBranch = payload.git?.branch || null;
        continue;
      }
      if (obj.type !== 'response_item') continue;
      if (payload.type === 'function_call') { meta.toolCallCount += 1; continue; }
      if (payload.type !== 'message') continue;

      // `developer` is the harness talking to the model about sandboxing and policy, not one
      // of the two sides of the conversation.
      const role = payload.role;
      if (role !== 'user' && role !== 'assistant') continue;
      const text = textOf(payload.content);
      if (!text) continue;
      if (role === 'user' && INJECTED.some((p) => text.startsWith(p))) continue;

      meta.messageCount += 1;
      texts.push(text);
      if (role === 'user' && meta.firstMessage === null) meta.firstMessage = text.slice(0, 400);
    }
  } finally {
    await handle.close();
  }

  if (subagent || meta.messageCount === 0) return null;
  meta.fullText = texts.join('\n');
  meta.title = meta.firstMessage ? meta.firstMessage.slice(0, 90) : null;
  meta.sessionId ??= filePath.split(/[\\/]/).pop().replace(/\.jsonl$/, '');
  return meta;
}

export async function listTranscripts(root) {
  const out = [];
  async function walk(dir) {
    let entries;
    try { entries = await readdir(dir, { withFileTypes: true }); } catch { return; }
    for (const entry of entries) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) { await walk(path); continue; }
      if (!entry.name.startsWith('rollout-') || !entry.name.endsWith('.jsonl')) continue;
      try {
        const s = await stat(path);
        out.push({ filePath: path, projectId: 'codex', size: s.size, mtime: Math.floor(s.mtimeMs) });
      } catch { /* it can vanish between the listing and the stat */ }
    }
  }
  await walk(root);
  return out;
}

/// The conversation, for the reader pane.
export async function loadTurns(filePath, maxTurns = 200) {
  const handle = await open(filePath, 'r');
  const turns = [];
  try {
    for await (const line of handle.readLines({ encoding: 'utf8' })) {
      if (turns.length >= maxTurns) break;
      if (!line.trim()) continue;
      let obj;
      try { obj = JSON.parse(line); } catch { continue; }
      if (obj?.type !== 'response_item' || obj.payload?.type !== 'message') continue;
      const role = obj.payload.role;
      if (role !== 'user' && role !== 'assistant') continue;
      const text = textOf(obj.payload.content);
      if (!text) continue;
      if (role === 'user' && INJECTED.some((p) => text.startsWith(p))) continue;
      turns.push({ role, text, at: obj.timestamp ? Date.parse(obj.timestamp) : null });
    }
  } finally {
    await handle.close();
  }
  return turns;
}
