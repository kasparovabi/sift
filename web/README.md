# Sift for Windows and Linux

The macOS app is SwiftUI, which does not exist off Apple platforms, so its interface could
not be carried over. What did carry over is the part that matters: read the transcripts
Claude Code already writes, keep a SQLite FTS5 index beside them, and hand a session back to
a real terminal. This serves that to a browser instead.

```sh
node web/sift.mjs
```

It indexes, opens `http://127.0.0.1:4319`, and that is the whole install. There are no
dependencies to fetch: SQLite ships inside Node 22 and later.

On a Windows machine with 1,067 transcripts the first index took 13 seconds, queries come
back in about 8 ms, and the index is 19.5 MB.

## What it does

- **Search** every session, ranked with BM25 so a title match outranks a body match, with
  the matched run shown in context.
- **Filter** by project from the sidebar.
- **Read** a session: only what the two sides actually said. Tool calls, tool results and
  injected reminders are not part of the conversation and are left out.
- **Open in terminal** hands the session to `claude --resume <id>` in its own working
  directory: Windows Terminal where it exists, PowerShell otherwise, Terminal.app on macOS.
- **Four themes**, matching the macOS app.

## Requirements

- Node 22 or later (`node --version`)
- [Claude Code](https://claude.com/claude-code), signed in
- Windows, Linux, or macOS

## Configuration

| Variable | Default |
|---|---|
| `SIFT_PROJECTS_ROOT` | `%USERPROFILE%\.claude\projects`, or `~/.claude/projects` |
| `SIFT_SUPPORT_DIR` | `%LOCALAPPDATA%\Sift`, `~/Library/Application Support/Sift`, or `$XDG_DATA_HOME/sift` |
| `SIFT_PORT` | `4319` |
| `SIFT_CLAUDE` | `claude` |
| `SIFT_NO_OPEN` | unset; `1` stops it opening a browser |

The server binds to `127.0.0.1` only.

## Unlimited retention

Claude Code deletes transcripts older than `cleanupPeriodDays`, 30 by default. A search tool
whose corpus evaporates after a month is not a search tool, so Sift archives every transcript
it indexes into `<support dir>/archive` as the original `.jsonl`. A session Claude Code has
since removed stays searchable and readable.

`GET /api/retention` reports the current setting and how much has been archived;
`POST /api/retention` sets `cleanupPeriodDays` to a hundred years, backing up the old
`settings.json` as `settings.json.sift-backup` and leaving every other setting alone.

Resuming an archived session puts the transcript back where Claude Code expects it first,
because `claude --resume` looks for it on disk.

## Notes

Sessions live one directory deep under the projects root. Anything nested below that is a
subagent or workflow transcript, marked `isSidechain`, and is machinery rather than a session
you had — on the machine this was built against that was 1,268 files that correctly stay out
of the index.

The index is a cache. Delete `index.sqlite` and the next run rebuilds it from the
transcripts, which stay the source of truth.

```sh
node --test web/test/sift.test.mjs
```
