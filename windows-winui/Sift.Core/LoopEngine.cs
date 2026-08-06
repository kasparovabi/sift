using System.Diagnostics;
using System.IO;

namespace SiftWinUI.Core;

/// Trigger, maker, a SEPARATE checker, evidence, repeat until done or out of attempts.
///
/// The checker being separate is the whole point: an agent asked to grade its own work
/// approves it. This one is told it did not do the work and that anything short of the
/// criterion, or any doubt, is a FAIL.
public sealed class LoopEngine
{
    private readonly LoopStore _store;
    private readonly string _claude;

    public LoopEngine(LoopStore store, string claude)
    {
        _store = store;
        _claude = claude;
    }

    public async Task RunAsync(LoopTask task, Action<string, string> log, CancellationToken token)
    {
        _store.ClearProofs(task.Id);
        var lastChecker = "";

        for (var attempt = 1; attempt <= Math.Max(1, task.MaxPasses); attempt++)
        {
            if (token.IsCancellationRequested) { Set(task, "stopped", attempt); return; }
            Set(task, "running", attempt);
            log("phase", $"Attempt {attempt} · maker running");

            var makerPrompt = attempt == 1 ? task.Prompt : $"""
                {task.Prompt}

                A previous attempt at this task was graded "not done" for this reason:
                {lastChecker}

                Take that feedback into account and finish the work.
                """;

            var maker = await Run(makerPrompt, task.Cwd, line => log("maker", line), token);
            if (token.IsCancellationRequested) { Set(task, "stopped", attempt); return; }

            Set(task, "checking", attempt);
            log("phase", $"Attempt {attempt} · checker grading");
            var (passed, checkerOutput) = await Check(task, maker, log, token);
            lastChecker = checkerOutput;
            log(passed ? "pass" : "fail", passed ? "PASS" : "FAIL");

            _store.Add(new Proof(task.Id, attempt, passed, maker, checkerOutput,
                                 DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()));

            if (passed) { Set(task, "passed", attempt); return; }
        }

        log("fail", "Out of attempts, did not pass.");
        Set(task, "failed", task.MaxPasses);
    }

    private void Set(LoopTask task, string state, int attempt)
    {
        task.State = state;
        task.LastAttempt = attempt;
        _store.Upsert(task);
    }

    private async Task<(bool, string)> Check(LoopTask task, string makerOutput,
                                             Action<string, string> log, CancellationToken token)
    {
        if (task.Check == CheckKind.Shell)
        {
            var (ok, output) = await RunShell(task.DoneWhen, task.Cwd, token);
            log("checker", output);
            return (ok, output);
        }

        var prompt = $"""
            You are an independent, sceptical quality checker. Verify that the work below
            MEETS the criterion; if it does not, catch that.

            CRITERION (definition of done):
            {task.DoneWhen}

            WORK PRODUCED:
            {makerOutput}

            Rules: you did not do this work, and your job is to audit it rather than approve
            it. If the criterion is not fully met, or you are unsure, answer FAIL. The FIRST
            line of your reply must be exactly PASS or FAIL, followed by one to three
            sentences of reasoning.
            """;
        var verdict = await Run(prompt, task.Cwd, line => log("checker", line), token);
        return (VerdictIsPass(verdict), verdict);
    }

    /// The first non-empty token decides, and anything that is not a clear PASS counts as
    /// FAIL, so an ambiguous grader never lets unfinished work through.
    public static bool VerdictIsPass(string verdict)
    {
        var first = verdict.Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "";
        return first.Trim().StartsWith("PASS", StringComparison.OrdinalIgnoreCase);
    }

    private async Task<string> Run(string prompt, string cwd, Action<string> onLine, CancellationToken token)
    {
        var text = new System.Text.StringBuilder();
        await Launcher.RunQuickTask(_claude, cwd, prompt, line =>
        {
            text.AppendLine(line);
            onLine(line);
        }, token);
        return text.ToString().Trim();
    }

    /// `doneWhen` as a shell command: tests, a linter, a file check. Exit 0 means done.
    public static async Task<(bool, string)> RunShell(string command, string cwd, CancellationToken token)
    {
        var dir = Directory.Exists(cwd) ? cwd : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var info = new ProcessStartInfo("powershell.exe")
        {
            Arguments = $"-NoProfile -Command \"{command.Replace("\"", "\\\"")}\"",
            WorkingDirectory = dir,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        using var process = new Process { StartInfo = info };
        process.Start();
        var output = await process.StandardOutput.ReadToEndAsync(token);
        var error = await process.StandardError.ReadToEndAsync(token);
        await process.WaitForExitAsync(token);
        var combined = (output + error).Trim();
        var label = $"exit {process.ExitCode}";
        return (process.ExitCode == 0, combined.Length == 0 ? label : label + "\n" + combined);
    }
}
