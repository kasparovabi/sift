using System.IO;

namespace SiftWinUI.Core;

/// Claude Code deletes transcripts older than `cleanupPeriodDays` (30 by default), which
/// means the thing this app exists to search quietly disappears from under it. Sift keeps
/// its own copy: every transcript it indexes is archived, and a session whose original has
/// been cleaned up stays searchable and readable.
///
/// The archive is a plain tree of the original .jsonl files, so it needs no migration and
/// can be read by anything, including Claude Code itself once a file is put back.
public static class Archive
{
    public static string Root => Path.Combine(AppPaths.SupportDir, "archive");

    public static string PathFor(string projectId, string sessionId) =>
        Path.Combine(Root, Sanitise(projectId), Sanitise(sessionId) + ".jsonl");

    /// Copies a transcript in, unless an identical copy is already there. Returns true when
    /// something was written.
    public static bool Keep(string sourcePath, string projectId, string sessionId)
    {
        var target = PathFor(projectId, sessionId);
        try
        {
            var source = new FileInfo(sourcePath);
            if (!source.Exists) return false;
            var existing = new FileInfo(target);
            if (existing.Exists && existing.Length == source.Length &&
                existing.LastWriteTimeUtc >= source.LastWriteTimeUtc) return false;

            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.Copy(sourcePath, target, overwrite: true);
            return true;
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }

    public static bool Has(string projectId, string sessionId) => File.Exists(PathFor(projectId, sessionId));

    /// Puts a transcript back where Claude Code expects it, so `claude --resume` can find a
    /// session that was cleaned up. Returns the restored path, or null if there was nothing
    /// to restore.
    public static string? Restore(string projectId, string sessionId)
    {
        var archived = PathFor(projectId, sessionId);
        if (!File.Exists(archived)) return null;
        try
        {
            var target = Path.Combine(AppPaths.ProjectsRoot, projectId, sessionId + ".jsonl");
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            if (!File.Exists(target)) File.Copy(archived, target);
            return target;
        }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }

    public static (int Files, long Bytes) Size()
    {
        if (!Directory.Exists(Root)) return (0, 0);
        var files = Directory.EnumerateFiles(Root, "*.jsonl", SearchOption.AllDirectories).ToList();
        long bytes = 0;
        foreach (var f in files)
        {
            try { bytes += new FileInfo(f).Length; } catch (IOException) { }
        }
        return (files.Count, bytes);
    }

    /// Directory names come from Claude Code and session ids from filenames, but a path
    /// separator slipping through would write outside the archive.
    private static string Sanitise(string name)
    {
        foreach (var c in Path.GetInvalidFileNameChars()) name = name.Replace(c, '-');
        return name.Replace("..", "-");
    }
}

/// Claude Code's own retention, in `~/.claude/settings.json`. Turning it off is what stops
/// the deletion happening in the first place; the archive is what covers everything that
/// was already lost or gets removed by another machine.
public static class ClaudeRetention
{
    public static string SettingsPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "settings.json");

    public const int Forever = 36500;   // a hundred years, the largest value that stays sane

    public static int? CurrentDays()
    {
        try
        {
            if (!File.Exists(SettingsPath)) return 30;   // Claude Code's own default
            using var doc = System.Text.Json.JsonDocument.Parse(File.ReadAllText(SettingsPath));
            return doc.RootElement.TryGetProperty("cleanupPeriodDays", out var v) && v.TryGetInt32(out var days)
                ? days : 30;
        }
        catch { return null; }
    }

    /// Rewrites only `cleanupPeriodDays`, leaving every other setting exactly as it was.
    public static bool SetDays(int days)
    {
        try
        {
            var dir = Path.GetDirectoryName(SettingsPath)!;
            Directory.CreateDirectory(dir);
            var node = File.Exists(SettingsPath)
                ? System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(SettingsPath)) as System.Text.Json.Nodes.JsonObject
                : new System.Text.Json.Nodes.JsonObject();
            node ??= new System.Text.Json.Nodes.JsonObject();

            if (File.Exists(SettingsPath))
                File.Copy(SettingsPath, SettingsPath + ".sift-backup", overwrite: true);

            node["cleanupPeriodDays"] = days;
            File.WriteAllText(SettingsPath, node.ToJsonString(
                new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
            return true;
        }
        catch { return false; }
    }
}
