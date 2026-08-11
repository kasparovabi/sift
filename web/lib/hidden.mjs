import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

/// Folders whose sessions you do not want to see. A harness that gives every run its own
/// directory produces hundreds of sessions nobody had and nobody will resume, and they crowd
/// out the ones you did have.
///
/// A list rather than a rule, because which folders are machinery is a judgement only the
/// person whose machine it is can make. Plain text, shared by all three versions of Sift.
export function hiddenProjectsPath(supportDir) {
  return join(supportDir, 'hidden-projects.txt');
}

export function hiddenProjects(supportDir) {
  const path = hiddenProjectsPath(supportDir);
  try {
    if (!existsSync(path)) return [];
    return readFileSync(path, 'utf8')
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line.length > 0 && !line.startsWith('#'))
      .map((line) => line.replace(/[\\/]+$/, ''));
  } catch {
    return [];
  }
}

/// True when `hidden` is the path itself or one of its ancestors, matched on whole path
/// components so hiding `A:\harness` does not also hide `A:\harness-notes`.
export function covers(hidden, path) {
  const candidate = String(path).replace(/[\\/]+$/, '');
  const lowerHidden = hidden.toLowerCase();
  const lowerCandidate = candidate.toLowerCase();
  if (lowerCandidate === lowerHidden) return true;
  if (lowerCandidate.length <= lowerHidden.length) return false;
  if (!lowerCandidate.startsWith(lowerHidden)) return false;
  const next = candidate[hidden.length];
  return next === '\\' || next === '/';
}

/// SQL that is false for a session under any hidden folder. Empty when nothing is hidden, so
/// the common case adds nothing to the query.
///
/// The wildcard comes after a separator, never straight after the name. Without that,
/// hiding `A:\harness` also hides `A:\harness-notes`, which is a different folder.
export function hiddenPredicate(hidden, table = 'session') {
  if (!hidden.length) return '';
  const column = `COALESCE(${table}.cwd, ${table}.projectId)`;
  const clauses = hidden.map((path) => {
    const quoted = path.replace(/'/g, "''");
    const escaped = quoted.replace(/\\/g, '\\\\').replace(/%/g, '\\%').replace(/_/g, '\\_');
    return `(${column} = '${quoted}' OR ` +
           `${column} LIKE '${escaped}\\\\%' ESCAPE '\\' OR ` +
           `${column} LIKE '${escaped}/%' ESCAPE '\\')`;
  });
  return `NOT (${clauses.join(' OR ')})`;
}
