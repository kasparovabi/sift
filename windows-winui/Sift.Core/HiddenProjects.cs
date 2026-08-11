using System.IO;

namespace SiftWinUI.Core;

/// Folders whose sessions you do not want to see. A harness that gives every run its own
/// directory produces hundreds of sessions nobody had and nobody will resume, and they crowd
/// out the ones you did have.
///
/// A list rather than a rule, because which folders are machinery is a judgement only the
/// person whose machine it is can make. Plain text so it can be edited by hand, and shared
/// by all three versions of Sift.
public static class HiddenProjects
{
    public static string Path => System.IO.Path.Combine(AppPaths.SupportDir, "hidden-projects.txt");

    public static IReadOnlyList<string> All()
    {
        try
        {
            if (!File.Exists(Path)) return [];
            return File.ReadAllLines(Path)
                .Select(line => line.Trim())
                .Where(line => line.Length > 0 && !line.StartsWith('#'))
                .Select(line => line.TrimEnd('\\', '/'))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();
        }
        catch (IOException) { return []; }
    }

    public static bool IsHidden(string path) =>
        All().Any(hidden => Covers(hidden, path));

    /// True when `hidden` is the path itself or one of its ancestors, matched on whole path
    /// components so hiding `A:\harness` does not also hide `A:\harness-notes`.
    internal static bool Covers(string hidden, string path)
    {
        var candidate = path.TrimEnd('\\', '/');
        if (candidate.Equals(hidden, StringComparison.OrdinalIgnoreCase)) return true;
        if (candidate.Length <= hidden.Length) return false;
        if (!candidate.StartsWith(hidden, StringComparison.OrdinalIgnoreCase)) return false;
        var next = candidate[hidden.Length];
        return next == '\\' || next == '/';
    }

    public static void Hide(string path)
    {
        var trimmed = path.TrimEnd('\\', '/');
        if (trimmed.Length == 0 || IsHidden(trimmed)) return;
        try
        {
            Directory.CreateDirectory(AppPaths.SupportDir);
            if (!File.Exists(Path))
            {
                File.WriteAllText(Path,
                    "# Folders Sift will not list. One path per line.\r\n" +
                    "# Everything under a listed folder is hidden too. Delete a line to bring it back.\r\n");
            }
            File.AppendAllText(Path, trimmed + "\r\n");
        }
        catch (IOException) { }
    }

    public static void Show(string path)
    {
        var trimmed = path.TrimEnd('\\', '/');
        try
        {
            if (!File.Exists(Path)) return;
            var kept = File.ReadAllLines(Path)
                .Where(line => !line.Trim().TrimEnd('\\', '/')
                                    .Equals(trimmed, StringComparison.OrdinalIgnoreCase));
            File.WriteAllLines(Path, kept);
        }
        catch (IOException) { }
    }

    /// SQL that is false for a session under any hidden folder. Empty when nothing is hidden,
    /// so the common case adds nothing to the query.
    public static string Predicate(IReadOnlyList<string> hidden, string table = "session")
    {
        if (hidden.Count == 0) return "";
        var clauses = hidden.Select(path =>
        {
            var literal = path.Replace("'", "''");
            var prefix = IndexStore.LikePrefix(path).Replace("'", "''");
            return $"(COALESCE({table}.cwd, {table}.projectId) = '{literal}' OR " +
                   $"COALESCE({table}.cwd, {table}.projectId) LIKE '{prefix}' ESCAPE '\\')";
        });
        return "NOT (" + string.Join(" OR ", clauses) + ")";
    }
}
