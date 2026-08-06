using System.IO;
using Microsoft.Data.Sqlite;

namespace SiftWinUI.Core;

public sealed class SearchHit
{
    public string SessionId = "";
    public string ProjectId = "";
    public string FilePath = "";
    public string? Cwd;
    public string? GitBranch;
    public string Title = "";
    public string Preview = "";
    public string? Snippet;
    public int MessageCount;
    public long? LastActivity;
}

public sealed record ProjectRow(string Id, string Path, string Name, int Count, long? LastActivity);

/// The same shape the macOS app keeps: a session table plus an FTS5 mirror, with the
/// transcripts on disk staying the source of truth. Delete the file and it rebuilds.
///
/// The FTS table keeps its own copy of the text rather than using `content=''`. A
/// contentless table cannot return its columns, so the delete an update needs has nothing
/// to delete with, and feeding it the wrong values corrupts the index outright.
public sealed class IndexStore : IDisposable
{
    private readonly SqliteConnection _db;

    public IndexStore(string path)
    {
        if (path != ":memory:")
        {
            var dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        }
        _db = new SqliteConnection($"Data Source={path}");
        _db.Open();
        Exec("PRAGMA journal_mode = WAL");
        Exec("""
            CREATE TABLE IF NOT EXISTS session (
              sessionId TEXT PRIMARY KEY, projectId TEXT NOT NULL, filePath TEXT NOT NULL,
              cwd TEXT, gitBranch TEXT, title TEXT, firstMessage TEXT, entrypoint TEXT,
              startedAt INTEGER, lastActivity INTEGER,
              messageCount INTEGER NOT NULL DEFAULT 0, toolCallCount INTEGER NOT NULL DEFAULT 0,
              fileSize INTEGER NOT NULL, fileMtime INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS session_project ON session(projectId);
            CREATE INDEX IF NOT EXISTS session_activity ON session(lastActivity);
            CREATE VIRTUAL TABLE IF NOT EXISTS session_ft USING fts5(
              sessionId UNINDEXED, title, firstMessage, fullText,
              tokenize='unicode61', prefix='2 3');
            """);
    }

    public void Dispose() => _db.Dispose();

