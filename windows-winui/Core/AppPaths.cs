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

    public static Result Reindex(IndexStore store, string projectsRoot, Action<int, int>? progress = null)
    {
        var found = Scanner.ListTranscripts(projectsRoot);
        var known = store.Fingerprints();
        var indexed = 0;

        for (var i = 0; i < found.Count; i++)
        {
            var file = found[i];
            if (known.TryGetValue(file.FilePath, out var seen) &&
                seen.Size == file.Size && seen.Mtime == file.Mtime) continue;
            try
            {
                var row = Scanner.ParseTranscript(file.FilePath);
                row.ProjectId = file.ProjectId;
                row.FileSize = file.Size;
                row.FileMtime = file.Mtime;
                store.Upsert(row);
                indexed++;
            }
            catch (IOException) { /* a transcript being written right now */ }
            if (i % 100 == 0) progress?.Invoke(i, found.Count);
        }

        var removed = store.RemoveMissing(found.Select(f => f.FilePath));
        return new Result(found.Count, indexed, removed);
    }
}
