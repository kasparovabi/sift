import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, mkdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { humanText, assistantText, parseTranscript, listTranscripts, decodeProjectDir, displayName }
  from '../lib/scanner.mjs';
import { IndexStore, ftsQuery } from '../lib/index-store.mjs';
import { quoteForShell, powershellCommand, posixScript } from '../lib/terminal.mjs';
import { reindex, config } from '../sift.mjs';
import * as codex from '../lib/codex.mjs';
import { archiveSize, restore, archivePathFor } from '../lib/archive.mjs';
import { existsSync } from 'node:fs';

/// A test that indexes a fixture must not also read the machine's own Codex sessions.
const NO_CODEX = join(tmpdir(), 'sift-no-codex');

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), 'sift-web-'));
  const projects = join(root, 'projects');
  const dir = join(projects, '-Users-alex-code-orbit-api');
  await mkdir(dir, { recursive: true });
  const lines = [
    { type: 'user', uuid: 'u1', sessionId: 's1', cwd: '/Users/alex/code/orbit-api',
      gitBranch: 'main', entrypoint: 'cli', timestamp: '2026-08-01T10:00:00.000Z',
      message: { role: 'user', content: 'offset pagination is slow past page 200' } },
    { type: 'assistant', uuid: 'a1', timestamp: '2026-08-01T10:00:20.000Z',
      message: { role: 'assistant', content: [{ type: 'text', text: 'Switched to keyset pagination.' }] } },
    { type: 'assistant', uuid: 'a2', timestamp: '2026-08-01T10:00:25.000Z',
      message: { role: 'assistant', content: [{ type: 'tool_use', name: 'Bash' }] } },
    { type: 'user', uuid: 'u2', timestamp: '2026-08-01T10:00:30.000Z',
      message: { role: 'user', content: [{ type: 'tool_result', content: 'exit 0' }] } },
    { type: 'user', uuid: 'u3', timestamp: '2026-08-01T10:00:40.000Z',
      message: { role: 'user', content: '<system-reminder>be careful</system-reminder>' } },
    { type: 'ai-title', uuid: 't1', title: 'Cursor pagination for events' },
  ];
  await writeFile(join(dir, 's1.jsonl'), lines.map((l) => JSON.stringify(l)).join('\n') + '\n');
  return { root, projects, dir };
}

test('a transcript yields only what the two sides said', async () => {
  const { root, dir } = await fixture();
  const meta = await parseTranscript(join(dir, 's1.jsonl'));
  assert.equal(meta.sessionId, 's1');
  assert.equal(meta.cwd, '/Users/alex/code/orbit-api');
  assert.equal(meta.gitBranch, 'main');
  assert.equal(meta.title, 'Cursor pagination for events');
  assert.equal(meta.messageCount, 2, 'the tool result and the reminder are not messages');
  assert.equal(meta.toolCallCount, 1);
  assert.match(meta.fullText, /keyset pagination/);
  assert.doesNotMatch(meta.fullText, /system-reminder/);
  await rm(root, { recursive: true, force: true });
});

test('tool results and injected reminders are not user messages', () => {
  assert.equal(humanText({ message: { content: [{ type: 'tool_result', content: 'x' }] } }), null);
  assert.equal(humanText({ message: { content: '<system-reminder>x</system-reminder>' } }), null);
  assert.equal(humanText({ message: { content: '<local-command-stdout>x</local-command-stdout>' } }), null);
  assert.equal(humanText({ isMeta: true, message: { content: 'hi' } }), null);
  assert.equal(humanText({ message: { content: 'real question' } }), 'real question');
});

test('a turn that is only a tool call has nothing to show', () => {
  assert.equal(assistantText({ message: { content: [{ type: 'tool_use', name: 'Bash' }] } }), null);
  assert.equal(assistantText({ message: { content: [{ type: 'text', text: 'ok' },
                                                    { type: 'tool_use', name: 'Bash' }] } }), 'ok');
});

test('search ranks, snippets, and matches prefixes', async () => {
  const { root, projects } = await fixture();
  const store = new IndexStore(':memory:');
  const result = await reindex(store, projects, () => {}, null, NO_CODEX);
  assert.equal(result.total, 1);
  assert.equal(result.indexed, 1);

  const hits = store.search({ query: 'pagination' });
  assert.equal(hits.length, 1);
  assert.match(hits[0].snippet, /pagination/i);

  assert.equal(store.search({ query: 'pagin' }).length, 1, 'prefix search');
  assert.equal(store.search({ query: 'kubernetes' }).length, 0);
  assert.equal(store.search({ query: '' }).length, 1, 'an empty query lists recent sessions');
  store.close();
  await rm(root, { recursive: true, force: true });
});

