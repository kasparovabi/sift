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

## Build

```powershell
dotnet publish SiftWinUI.csproj -c Release -r win-x64 -o publish
.\publish\Sift.exe
```

Republishing over a running copy fails with the DLL locked, so close the app first.

About 265 MB published, because the Windows App SDK and the .NET runtime ship inside it.
For a much smaller build on a machine that already has both, drop
`WindowsAppSDKSelfContained` and `SelfContained` from the `.csproj`.

## Prerequisites to build

- .NET SDK 8 or later
- Developer Mode enabled
- WinUI 3 templates: `dotnet new install Microsoft.WindowsAppSDK.WinUI.CSharp.Templates`

`winget install --id Microsoft.WinAppCli` gets the WinApp CLI, which the win-dev-skills
BuildAndRun workflow uses. Note the package id is `Microsoft.WinAppCli`, not the
`Microsoft.WinAppCLI` some docs give.

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

The project list is ordered by how much work is in each project, not by recency, and the
long tail is folded behind "Show all". A throwaway run leaves a project directory behind
exactly like a real one does: on the machine this was built against, 745 of 753 projects
held a single session each, which made a recency-ordered list useless.

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