    private void Exec(string sql)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        cmd.ExecuteNonQuery();
    }

    private SqliteCommand Cmd(string sql, params object?[] args)
    {
        var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        for (var i = 0; i < args.Length; i++)
            cmd.Parameters.AddWithValue($"@p{i}", args[i] ?? DBNull.Value);
        return cmd;
    }

    public Dictionary<string, (long Size, long Mtime)> Fingerprints()
    {
        var map = new Dictionary<string, (long, long)>();
        using var cmd = Cmd("SELECT filePath, fileSize, fileMtime FROM session");
        using var r = cmd.ExecuteReader();
        while (r.Read()) map[r.GetString(0)] = (r.GetInt64(1), r.GetInt64(2));
        return map;
    }

    public void Upsert(SessionRow row)
    {
        using (var cmd = Cmd("""
            INSERT INTO session (sessionId, projectId, filePath, cwd, gitBranch, title,
                                 firstMessage, entrypoint, startedAt, lastActivity,
                                 messageCount, toolCallCount, fileSize, fileMtime)
            VALUES (@p0,@p1,@p2,@p3,@p4,@p5,@p6,@p7,@p8,@p9,@p10,@p11,@p12,@p13)
            ON CONFLICT(sessionId) DO UPDATE SET
              projectId=excluded.projectId, filePath=excluded.filePath, cwd=excluded.cwd,
              gitBranch=excluded.gitBranch, title=excluded.title,
              firstMessage=excluded.firstMessage, entrypoint=excluded.entrypoint,
              startedAt=excluded.startedAt, lastActivity=excluded.lastActivity,
              messageCount=excluded.messageCount, toolCallCount=excluded.toolCallCount,
              fileSize=excluded.fileSize, fileMtime=excluded.fileMtime
            """, row.SessionId, row.ProjectId, row.FilePath, row.Cwd, row.GitBranch, row.Title,
                 row.FirstMessage, row.Entrypoint, row.StartedAt, row.LastActivity,
                 row.MessageCount, row.ToolCallCount, row.FileSize, row.FileMtime))
            cmd.ExecuteNonQuery();

        using (var del = Cmd("DELETE FROM session_ft WHERE sessionId = @p0", row.SessionId))
            del.ExecuteNonQuery();
        using (var ins = Cmd(
            "INSERT INTO session_ft(sessionId, title, firstMessage, fullText) VALUES (@p0,@p1,@p2,@p3)",
            row.SessionId, row.Title ?? "", row.FirstMessage ?? "", row.FullText))
            ins.ExecuteNonQuery();
    }

    public int RemoveMissing(IEnumerable<string> presentPaths)
    {
        var present = new HashSet<string>(presentPaths, StringComparer.OrdinalIgnoreCase);
        var gone = new List<string>();
        using (var cmd = Cmd("SELECT sessionId, filePath FROM session"))
        using (var r = cmd.ExecuteReader())
            while (r.Read())
                if (!present.Contains(r.GetString(1))) gone.Add(r.GetString(0));

        foreach (var id in gone)
        {
            using (var a = Cmd("DELETE FROM session_ft WHERE sessionId = @p0", id)) a.ExecuteNonQuery();
            using (var b = Cmd("DELETE FROM session WHERE sessionId = @p0", id)) b.ExecuteNonQuery();
        }
        return gone.Count;
    }

    public int Count()
    {
        using var cmd = Cmd("SELECT count(*) FROM session");
        return Convert.ToInt32(cmd.ExecuteScalar());
    }

    /// Projects grouped by where they actually are on disk, not by the encoded directory
    /// name Claude Code stores them under.
    ///
    /// That encoding turns every path separator into a dash, so `A:\harness\sandbox\
    /// clean-20260802\contact_email` and `A:\harness` become unrelated-looking siblings.
    /// A run that works in scratch subfolders therefore showed up as hundreds of top-level
    /// projects: on the machine this was built against, 737 of them were subfolders of one
    /// real project. The session's own `cwd` still has the true path, so a cwd that sits
    /// under another session's cwd is rolled up into it.
    public List<ProjectRow> Projects()
    {
        var counts = new Dictionary<string, (int Count, long? Last)>(StringComparer.OrdinalIgnoreCase);
        // A session with no cwd falls back to a sibling's, because the encoded directory name
        // cannot be decoded back into a path: every separator became a dash, and so did any
        // dash already in the name. Without this, two sessions missing a cwd show up as a
        // second copy of a project that is already listed.
        using (var cmd = Cmd("""
            SELECT COALESCE(
                     s.cwd,
                     (SELECT o.cwd FROM session o
                       WHERE o.projectId = s.projectId AND o.cwd IS NOT NULL LIMIT 1),
                     s.projectId) AS path,
                   count(*), max(s.lastActivity)
            FROM session s GROUP BY path
            """))
        using (var r = cmd.ExecuteReader())
            while (r.Read())
                counts[r.GetString(0)] = (r.GetInt32(1), r.IsDBNull(2) ? null : r.GetInt64(2));

        counts = FoldOneShotSiblings(counts);
        var roots = Roots(counts.Keys);
        var rolled = new Dictionary<string, (int Count, long? Last)>(StringComparer.OrdinalIgnoreCase);
        foreach (var (path, value) in counts)
        {
            var root = NearestRoot(path, roots);
            rolled.TryGetValue(root, out var soFar);
            var last = soFar.Last is null || (value.Last is not null && value.Last > soFar.Last)
                ? value.Last : soFar.Last;
            rolled[root] = (soFar.Count + value.Count, last);
        }

        return rolled
            .Select(kv => new ProjectRow(kv.Key, kv.Key, Scanner.DisplayName(kv.Key),
                                         kv.Value.Count, kv.Value.Last))
            .OrderByDescending(p => p.Count)
            .ThenByDescending(p => p.LastActivity ?? 0)
            .ToList();
    }

    /// Rolling up into an ancestor only works when that ancestor ran a session of its own.
    /// A harness gives every run a fresh directory and never works in the parent, so hundreds
    /// of one-session folders stayed separate: siblings with no common row to fold into.
    ///
    /// One session per directory, over and over, is the signature of directories a program
    /// made rather than a person. When most of a parent's children look like that, the parent
    /// becomes the project and the children disappear into it. A folder of real projects is
    /// left alone, because those hold more than one session each. The cost of being wrong is
    /// that a handful of genuinely new projects share one entry until they are worked in
    /// twice, which beats a sidebar with seven hundred rows in it.
    internal static Dictionary<string, (int Count, long? Last)> FoldOneShotSiblings(
        Dictionary<string, (int Count, long? Last)> counts)
    {
        const int minimumSiblings = 6;

        var folded = new Dictionary<string, (int Count, long? Last)>(counts, StringComparer.OrdinalIgnoreCase);
        for (var pass = 0; pass < 8; pass++)
        {
            var groups = folded.Keys
                .Select(path => (Path: path, Parent: Parent(path)))
                .Where(pair => pair.Parent is not null)
                .GroupBy(pair => pair.Parent!, StringComparer.OrdinalIgnoreCase)
                .Where(group => group.Count() >= minimumSiblings &&
                                group.Count(pair => folded[pair.Path].Count == 1) * 4 >= group.Count() * 3)
                .ToList();
            if (groups.Count == 0) break;

            foreach (var group in groups)
            {
                folded.TryGetValue(group.Key, out var merged);
                foreach (var (path, _) in group)
                {
                    var child = folded[path];
                    folded.Remove(path);
                    merged = (merged.Count + child.Count,
                              merged.Last is null || (child.Last is not null && child.Last > merged.Last)
                                  ? child.Last : merged.Last);
                }
                folded[group.Key] = merged;
            }
        }
        return folded;
    }

    private static readonly char[] Separators = { '/', '\\' };

    /// The containing directory, or null at a drive or filesystem root.
    internal static string? Parent(string path)
    {
        var trimmed = path.TrimEnd(Separators);
        var cut = trimmed.LastIndexOfAny(Separators);
        if (cut <= 0) return null;
        var parent = trimmed[..cut];
        return parent.Length < 2 || parent.EndsWith(':') ? null : parent;
    }

    /// A path is a root when no other path in the set is an ancestor of it.
    internal static HashSet<string> Roots(IEnumerable<string> paths)
    {
        var all = paths.ToList();
        var roots = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var path in all)
            if (!all.Any(other => IsAncestor(other, path))) roots.Add(path);
        return roots;
    }

    internal static string NearestRoot(string path, HashSet<string> roots)
    {
        if (roots.Contains(path)) return path;
        string? best = null;
        foreach (var root in roots)
            if (IsAncestor(root, path) && (best is null || root.Length > best.Length)) best = root;
        return best ?? path;
    }

    /// True when `parent` contains `child`, matched on whole path components so
    /// `A:\harness` does not swallow `A:\harness-other`.
    internal static bool IsAncestor(string parent, string child)
    {
        if (parent.Length >= child.Length) return false;
        if (!child.StartsWith(parent, StringComparison.OrdinalIgnoreCase)) return false;
        var next = child[parent.Length];
        return next == '\\' || next == '/';
    }

    /// Ranked search. The column weights put a title match above a body match, the same
    /// ordering the macOS app uses. Column 3 is fullText, which the snippet comes from.
    public List<SearchHit> Search(string query, string? projectPath = null, long? since = null, int limit = 200)
    {
        var trimmed = (query ?? "").Trim();
        var hits = new List<SearchHit>();

        SqliteCommand cmd;
        if (trimmed.Length == 0)
        {
            var where = new List<string>();
            var args = new List<object?>();
            if (projectPath is not null)
            {
                where.Add($"(COALESCE(cwd, projectId) = @p{args.Count} OR COALESCE(cwd, projectId) LIKE @p{args.Count + 1} ESCAPE '\\')");
                args.Add(projectPath);
                args.Add(LikePrefix(projectPath));
            }
            if (since is not null) { where.Add($"lastActivity >= @p{args.Count}"); args.Add(since); }
            args.Add(limit);
            cmd = Cmd($"""
                SELECT sessionId, projectId, filePath, cwd, gitBranch, title, firstMessage,
                       messageCount, lastActivity, NULL
                FROM session {(where.Count > 0 ? "WHERE " + string.Join(" AND ", where) : "")}
                ORDER BY lastActivity DESC LIMIT @p{args.Count - 1}
                """, args.ToArray());
        }
        else
        {
            var args = new List<object?> { FtsQuery(trimmed) };
            var where = new List<string>();
            if (projectPath is not null)
            {
                where.Add($"(COALESCE(s.cwd, s.projectId) = @p{args.Count} OR COALESCE(s.cwd, s.projectId) LIKE @p{args.Count + 1} ESCAPE '\\')");
                args.Add(projectPath);
                args.Add(LikePrefix(projectPath));
            }
            if (since is not null) { where.Add($"s.lastActivity >= @p{args.Count}"); args.Add(since); }
            args.Add(limit);
            cmd = Cmd($"""
                SELECT s.sessionId, s.projectId, s.filePath, s.cwd, s.gitBranch, s.title,
                       s.firstMessage, s.messageCount, s.lastActivity,
                       snippet(session_ft, 3, '', '', '…', 12)
                FROM session_ft
                JOIN session s ON s.sessionId = session_ft.sessionId
                WHERE session_ft MATCH @p0 {(where.Count > 0 ? "AND " + string.Join(" AND ", where) : "")}
                ORDER BY bm25(session_ft, 0.0, 5.0, 2.0, 1.0)
                LIMIT @p{args.Count - 1}
                """, args.ToArray());
        }

        using (cmd)
        using (var r = cmd.ExecuteReader())
        {
            while (r.Read())
            {
                var cwd = r.IsDBNull(3) ? null : r.GetString(3);
                var project = Scanner.DisplayName(cwd ?? Scanner.DecodeProjectDir(r.GetString(1)));
                var first = r.IsDBNull(6) ? "" : r.GetString(6);
                hits.Add(new SearchHit
                {
                    SessionId = r.GetString(0),
                    ProjectId = project,
                    FilePath = r.GetString(2),
                    Cwd = cwd,
                    GitBranch = r.IsDBNull(4) ? null : r.GetString(4),
                    Title = r.IsDBNull(5) ? FirstLine(first) : r.GetString(5),
                    Preview = first,
                    MessageCount = r.GetInt32(7),
                    LastActivity = r.IsDBNull(8) ? null : r.GetInt64(8),
                    Snippet = r.IsDBNull(9) ? null : r.GetString(9),
                });
            }
        }
        return hits;
    }

    /// LIKE pattern matching everything under a directory, with the wildcards SQLite would
    /// otherwise read inside the path escaped.
    internal static string LikePrefix(string path)
    {
        var escaped = path.Replace("\\", "\\\\").Replace("%", "\\%").Replace("_", "\\_");
        // A separator, then a real wildcard. The separator is itself escaped because the
        // escape character IS the separator on Windows; getting this wrong makes the
        // pattern end in a literal per-cent and match nothing.
        return escaped + "\\\\%";
    }

    private static string FirstLine(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return "Untitled session";
        foreach (var line in text.Split('\n'))
            if (!string.IsNullOrWhiteSpace(line))
                return line.Trim().Length > 120 ? line.Trim()[..120] : line.Trim();
        return "Untitled session";
    }

    /// Turns what someone typed into an FTS5 expression: every word a prefix match, with
    /// the characters that carry meaning to FTS5 stripped so a stray quote is not an error.
    public static string FtsQuery(string input)
    {
        var words = input.Replace("\"", " ").Replace("*", " ")
            .Split(new[] { ' ', '\t', '\n' }, StringSplitOptions.RemoveEmptyEntries);
        if (words.Length == 0) return "\"\"";
        return string.Join(" AND ", words.Select(w => $"\"{w}\"*"));
    }
}