test('a rescan neither duplicates nor re-reads unchanged files', async () => {
  const { root, projects, dir } = await fixture();
  const store = new IndexStore(':memory:');
  await reindex(store, projects, () => {}, null, NO_CODEX);

  const second = await reindex(store, projects, () => {}, null, NO_CODEX);
  assert.equal(second.indexed, 0, 'unchanged files are skipped on size and mtime');
  assert.equal(store.count(), 1);
  assert.equal(store.search({ query: 'pagination' }).length, 1, 'contentless FTS must not double up');

  // Change the file: the row is replaced, not added to.
  await writeFile(join(dir, 's1.jsonl'), JSON.stringify({
    type: 'user', sessionId: 's1', cwd: '/Users/alex/code/orbit-api',
    timestamp: '2026-08-02T10:00:00.000Z',
    message: { role: 'user', content: 'a completely different subject: kubernetes' },
  }) + '\n');
  const third = await reindex(store, projects, () => {}, null, NO_CODEX);
  assert.equal(third.indexed, 1);
  assert.equal(store.count(), 1);
  assert.equal(store.search({ query: 'pagination' }).length, 0, 'the old text is gone from the index');
  assert.equal(store.search({ query: 'kubernetes' }).length, 1);
  store.close();
  await rm(root, { recursive: true, force: true });
});

test('a deleted transcript leaves the index when nothing archived it', async () => {
  const { root, projects, dir } = await fixture();
  const store = new IndexStore(':memory:');
  await reindex(store, projects, () => {}, null, NO_CODEX);
  await rm(join(dir, 's1.jsonl'));
  const result = await reindex(store, projects, () => {}, null, NO_CODEX);
  assert.equal(result.vanished, 1);
  assert.equal(store.count(), 0);
  store.close();
  await rm(root, { recursive: true, force: true });
});

test('an archived transcript survives Claude Code deleting it', async () => {
  const { root, projects, dir } = await fixture();
  const support = join(root, 'support');
  const store = new IndexStore(':memory:');

  const first = await reindex(store, projects, () => {}, support, NO_CODEX);
  assert.equal(first.archived, 1, 'indexing keeps a copy');

  // Claude Code cleans the transcript up.
  await rm(join(dir, 's1.jsonl'));

  const second = await reindex(store, projects, () => {}, support, NO_CODEX);
  assert.equal(second.vanished, 1, 'the row moved to the archive rather than being dropped');
  assert.equal(store.count(), 1, 'the session is still in the index');

  const hits = store.search({ query: 'pagination' });
  assert.equal(hits.length, 1, 'and still searchable');
  assert.equal(hits[0].archived, 1);
  assert.ok(hits[0].filePath.includes('archive'), 'reading it now comes from the archive');
  assert.ok(existsSync(hits[0].filePath));

  const { files } = await archiveSize(support);
  assert.equal(files, 1);
  store.close();
  await rm(root, { recursive: true, force: true });
});

test('a cleaned-up session can be put back so it resumes', async () => {
  const { root, projects, dir } = await fixture();
  const support = join(root, 'support');
  const store = new IndexStore(':memory:');
  await reindex(store, projects, () => {}, support, NO_CODEX);

  const original = join(dir, 's1.jsonl');
  await rm(original);
  assert.equal(existsSync(original), false);

  const restored = await restore(support, projects, '-Users-alex-code-orbit-api', 's1');
  assert.equal(restored, original, 'claude --resume looks for it on disk, so it goes back');
  assert.equal(existsSync(original), true);
  store.close();
  await rm(root, { recursive: true, force: true });
});

test('archiving twice does not copy twice', async () => {
  const { root, projects } = await fixture();
  const support = join(root, 'support');
  const store = new IndexStore(':memory:');
  await reindex(store, projects, () => {}, support, NO_CODEX);
  const again = await reindex(store, projects, () => {}, support, NO_CODEX);
  assert.equal(again.archived, 0, 'an unchanged transcript is already kept');
  store.close();
  await rm(root, { recursive: true, force: true });
});

test('a query cannot be a syntax error', () => {
  assert.equal(ftsQuery('rate limiter'), '"rate"* AND "limiter"*');
  assert.equal(ftsQuery('"unbalanced'), '"unbalanced"*');
  assert.equal(ftsQuery('  '), '""');
  const store = new IndexStore(':memory:');
  assert.doesNotThrow(() => store.search({ query: 'a "b* (c' }));
  store.close();
});

