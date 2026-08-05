# Sift for Windows

A native Windows app: WPF on .NET 8, one `Sift.exe`, no runtime to install first.

The macOS app is SwiftUI, which does not exist on Windows, so this is a separate
implementation rather than a port. It reads the same transcripts, keeps the same kind of
SQLite FTS5 index with the same BM25 column weights, and shows the same thing.

## Build

```powershell
dotnet publish Sift\Sift.csproj -c Release -r win-x64 -o publish
.\publish\Sift.exe
```

That produces a self-contained single file, about 140 MB, that runs on a machine with no
.NET installed. For a much smaller build on a machine that already has the .NET 8 desktop
runtime:

```powershell
dotnet publish Sift\Sift.csproj -c Release -r win-x64 --self-contained false -o publish
```

```powershell
dotnet test Sift.Tests\Sift.Tests.csproj
```

## What it does

- **Search** every session, ranked so a title match outranks a body match, with the matched
  run shown in context. Prefix matching, so `pagin` finds `pagination`.
- **Browse** by project, or by what you did today.
- **Read** a session: what the two sides actually said. Tool calls, tool results and
  injected reminders are not conversation and are left out.
- **Open in terminal** resumes the session in its own working directory: Windows Terminal
  where it exists, PowerShell otherwise.
- **Quick task** runs a one-off `claude -p` in a folder and streams the answer back. Stop
  kills the process rather than just looking away from it.
- **Five themes**, remembered between runs.

Measured on a library of 1,067 transcripts: first index about 20 seconds, queries under a
millisecond, index 19.5 MB, around 150 MB of memory.

## Requirements

- Windows 10 or 11, x64
- [Claude Code](https://claude.com/claude-code), signed in
- .NET 8 SDK to build

`claude` on Windows is a PowerShell script rather than an executable, which is why sessions
are opened through PowerShell. `cmd` cannot run it.

## Configuration

| Variable | Default |
|---|---|
| `SIFT_PROJECTS_ROOT` | `%USERPROFILE%\.claude\projects` |
| `SIFT_SUPPORT_DIR` | `%LOCALAPPDATA%\Sift` |
| `SIFT_CLAUDE` | `claude` |

## Notes

Sessions live one directory deep under the projects root. Anything nested below that is a
subagent or workflow transcript, marked `isSidechain`; on the machine this was built against
that was 1,268 files that correctly stay out of the index.

The index is a cache. Delete `%LOCALAPPDATA%\Sift\index.sqlite` and the next run rebuilds it
from the transcripts, which stay the source of truth. A rescan skips files whose size and
modified time have not changed.

The executable is unsigned, so SmartScreen will warn the first time. Building it yourself is
the way around that.
