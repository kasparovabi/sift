import { copyFile, mkdir, stat, readFile, writeFile, readdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';

/// Claude Code deletes transcripts past `cleanupPeriodDays` (30 by default), which means
/// the corpus this tool searches quietly disappears from under it. Sift keeps its own copy
/// of everything it indexes, so a cleaned-up session stays searchable and readable.
///
/// The archive is a plain tree of the original .jsonl files: no format to migrate, and a
/// file can be put straight back where Claude Code expects it.
export function archiveRoot(supportDir) {
  return join(supportDir, 'archive');
}

/// Directory names come from Claude Code and session ids from filenames; a separator
/// slipping through would write outside the archive.
function sanitise(name) {
  return name.replace(/[<>:"|?*\\/]/g, '-').replace(/\.\./g, '-');
}

export function archivePathFor(supportDir, projectId, sessionId) {
  return join(archiveRoot(supportDir), sanitise(projectId), sanitise(sessionId) + '.jsonl');
}

/// Copies a transcript in unless an identical copy is already there.
export async function keep(supportDir, sourcePath, projectId, sessionId) {
  const target = archivePathFor(supportDir, projectId, sessionId);
  try {
    const source = await stat(sourcePath);
    try {
      const existing = await stat(target);
      if (existing.size === source.size && existing.mtimeMs >= source.mtimeMs) return false;
    } catch { /* not archived yet */ }
    await mkdir(dirname(target), { recursive: true });
    await copyFile(sourcePath, target);
    return true;
  } catch {
    return false;
  }
}

/// Puts a transcript back where Claude Code expects it, so `claude --resume` can find a
/// session that was cleaned up.
export async function restore(supportDir, projectsRoot, projectId, sessionId) {
  const archived = archivePathFor(supportDir, projectId, sessionId);
  if (!existsSync(archived)) return null;
  const target = join(projectsRoot, projectId, sessionId + '.jsonl');
  if (existsSync(target)) return target;
  try {
    await mkdir(dirname(target), { recursive: true });
    await copyFile(archived, target);
    return target;
  } catch {
    return null;
  }
}

export async function archiveSize(supportDir) {
  const root = archiveRoot(supportDir);
  let files = 0;
  let bytes = 0;
  try {
    for (const dir of await readdir(root, { withFileTypes: true })) {
      if (!dir.isDirectory()) continue;
      for (const name of await readdir(join(root, dir.name))) {
        if (!name.endsWith('.jsonl')) continue;
        files += 1;
        try { bytes += (await stat(join(root, dir.name, name))).size; } catch { /* raced */ }
      }
    }
  } catch { /* nothing archived yet */ }
  return { files, bytes };
}

/// Claude Code's own retention lives in ~/.claude/settings.json. Turning it off is what
/// stops the deletion happening at all; the archive covers what other machines remove.
export const settingsPath = () => join(homedir(), '.claude', 'settings.json');

export async function currentRetentionDays() {
  try {
    const value = JSON.parse(await readFile(settingsPath(), 'utf8')).cleanupPeriodDays;
    return Number.isInteger(value) ? value : 30;
  } catch {
    return 30;   // Claude Code's own default when unset
  }
}

export const FOREVER = 36500;

/// Rewrites only `cleanupPeriodDays`, keeping every other setting, after a backup.
export async function setRetentionDays(days) {
  const path = settingsPath();
  let settings = {};
  try {
    const text = await readFile(path, 'utf8');
    settings = JSON.parse(text);
    await writeFile(path + '.sift-backup', text);
  } catch { /* no settings file yet */ }
  settings.cleanupPeriodDays = days;
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, JSON.stringify(settings, null, 2) + '\n');
  return days;
}
