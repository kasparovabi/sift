using System.IO;
using System.Diagnostics;

namespace Sift.Core;

public static class Launcher
{
    /// PowerShell single-quoting. On Windows `claude` is a .ps1, so the session has to be
    /// opened through PowerShell; cmd cannot run it at all.
    public static string Quote(string token) => "'" + (token ?? "").Replace("'", "''") + "'";

    public static string ResumeCommand(string claude, string cwd, string? sessionId)
    {
        var run = sessionId is null
            ? $"& {Quote(claude)}"
            : $"& {Quote(claude)} --resume {Quote(sessionId)}";
        return $"Set-Location {Quote(cwd)}; {run}";
    }

    public static string QuickTaskCommand(string claude, string prompt) =>
        $"& {Quote(claude)} -p {Quote(prompt)}";

    /// Opens a session in a real terminal: Windows Terminal where it exists, because that
    /// is what ships with Windows 11, and a plain PowerShell window otherwise.
    public static void OpenSession(string claude, string cwd, string? sessionId)
    {
        var dir = Directory.Exists(cwd) ? cwd : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var command = ResumeCommand(claude, dir, sessionId);
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

    /// Runs a one-off `claude -p` and streams stdout back as it arrives.
    public static async Task RunQuickTask(string claude, string cwd, string prompt,
                                          Action<string> onLine, CancellationToken token)
    {
        var dir = Directory.Exists(cwd) ? cwd : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var info = new ProcessStartInfo("powershell.exe")
        {
            Arguments = $"-NoProfile -Command \"{QuickTaskCommand(claude, prompt).Replace("\"", "\\\"")}\"",
            WorkingDirectory = dir,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        using var process = new Process { StartInfo = info, EnableRaisingEvents = true };
        process.Start();

        // Killing the process is what "Stop" has to mean; without this the button only
        // stops the UI listening while claude keeps running and keeps spending tokens.
        await using var _ = token.Register(() => { try { process.Kill(entireProcessTree: true); } catch { } });

        while (await process.StandardOutput.ReadLineAsync(token) is { } line) onLine(line);
        await process.WaitForExitAsync(token);
    }
}
