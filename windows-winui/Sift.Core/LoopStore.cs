using System.IO;
using Microsoft.Data.Sqlite;

namespace SiftWinUI.Core;

public enum CheckKind { Agent, Shell }

public sealed class LoopTask
{
    public string Id = Guid.NewGuid().ToString("N");
    public string Title = "";
    public string Prompt = "";
    public string Cwd = "";
    public string DoneWhen = "";
    public CheckKind Check = CheckKind.Agent;
    public int MaxPasses = 3;
    public string State = "idle";       // idle | running | checking | passed | failed | stopped
    public int LastAttempt;
    public long UpdatedAt;
}

public sealed record Proof(string TaskId, int Attempt, bool Passed, string MakerOutput,
                           string CheckerOutput, long At);

/// Loop definitions and their evidence, in their own database beside the index so a
/// rebuilt index never takes the record of what was run with it.
public sealed class LoopStore : IDisposable
{
    private readonly SqliteConnection _db;

    public LoopStore(string path)
    {
        var dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        _db = new SqliteConnection($"Data Source={path}");
        _db.Open();
        using var cmd = _db.CreateCommand();
        cmd.CommandText = """
            CREATE TABLE IF NOT EXISTS loop_task (
              id TEXT PRIMARY KEY, title TEXT NOT NULL, prompt TEXT NOT NULL, cwd TEXT NOT NULL,
              doneWhen TEXT NOT NULL, checkKind TEXT NOT NULL, maxPasses INTEGER NOT NULL,
              state TEXT NOT NULL, lastAttempt INTEGER NOT NULL, updatedAt INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS proof (
              taskId TEXT NOT NULL, attempt INTEGER NOT NULL, passed INTEGER NOT NULL,
              makerOutput TEXT NOT NULL, checkerOutput TEXT NOT NULL, at INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS proof_task ON proof(taskId);
            """;
        cmd.ExecuteNonQuery();
    }

    public void Dispose() => _db.Dispose();

    private SqliteCommand Cmd(string sql, params object?[] args)
    {
        var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        for (var i = 0; i < args.Length; i++) cmd.Parameters.AddWithValue($"@p{i}", args[i] ?? DBNull.Value);
        return cmd;
    }

    public List<LoopTask> All()
    {
        var list = new List<LoopTask>();
        using var cmd = Cmd("SELECT * FROM loop_task ORDER BY updatedAt DESC");
        using var r = cmd.ExecuteReader();
        while (r.Read())
        {
            list.Add(new LoopTask
            {
                Id = r.GetString(r.GetOrdinal("id")),
                Title = r.GetString(r.GetOrdinal("title")),
                Prompt = r.GetString(r.GetOrdinal("prompt")),
                Cwd = r.GetString(r.GetOrdinal("cwd")),
                DoneWhen = r.GetString(r.GetOrdinal("doneWhen")),
                Check = r.GetString(r.GetOrdinal("checkKind")) == "shell" ? CheckKind.Shell : CheckKind.Agent,
                MaxPasses = r.GetInt32(r.GetOrdinal("maxPasses")),
                State = r.GetString(r.GetOrdinal("state")),
                LastAttempt = r.GetInt32(r.GetOrdinal("lastAttempt")),
                UpdatedAt = r.GetInt64(r.GetOrdinal("updatedAt")),
            });
        }
        // A task left mid-run when the app was closed is not running any more.
        foreach (var t in list.Where(t => t.State is "running" or "checking"))
        {
            t.State = "idle";
            Upsert(t);
        }
        return list;
    }

    public void Upsert(LoopTask t)
    {
        t.UpdatedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        using var cmd = Cmd("""
            INSERT INTO loop_task (id, title, prompt, cwd, doneWhen, checkKind, maxPasses,
                                   state, lastAttempt, updatedAt)
            VALUES (@p0,@p1,@p2,@p3,@p4,@p5,@p6,@p7,@p8,@p9)
            ON CONFLICT(id) DO UPDATE SET title=excluded.title, prompt=excluded.prompt,
              cwd=excluded.cwd, doneWhen=excluded.doneWhen, checkKind=excluded.checkKind,
              maxPasses=excluded.maxPasses, state=excluded.state,
              lastAttempt=excluded.lastAttempt, updatedAt=excluded.updatedAt
            """, t.Id, t.Title, t.Prompt, t.Cwd, t.DoneWhen,
                 t.Check == CheckKind.Shell ? "shell" : "agent",
                 t.MaxPasses, t.State, t.LastAttempt, t.UpdatedAt);
        cmd.ExecuteNonQuery();
    }

    public void Delete(string id)
    {
        using (var a = Cmd("DELETE FROM proof WHERE taskId = @p0", id)) a.ExecuteNonQuery();
        using (var b = Cmd("DELETE FROM loop_task WHERE id = @p0", id)) b.ExecuteNonQuery();
    }

    public void ClearProofs(string taskId)
    {
        using var cmd = Cmd("DELETE FROM proof WHERE taskId = @p0", taskId);
        cmd.ExecuteNonQuery();
    }

    public void Add(Proof p)
    {
        using var cmd = Cmd("""
            INSERT INTO proof (taskId, attempt, passed, makerOutput, checkerOutput, at)
            VALUES (@p0,@p1,@p2,@p3,@p4,@p5)
            """, p.TaskId, p.Attempt, p.Passed ? 1 : 0, p.MakerOutput, p.CheckerOutput, p.At);
        cmd.ExecuteNonQuery();
    }

    public List<Proof> Proofs(string taskId)
    {
        var list = new List<Proof>();
        using var cmd = Cmd("SELECT * FROM proof WHERE taskId = @p0 ORDER BY attempt", taskId);
        using var r = cmd.ExecuteReader();
        while (r.Read())
        {
            list.Add(new Proof(taskId, r.GetInt32(r.GetOrdinal("attempt")),
                r.GetInt32(r.GetOrdinal("passed")) == 1,
                r.GetString(r.GetOrdinal("makerOutput")),
                r.GetString(r.GetOrdinal("checkerOutput")),
                r.GetInt64(r.GetOrdinal("at"))));
        }
        return list;
    }
}
