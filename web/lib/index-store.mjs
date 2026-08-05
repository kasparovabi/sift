import { DatabaseSync } from 'node:sqlite';
import { mkdirSync, existsSync } from 'node:fs';
import { dirname } from 'node:path';

/// The same shape the macOS app keeps: a session table plus an FTS5 mirror, with the
/// transcripts on disk staying the source of truth. Delete the file and it rebuilds.
///
/// The FTS table keeps its own copy of the text rather than using `content=''`. A
/// contentless table cannot return its columns, so the delete-then-insert an update needs
/// has nothing to delete with, and feeding it the wrong values corrupts the index outright
/// ("database disk image is malformed"). Storing the text is what makes the index large,
/// and that is the trade this tool is built on anyway.
export class IndexStore {
  constructor(path) {
    if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
    this.db = new DatabaseSync(path);
    this.db.exec('PRAGMA journal_mode = WAL');
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS session (
        sessionId TEXT PRIMARY KEY, projectId TEXT NOT NULL, filePath TEXT NOT NULL,
        cwd TEXT, gitBranch TEXT, title TEXT, firstMessage TEXT, entrypoint TEXT,
        version TEXT, startedAt INTEGER, lastActivity INTEGER,
        messageCount INTEGER NOT NULL DEFAULT 0, toolCallCount INTEGER NOT NULL DEFAULT 0,
        fileSize INTEGER NOT NULL, fileMtime INTEGER NOT NULL,
        archived INTEGER NOT NULL DEFAULT 0
      );
      CREATE INDEX IF NOT EXISTS session_project ON session(projectId);
      CREATE INDEX IF NOT EXISTS session_activity ON session(lastActivity);
      CREATE VIRTUAL TABLE IF NOT EXISTS session_ft USING fts5(
        sessionId UNINDEXED, title, firstMessage, fullText,
        tokenize='unicode61', prefix='2 3'
      );
    `);
  }

  close() { this.db.close(); }

  fingerprints() {
    const rows = this.db.prepare('SELECT filePath, fileSize, fileMtime FROM session').all();
    return new Map(rows.map((r) => [r.filePath, { size: r.fileSize, mtime: r.fileMtime }]));
  }

  upsert(row, project) {
    this.db.prepare(`
      INSERT INTO session (sessionId, projectId, filePath, cwd, gitBranch, title, firstMessage,
                           entrypoint, version, startedAt, lastActivity, messageCount,
                           toolCallCount, fileSize, fileMtime)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(sessionId) DO UPDATE SET
        projectId=excluded.projectId, filePath=excluded.filePath, cwd=excluded.cwd,
        gitBranch=excluded.gitBranch, title=excluded.title, firstMessage=excluded.firstMessage,
        entrypoint=excluded.entrypoint, version=excluded.version, startedAt=excluded.startedAt,
        lastActivity=excluded.lastActivity, messageCount=excluded.messageCount,
        toolCallCount=excluded.toolCallCount, fileSize=excluded.fileSize, fileMtime=excluded.fileMtime
    `).run(row.sessionId, project, row.filePath, row.cwd, row.gitBranch, row.title,
           row.firstMessage, row.entrypoint, row.version, row.startedAt, row.lastActivity,
           row.messageCount, row.toolCallCount, row.fileSize, row.fileMtime);

    this.db.prepare('DELETE FROM session_ft WHERE sessionId = ?').run(row.sessionId);
    this.db.prepare('INSERT INTO session_ft(sessionId, title, firstMessage, fullText) VALUES (?,?,?,?)')
      .run(row.sessionId, row.title ?? '', row.firstMessage ?? '', row.fullText ?? '');
  }

  /// A transcript that has left ~/.claude/projects is not necessarily gone: if it was
  /// archived, the row survives pointing at the archived copy. Only a session with no
  /// archived copy is dropped. Returns how many rows moved to the archive.
  repointMissing(presentPaths, archivePathFor) {
    const present = new Set(presentPaths);
    const rows = this.db.prepare('SELECT sessionId, projectId, filePath FROM session').all();
    let repointed = 0;
    for (const r of rows) {
      if (present.has(r.filePath)) continue;
      const archived = archivePathFor(r.projectId, r.sessionId);
      if (existsSync(archived)) {
        this.db.prepare('UPDATE session SET filePath = ?, archived = 1 WHERE sessionId = ?')
          .run(archived, r.sessionId);
        repointed += 1;
        continue;
      }
      this.db.prepare('DELETE FROM session_ft WHERE sessionId = ?').run(r.sessionId);
      this.db.prepare('DELETE FROM session WHERE sessionId = ?').run(r.sessionId);
    }
    return repointed;
  }

  removeMissing(presentPaths) {
    const present = new Set(presentPaths);
    const rows = this.db.prepare('SELECT sessionId, filePath FROM session').all();
    let removed = 0;
    for (const r of rows) {
      if (present.has(r.filePath)) continue;
      this.db.prepare('DELETE FROM session_ft WHERE sessionId = ?').run(r.sessionId);
      this.db.prepare('DELETE FROM session WHERE sessionId = ?').run(r.sessionId);
      removed += 1;
    }
    return removed;
  }

  count() {
    return this.db.prepare('SELECT count(*) n FROM session').get().n;
  }

  projects() {
    return this.db.prepare(`
      SELECT projectId, count(*) n, max(lastActivity) last,
             (SELECT cwd FROM session s2 WHERE s2.projectId = s1.projectId AND cwd IS NOT NULL LIMIT 1) cwd
      FROM session s1 GROUP BY projectId ORDER BY last DESC
    `).all();
  }

  /// Ranked search. The column weights put a title match above a body match, the same
  /// ordering the macOS app uses. Column 3 is fullText, which is what a snippet comes from.
  search({ query = '', projectId = null, since = null, limit = 60 } = {}) {
    const trimmed = query.trim();

    if (!trimmed) {
      const where = [];
      const args = [];
      if (projectId) { where.push('projectId = ?'); args.push(projectId); }
      if (since) { where.push('lastActivity >= ?'); args.push(since); }
      return this.db.prepare(`
        SELECT * FROM session ${where.length ? 'WHERE ' + where.join(' AND ') : ''}
        ORDER BY lastActivity DESC LIMIT ?
      `).all(...args, limit).map((r) => ({ ...r, snippet: null }));
    }

    const args = [ftsQuery(trimmed)];
    const where = [];
    if (projectId) { where.push('s.projectId = ?'); args.push(projectId); }
    if (since) { where.push('s.lastActivity >= ?'); args.push(since); }
    args.push(limit);

    return this.db.prepare(`
      SELECT s.*,
             snippet(session_ft, 3, '', '', '…', 12) AS snippet,
             bm25(session_ft, 0.0, 5.0, 2.0, 1.0) AS rank
      FROM session_ft
      JOIN session s ON s.sessionId = session_ft.sessionId
      WHERE session_ft MATCH ? ${where.length ? 'AND ' + where.join(' AND ') : ''}
      ORDER BY rank
      LIMIT ?
    `).all(...args);
  }

  get(sessionId) {
    return this.db.prepare('SELECT * FROM session WHERE sessionId = ?').get(sessionId);
  }

  activityByDay(sinceMs) {
    return this.db.prepare(`
      SELECT date(lastActivity / 1000, 'unixepoch', 'localtime') AS day, count(*) n
      FROM session WHERE lastActivity IS NOT NULL AND lastActivity >= ?
      GROUP BY day
    `).all(sinceMs);
  }
}

/// Turns what someone typed into an FTS5 expression: every word a prefix match, with the
/// characters that carry meaning to FTS5 stripped so a stray quote cannot be a syntax error.
export function ftsQuery(input) {
  const words = input.replace(/["*]/g, ' ').split(/\s+/).filter(Boolean);
  if (!words.length) return '""';
  return words.map((w) => `"${w}"*`).join(' AND ');
}
