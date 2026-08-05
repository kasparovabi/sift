using System.IO;
using Microsoft.Data.Sqlite;

namespace Sift.Core;

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

    public List<ProjectRow> Projects()
    {
        var rows = new List<ProjectRow>();
        using var cmd = Cmd("""
            SELECT projectId, count(*), max(lastActivity),
                   (SELECT cwd FROM session s2 WHERE s2.projectId = s1.projectId AND cwd IS NOT NULL LIMIT 1)
            FROM session s1 GROUP BY projectId ORDER BY max(lastActivity) DESC
            """);
        using var r = cmd.ExecuteReader();
        while (r.Read())
        {
            var id = r.GetString(0);
            var path = r.IsDBNull(3) ? Scanner.DecodeProjectDir(id) : r.GetString(3);
            rows.Add(new ProjectRow(id, path, Scanner.DisplayName(path), r.GetInt32(1),
                r.IsDBNull(2) ? null : r.GetInt64(2)));
        }
        return rows;
    }

    /// Ranked search. The column weights put a title match above a body match, the same
    /// ordering the macOS app uses. Column 3 is fullText, which the snippet comes from.
    public List<SearchHit> Search(string query, string? projectId = null, long? since = null, int limit = 200)
    {
        var trimmed = (query ?? "").Trim();
        var hits = new List<SearchHit>();

        SqliteCommand cmd;
        if (trimmed.Length == 0)
        {
            var where = new List<string>();
            var args = new List<object?>();
            if (projectId is not null) { where.Add($"projectId = @p{args.Count}"); args.Add(projectId); }
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
            if (projectId is not null) { where.Add($"s.projectId = @p{args.Count}"); args.Add(projectId); }
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
