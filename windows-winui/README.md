# Sift for Windows

A native Windows app: WinUI 3 on the Windows App SDK, published as a self-contained folder
with `SiftWinUI.exe` in it. No .NET or Windows App Runtime to install first.

The macOS app is SwiftUI, which does not exist on Windows, so this is a separate
implementation rather than a port. It reads the same transcripts, keeps the same SQLite
FTS5 index with the same BM25 column weights, and applies the same rule about what counts
as conversation.

Built with Microsoft's [win-dev-skills](https://github.com/microsoft/win-dev-skills)
toolchain, which is what the Fluent look comes from: Mica backdrop, the system title bar,
NavigationView, and real Fluent controls rather than hand-drawn approximations.

## Getting it

You build it once on your own machine. You do not need to know how to program.

**1. Install the tool you need.** Open PowerShell (Start button, type `PowerShell`, click
it) and paste this:

```powershell
winget install Microsoft.DotNet.SDK.8
```

Close PowerShell and open it again afterwards.

**2. Build it.** Paste these, one line at a time:

```powershell
git clone https://github.com/kasparovabi/sift.git
cd sift
dotnet publish windows-winui\SiftWinUI.csproj -c Release -r win-x64 -o publish
```

**3. Open it.** Double-click `Sift.exe` in the `publish` folder. Windows will warn that the
app is unrecognised, because it is not signed by a company: click **More info**, then **Run
anyway**.

Everything it needs is inside that folder, so it runs on a machine with nothing else
installed. That is why the folder is about 265 MB. Close the app before rebuilding, or the
publish fails with the file locked.

For a much smaller build on a machine that already has the .NET 8 desktop runtime and the
Windows App Runtime, drop `WindowsAppSDKSelfContained` and `SelfContained` from the
`.csproj`.

```powershell
dotnet test Sift.Tests\Sift.Tests.csproj
```

## What it does

- **Search** every session, ranked so a title match outranks a body match, with the matched
  run in context and prefix matching (`pagin` finds `pagination`).
- **Browse** by project or by what you did today.
- **Read** a session: what the two sides actually said, with tool calls, tool results and
  injected reminders left out.
- **Open in terminal** resumes it in its own working directory through PowerShell, because
  `claude` on Windows is a `.ps1` that cmd cannot run.
- **Quick task** runs a one-off `claude -p` in a folder and streams the answer back. Stop
  kills the process rather than just looking away from it.
- **Loops**: a maker does the work, a separate checker grades it against your definition of
  done, and it repeats until it passes or runs out of attempts. The checker can be an agent
  or a command whose exit code decides. Every attempt is kept as evidence.
- **Keeps your sessions.** See below.
- **Five appearances**, remembered between runs.

Projects are grouped by where they actually are on disk. Claude Code stores each session
under a directory name with every path separator replaced by a dash, so a scratch folder
inside a project looks like a separate top-level project. On the machine this was built
against that turned one project into 738: `A:\harness` plus 737 sandbox folders inside it.
Reading the real path back out of the session collapses 754 entries to 8.

## Unlimited retention

Claude Code deletes transcripts older than `cleanupPeriodDays`, 30 by default. A search tool
whose corpus evaporates after a month is not a search tool, so Sift does two things:

1. **Archives every transcript it indexes** into `%LOCALAPPDATA%\Sift\archive`, as the
   original `.jsonl`. A session Claude Code has since removed stays searchable and readable,
   and is marked "kept by Sift".
2. **Offers to turn the cleanup off**, writing `cleanupPeriodDays` in
   `~/.claude/settings.json` and backing the old file up as `settings.json.sift-backup`.
   Every other setting is left exactly as it was.

Resuming an archived session puts the transcript back where Claude Code expects it first,
because `claude --resume` looks for it on disk.

## Configuration

| Variable | Default |
|---|---|
| `SIFT_PROJECTS_ROOT` | `%USERPROFILE%\.claude\projects` |
| `SIFT_SUPPORT_DIR` | `%LOCALAPPDATA%\Sift` |
| `SIFT_CLAUDE` | `claude` |
