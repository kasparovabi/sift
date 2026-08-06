import { spawn } from 'node:child_process';
import { writeFileSync, chmodSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir, homedir } from 'node:os';
import { randomUUID } from 'node:crypto';

export const isWindows = process.platform === 'win32';

/// Argument-safe quoting per platform. The session id comes from a filename and the cwd
/// from the transcript, so neither is trusted enough to interpolate raw.
export function quoteForShell(token, windows = isWindows) {
  if (windows) return `'${String(token).replace(/'/g, "''")}'`;   // PowerShell single-quote
  return `'${String(token).replace(/'/g, `'\\''`)}'`;             // POSIX
}

/// A session goes back to whichever agent wrote it, by the id its own transcript records:
/// `claude --resume <id>`, or `codex resume <id>`. claude is a path Sift resolved; codex
/// comes off PATH, which the shell running this has already set up.
function program(agent, claude, windows) {
  return quoteForShell(agent === 'codex' ? 'codex' : claude, windows);
}

function resumeFlags(agent, sessionId, windows) {
  const [flag, id] = agent === 'codex' ? ['resume', sessionId] : ['--resume', sessionId];
  return `${flag} ${quoteForShell(id, windows)}`;
}

export function powershellCommand({ claude = 'claude', cwd, sessionId, agent = 'claude' }) {
  const parts = [`Set-Location ${quoteForShell(cwd, true)}`];
  parts.push(sessionId
    ? `& ${program(agent, claude, true)} ${resumeFlags(agent, sessionId, true)}`
    : `& ${program(agent, claude, true)}`);
  return parts.join('; ');
}

export function posixScript({ claude = 'claude', cwd, sessionId, agent = 'claude' }) {
  const run = sessionId
    ? `exec ${program(agent, claude, false)} ${resumeFlags(agent, sessionId, false)}`
    : `exec ${program(agent, claude, false)}`;
  return `#!/bin/sh\ncd ${quoteForShell(cwd, false)} || exit 1\n${run}\n`;
}

/// Opens a session in a real terminal. Windows Terminal when it is there, because it is
/// what ships with Windows 11 and keeps the window open; otherwise a plain PowerShell
/// window, which every Windows has.
export function openSession({ cwd, sessionId, claude = 'claude', agent = 'claude' }) {
  const dir = cwd && cwd.length ? cwd : homedir();

  if (isWindows) {
    const command = powershellCommand({ claude, cwd: dir, sessionId, agent });
    const psArgs = ['-NoExit', '-NoLogo', '-Command', command];
    const child = spawn('wt.exe', ['-d', dir, 'powershell', ...psArgs], {
      detached: true, stdio: 'ignore', windowsHide: false,
    });
    child.on('error', () => {
      spawn('powershell.exe', psArgs, { detached: true, stdio: 'ignore' }).unref();
    });
    child.unref();
    return { via: 'windows-terminal' };
  }

  // macOS: hand Terminal.app a throwaway script. Driving it with AppleScript instead
  // makes macOS ask for Automation permission on the first session anyone opens.
  const script = join(tmpdir(), `sift-session-${randomUUID()}.command`);
  writeFileSync(script, posixScript({ claude, cwd: dir, sessionId, agent }));
  chmodSync(script, 0o755);
  spawn('open', ['-a', 'Terminal', script], { detached: true, stdio: 'ignore' }).unref();
  return { via: 'terminal' };
}

export function revealFolder(path) {
  const target = path && path.length ? path : homedir();
  if (isWindows) {
    spawn('explorer.exe', [target], { detached: true, stdio: 'ignore' }).unref();
  } else {
    spawn('open', [target], { detached: true, stdio: 'ignore' }).unref();
  }
}
