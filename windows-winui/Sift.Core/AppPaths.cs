using System.IO;

namespace SiftWinUI.Core;

/// Where Sift reads transcripts from and writes its index to. Both are overridable by
/// environment variable so a run can be pointed at throwaway data, which is how the
/// screenshots are made without putting anyone's real session titles on the internet.
public static class AppPaths
{
    public const string ProjectsRootKey = "SIFT_PROJECTS_ROOT";
    public const string SupportDirKey = "SIFT_SUPPORT_DIR";

    public static string ProjectsRoot => Resolve(ProjectsRootKey)
        ?? Path.Combine(Home, ".claude", "projects");

    public static string SupportDir => Resolve(SupportDirKey)
        ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Sift");

    public static string IndexPath => Path.Combine(SupportDir, "index.sqlite");

    public static string ClaudeCommand =>
        Environment.GetEnvironmentVariable("SIFT_CLAUDE") is { Length: > 0 } c ? c : "claude";

    private static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    public static string? Resolve(string key, IDictionary<string, string>? env = null)
    {
        var raw = env is null
            ? Environment.GetEnvironmentVariable(key)
            : (env.TryGetValue(key, out var v) ? v : null);
        raw = raw?.Trim();
        return string.IsNullOrEmpty(raw) ? null : Environment.ExpandEnvironmentVariables(raw);
    }
}

/// Indexes every transcript that changed since last time. Unchanged files are skipped on
/// (size, mtime), so a rescan over thousands of sessions costs almost nothing.
public static class Indexer
{
    public sealed record Result(int Total, int Indexed, int Removed);

    /// `codexRoot` is a parameter rather than a constant so a run can be pointed at
    /// throwaway data, the same way the projects root can. Left to the default it reads
    /// wherever Codex actually writes.
    public static Result Reindex(IndexStore store, string projectsRoot,
                                 Action<int, int>? progress = null, string? codexRoot = null)
    {
        var found = Scanner.ListTranscripts(projectsRoot);
        found.AddRange(Codex.ListTranscripts(codexRoot ?? Codex.Root));
        var known = store.Fingerprints();
        var indexed = 0;
        // Files that parsed to nothing must not look like sessions that vanished on the next
        // pass, so they are held back from the present-paths set rather than deleted from it.
        var skipped = new HashSet<string>();

        for (var i = 0; i < found.Count; i++)
        {
            var file = found[i];
            if (known.TryGetValue(file.FilePath, out var seen) &&
                seen.Size == file.Size && seen.Mtime == file.Mtime) continue;
            try
            {
                SessionRow? row;
                if (file.ProjectId == "codex")
                {
                    // Null means a thread Codex spawned for itself, or a rollout with nothing
                    // anyone said in it. Neither is a session, so it never enters the index.
                    row = Codex.ParseTranscript(file.FilePath);
                    if (row is null) { skipped.Add(file.FilePath); continue; }
                    row.Agent = Agent.Codex;
                }
                else
                {
                    row = Scanner.ParseTranscript(file.FilePath);
                    row.ProjectId = file.ProjectId;
                }
                row.FileSize = file.Size;
                row.FileMtime = file.Mtime;
                store.Upsert(row);
                indexed++;
            }
            catch (IOException) { /* a transcript being written right now */ }
            if (i % 100 == 0) progress?.Invoke(i, found.Count);
        }

        var removed = store.RemoveMissing(
            found.Select(f => f.FilePath).Where(p => !skipped.Contains(p)));
        return new Result(found.Count, indexed, removed);
    }
}
