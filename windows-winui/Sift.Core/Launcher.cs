using System.IO;
using System.Diagnostics;

namespace SiftWinUI.Core;

public static class Launcher
{
    /// PowerShell single-quoting. On Windows `claude` is a .ps1, so the session has to be
    /// opened through PowerShell; cmd cannot run it at all.
    public static string Quote(string token) => "'" + (token ?? "").Replace("'", "''") + "'";

    /// A redirected pipe on Windows speaks the console code page, which for a Turkish machine
    /// is CP857: every non-ASCII letter Claude writes comes back mangled and gets stored that
    /// way. Both ends are pinned to UTF-8, PowerShell's included, or the text is corrupt
    /// before anything else touches it.
    public const string Utf8Prelude =
        "$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); ";

    /// Hands the session back to whichever agent wrote it, by the id its own transcript
    /// records: `claude --resume <id>`, or `codex resume <id>`.
    public static string ResumeCommand(string claude, string cwd, string? sessionId,
                                       Agent agent = Agent.ClaudeCode)
    {
        // claude is resolved to a path Sift knows; codex comes off PATH, which the shell
        // running this command has already set up.
        var program = agent == Agent.ClaudeCode ? Quote(claude) : Quote(agent.Command());
        var run = sessionId is null
            ? $"& {program}"
            // The id is quoted, the flag is not: a flag is ours and fixed, and quoting it
              // reads as an argument in some shells rather than an option.
            : $"& {program} {string.Join(" ", agent.ResumeArguments(sessionId).Select((a, i) => i == 0 ? a : Quote(a)))}";
        return $"Set-Location {Quote(cwd)}; {run}";
    }

    /// `claude -p` alone prints nothing until the whole run is over, which leaves a spinner
    /// and no idea whether anything is happening. The streaming format emits an event per
    /// step instead, so the work can be watched as it goes.
    public static string QuickTaskCommand(string claude, string prompt) =>
        $"& {Quote(claude)} -p {Quote(prompt)} --output-format stream-json --verbose";

    /// Opens a session in a real terminal: Windows Terminal where it exists, because that
    /// is what ships with Windows 11, and a plain PowerShell window otherwise.
    public static void OpenSession(string claude, string cwd, string? sessionId,
                                   Agent agent = Agent.ClaudeCode)
    {
        var dir = Directory.Exists(cwd) ? cwd : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var command = ResumeCommand(claude, dir, sessionId, agent);
        var psArgs = $"-NoExit -NoLogo -Command \"{command.Replace("\"", "\\\"")}\"";

        if (!TryStart("wt.exe", $"-d \"{dir}\" powershell {psArgs}"))
            TryStart("powershell.exe", psArgs);
    }

    public static void RevealFolder(string? path)
    {
        var dir = !string.IsNullOrWhiteSpace(path) && Directory.Exists(path)
            ? path : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        TryStart("explorer.exe", $"\"{dir}\"");
    }

    private static bool TryStart(string file, string args)
    {
        try
        {
            Process.Start(new ProcessStartInfo(file, args) { UseShellExecute = true });
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// Runs a one-off `claude -p`, reporting each step as it happens and returning the final
    /// answer. The two are separate because a loop's checker has to grade the answer, not the
    /// running commentary about how it was reached.
    public static async Task<string> RunQuickTask(string claude, string cwd, string prompt,
                                                  Action<string> onLine, CancellationToken token)
    {
        var dir = Directory.Exists(cwd) ? cwd : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var info = new ProcessStartInfo("powershell.exe")
        {
            Arguments = $"-NoProfile -Command \"{Utf8Prelude}{QuickTaskCommand(claude, prompt).Replace("\"", "\\\"")}\"",
            WorkingDirectory = dir,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = System.Text.Encoding.UTF8,
            StandardErrorEncoding = System.Text.Encoding.UTF8,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        using var process = new Process { StartInfo = info, EnableRaisingEvents = true };
        process.Start();

        // Killing the process is what "Stop" has to mean; without this the button only
        // stops the UI listening while claude keeps running and keeps spending tokens.
        await using var _ = token.Register(() => { try { process.Kill(entireProcessTree: true); } catch { } });

        var final = "";
        while (await process.StandardOutput.ReadLineAsync(token) is { } line)
        {
            var read = StreamEvents.Read(line);
            if (read.Display is { Length: > 0 } display) onLine(display);
            if (read.FinalResult is { } result) final = result;
        }
        await process.WaitForExitAsync(token);

        // A run that dies before emitting a result leaves the pane blank, and the reason is
        // on stderr: a missing claude, a bad flag, an auth failure.
        if (final.Length == 0)
        {
            var error = (await process.StandardError.ReadToEndAsync(token)).Trim();
            if (error.Length > 0) onLine(error);
        }
        return final;
    }
}