test('paths with quotes cannot break out of the launch command', () => {
  assert.equal(quoteForShell("it's", true), "'it''s'");
  assert.equal(quoteForShell("it's", false), "'it'\\''s'");

  const ps = powershellCommand({ claude: 'claude', cwd: "C:\\code\\it's", sessionId: 'abc-1' });
  assert.match(ps, /Set-Location 'C:\\code\\it''s'/);
  assert.match(ps, /--resume 'abc-1'/);

  const sh = posixScript({ claude: '/usr/bin/claude', cwd: '/tmp/a b', sessionId: 'x' });
  assert.match(sh, /^#!\/bin\/sh/);
  assert.match(sh, /cd '\/tmp\/a b' \|\| exit 1/);
});

test('project directory names decode back to something readable', () => {
  assert.equal(decodeProjectDir('-Users-alex-code-orbit-api'), '/Users/alex/code/orbit/api');
  assert.equal(displayName('/Users/alex/code/orbit-api'), 'orbit-api');
  assert.equal(displayName('/Users/alex/code/'), 'code');
});

test('data locations follow the platform and are overridable', () => {
  const overridden = config({ SIFT_PROJECTS_ROOT: '/tmp/p', SIFT_SUPPORT_DIR: '/tmp/s' });
  assert.equal(overridden.projectsRoot, '/tmp/p');
  assert.equal(overridden.supportDir, '/tmp/s');
  const plain = config({});
  assert.match(plain.projectsRoot, /[\\/]\.claude[\\/]projects$/);
  assert.ok(plain.port > 0);
});

async function codexFixture() {
  const root = await mkdtemp(join(tmpdir(), 'sift-codex-'));
  const day = join(root, 'sessions', '2026', '07', '14');
  await mkdir(day, { recursive: true });
  const meta = { timestamp: '2026-07-14T15:21:31.121Z', type: 'session_meta',
    payload: { id: 'x1', cwd: '/Users/alex/orbit', originator: 'Codex Desktop',
               cli_version: '0.144.2', git: { branch: 'main' } } };
  const say = (role, text) => ({ timestamp: '2026-07-14T15:22:00.000Z', type: 'response_item',
    payload: { type: 'message', role, content: [{ type: 'input_text', text }] } });

  await writeFile(join(day, 'rollout-real.jsonl'), [
    meta,
    say('developer', '<permissions instructions> read-only'),
    say('user', '# AGENTS.md instructions do the thing'),
    say('user', 'why is the build slow'),
    say('assistant', 'Nothing is cached.'),
    { timestamp: '2026-07-14T15:23:00.000Z', type: 'response_item',
      payload: { type: 'function_call', name: 'shell' } },
  ].map((l) => JSON.stringify(l)).join('\n'));

  await writeFile(join(day, 'rollout-sub.jsonl'), [
    { ...meta, payload: { ...meta.payload, thread_source: 'subagent', parent_thread_id: 'p1' } },
    say('user', 'judge this'),
  ].map((l) => JSON.stringify(l)).join('\n'));

  await writeFile(join(day, 'rollout-empty.jsonl'), JSON.stringify(meta));
  return { root, sessions: join(root, 'sessions') };
}

test('a Codex rollout yields only what the two sides said', async () => {
  const { root, sessions } = await codexFixture();
  const meta = await codex.parseTranscript(join(sessions, '2026/07/14/rollout-real.jsonl'));
  assert.equal(meta.sessionId, 'x1');
  assert.equal(meta.cwd, '/Users/alex/orbit');
  assert.equal(meta.gitBranch, 'main');
  assert.equal(meta.messageCount, 2, 'the developer turn and the AGENTS.md preamble are not messages');
  assert.equal(meta.toolCallCount, 1);
  assert.equal(meta.firstMessage, 'why is the build slow');
  assert.match(meta.fullText, /Nothing is cached/);
  await rm(root, { recursive: true, force: true });
});

test('a thread Codex spawned for itself is not a session', async () => {
  const { root, sessions } = await codexFixture();
  assert.equal(await codex.parseTranscript(join(sessions, '2026/07/14/rollout-sub.jsonl')), null);
  assert.equal(await codex.parseTranscript(join(sessions, '2026/07/14/rollout-empty.jsonl')), null);
  await rm(root, { recursive: true, force: true });
});

test('rollouts are found through the date nesting', async () => {
  const { root, sessions } = await codexFixture();
  const found = await codex.listTranscripts(sessions);
  assert.equal(found.length, 3);
  assert.ok(found.every((f) => f.projectId === 'codex'));
  assert.deepEqual(await codex.listTranscripts(join(root, 'nowhere')), []);
  await rm(root, { recursive: true, force: true });
});

test('one pass indexes both agents, and neither drops the other', async () => {
  const claude = await fixture();
  const { root: codexRoot, sessions } = await codexFixture();
  const store = new IndexStore(':memory:');

  const result = await reindex(store, claude.projects, () => {}, null, sessions);
  assert.equal(result.indexed, 2, 'one Claude session, one real Codex session');

  const all = store.search({ query: '' });
  assert.equal(all.length, 2);
  assert.deepEqual(new Set(all.map((r) => r.agent)), new Set(['claude', 'codex']));

  const hit = store.search({ query: 'cached' });
  assert.equal(hit.length, 1);
  assert.equal(hit[0].agent, 'codex');
  assert.equal(hit[0].cwd, '/Users/alex/orbit');

  // A second pass changes nothing and must not drop either side.
  const again = await reindex(store, claude.projects, () => {}, null, sessions);
  assert.equal(again.indexed, 0);
  assert.equal(store.count(), 2);

  store.close();
  await rm(claude.root, { recursive: true, force: true });
  await rm(codexRoot, { recursive: true, force: true });
});

test('a session opens in whichever agent wrote it', () => {
  const claude = powershellCommand({ claude: 'claude', cwd: 'C:\\code', sessionId: 'abc' });
  assert.match(claude, /--resume 'abc'/);

  const codexPs = powershellCommand({ claude: 'claude', cwd: 'C:\\code', sessionId: 'abc', agent: 'codex' });
  assert.match(codexPs, /& 'codex' resume 'abc'/);
  assert.doesNotMatch(codexPs, /claude/);

  const codexSh = posixScript({ claude: '/usr/bin/claude', cwd: '/tmp', sessionId: 'abc', agent: 'codex' });
  assert.match(codexSh, /exec 'codex' resume 'abc'/);
});

import * as emb from '../lib/embedder.mjs';

test('both embedding response shapes read, and neither hides a bad one', () => {
  assert.deepEqual(emb.vectors('{"embeddings":[[0.1,0.2],[0.3,0.4]]}', false), [[0.1, 0.2], [0.3, 0.4]]);
  assert.deepEqual(emb.vectors('{"data":[{"index":0,"embedding":[1,2,3]}]}', true), [[1, 2, 3]]);
  assert.deepEqual(emb.vectors('{"embedding":[0.5,0.5]}', false), [[0.5, 0.5]], 'legacy single vector');
  assert.throws(() => emb.vectors('nope', false));
  assert.throws(() => emb.vectors('{}', false));
});

test('model lists read in both shapes, and a chat model is not an embedding model', () => {
  assert.deepEqual(emb.models('{"models":[{"name":"llama3:8b"},{"name":"nomic-embed-text"}]}'),
                   ['llama3:8b', 'nomic-embed-text']);
  assert.deepEqual(emb.models('{"data":[{"id":"text-embedding-bge-m3"}]}'), ['text-embedding-bge-m3']);
  assert.deepEqual(emb.models('garbage'), []);

  assert.ok(emb.looksLikeEmbeddingModel('nomic-embed-text:latest'));
  assert.ok(emb.looksLikeEmbeddingModel('all-MiniLM-L6-v2'));
  assert.ok(!emb.looksLikeEmbeddingModel('llama3:8b'));
  assert.ok(!emb.looksLikeEmbeddingModel('qwen2.5-coder'));
});

test('a vector survives the round trip to disk', () => {
  const vector = [0.25, -0.5, 1, 0];
  assert.deepEqual(emb.fromBytes(emb.toBytes(vector)), vector);
  assert.deepEqual(emb.fromBytes(Buffer.alloc(0)), []);
  assert.deepEqual(emb.fromBytes(Buffer.from([1, 2, 3])), [], 'a truncated blob is not a vector');
});

test('cosine orders by closeness', () => {
  assert.equal(emb.cosine([1, 0, 0], [1, 0, 0]), 1);
  assert.equal(emb.cosine([1, 0, 0], [0, 1, 0]), 0);
  assert.equal(emb.cosine([1, 0, 0], [-1, 0, 0]), -1);
  assert.equal(emb.cosine([1, 0, 0], [0, 0, 0]), 0, 'a zero vector cannot be close to anything');
});

test('what both rankings agree on comes first', () => {
  const fused = emb.fuse(['b', 'a', 'c'], ['a', 'd', 'b']);
  assert.equal(fused[0], 'a');
  assert.deepEqual(new Set(fused), new Set(['a', 'b', 'c', 'd']), 'nothing is thrown away');
  assert.deepEqual(emb.fuse(['a', 'b'], []), ['a', 'b']);
  assert.deepEqual(emb.fuse([], []), []);
});

test('discovery skips a server with no embedding model and finds one that has it', async () => {
  const fake = async (url) => {
    if (url.includes('11434')) return { ok: true, text: async () => '{"models":[{"name":"llama3"}]}' };
    if (url.includes('1234')) return { ok: true, text: async () => '{"data":[{"id":"bge-m3"}]}' };
    throw new Error('refused');
  };
  const found = await emb.discover(fake);
  assert.equal(found.name, 'LM Studio');
  assert.equal(found.model, 'bge-m3');

  const nothing = await emb.discover(async () => { throw new Error('refused'); });
  assert.equal(nothing, null);
});
