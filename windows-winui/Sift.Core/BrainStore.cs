using Microsoft.Data.Sqlite;

namespace SiftWinUI.Core;

public enum AtomType { Fact, Decision, Pref, Entity, HowTo, Event }

public static class AtomTypes
{
    public static string Code(this AtomType t) => t switch
    {
        AtomType.Fact => "F",
        AtomType.Decision => "D",
        AtomType.Pref => "P",
        AtomType.Entity => "E",
        AtomType.HowTo => "H",
        _ => "V",
    };

    public static AtomType Parse(string? code) => code switch
    {
        "D" => AtomType.Decision,
        "P" => AtomType.Pref,
        "E" => AtomType.Entity,
        "H" => AtomType.HowTo,
        "V" => AtomType.Event,
        _ => AtomType.Fact,
    };

    public static string Label(this AtomType t) => t switch
    {
        AtomType.Fact => "Fact",
        AtomType.Decision => "Decision",
        AtomType.Pref => "Preference",
        AtomType.Entity => "Entity",
        AtomType.HowTo => "How-to",
        _ => "Event",
    };
}

public sealed record Atom(
    string Id, AtomType Type, string Statement, string? Project, string Source, int Importance,
    double CreatedAt);

public sealed record Entity(string Id, string Name, string Kind, int AtomCount);

public sealed record Relation(string Id, string SubjectId, string Predicate, string ObjectId);

public sealed record GraphEdge(string FromId, string ToId, int Weight);

/// Extracted knowledge: statements, the entities they mention, and the relations between
/// those entities. Separate from index.sqlite because the index is a rebuildable cache and
/// this is not: deleting it loses everything that was extracted.
public sealed class BrainStore : IDisposable
{
    private readonly SqliteConnection _db;

    public BrainStore(string path)
    {
        _db = new SqliteConnection($"Data Source={path}");
        _db.Open();
        Exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;");
        Migrate();
    }

    private void Migrate() => Exec("""
        CREATE TABLE IF NOT EXISTS brain_meta(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS atom(
            id TEXT PRIMARY KEY, t TEXT NOT NULL, s TEXT NOT NULL, proj TEXT,
            src TEXT NOT NULL, imp INTEGER NOT NULL, createdAt REAL NOT NULL,
            validAt REAL, invalidAt REAL,
            retrievals INTEGER NOT NULL DEFAULT 0, lastRetrievedAt REAL);
        CREATE TABLE IF NOT EXISTS entity(id TEXT PRIMARY KEY, n TEXT NOT NULL, k TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS entity_alias(entityId TEXT NOT NULL, alias TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS atom_entity(
            atomId TEXT NOT NULL REFERENCES atom(id) ON DELETE CASCADE,
            entityId TEXT NOT NULL REFERENCES entity(id) ON DELETE CASCADE,
            PRIMARY KEY(atomId, entityId));
        CREATE TABLE IF NOT EXISTS relation(
            id TEXT PRIMARY KEY, subjectId TEXT NOT NULL, predicate TEXT NOT NULL,
            objectId TEXT NOT NULL, validAt REAL, invalidAt REAL, src TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS ingested(src TEXT PRIMARY KEY, at REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS atom_src ON atom(src);
        CREATE INDEX IF NOT EXISTS atom_proj ON atom(proj);
        CREATE UNIQUE INDEX IF NOT EXISTS entity_name ON entity(n COLLATE NOCASE);
        CREATE VIRTUAL TABLE IF NOT EXISTS atom_ft USING fts5(
            s, id UNINDEXED, tokenize='unicode61', prefix='2 3');
        """);

    /// Base62 of a counter, so an id stays short in the graph view.
    private string NextId()
    {
        var current = ScalarLong("SELECT value FROM brain_meta WHERE key='seq'") ?? 0;
        var next = current + 1;
        using var cmd = _db.CreateCommand();
        cmd.CommandText = "INSERT INTO brain_meta(key,value) VALUES('seq',$v) " +
                          "ON CONFLICT(key) DO UPDATE SET value=$v";
        cmd.Parameters.AddWithValue("$v", next);
        cmd.ExecuteNonQuery();
        return Base62(next);
    }

    internal static string Base62(long value)
    {
        const string alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
        if (value == 0) return "0";
        var digits = new Stack<char>();
        while (value > 0)
        {
            digits.Push(alphabet[(int)(value % 62)]);
            value /= 62;
        }
        return new string(digits.ToArray());
    }

    public bool AlreadyIngested(string source) =>
        ScalarLong("SELECT 1 FROM ingested WHERE src=$s", ("$s", source)) is not null;

    public void MarkIngested(string source)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = "INSERT OR REPLACE INTO ingested(src,at) VALUES($s,$a)";
        cmd.Parameters.AddWithValue("$s", source);
        cmd.Parameters.AddWithValue("$a", Now());
        cmd.ExecuteNonQuery();
    }

    /// Writes one extraction. Entities are matched by name, so the same library mentioned in
    /// two projects becomes one node rather than two.
    public int Ingest(ExtractionResult result, string source, string? project)
    {
        using var tx = _db.BeginTransaction();
        var written = 0;
        foreach (var raw in result.Atoms)
        {
            var statement = raw.Statement.Trim();
            if (statement.Length == 0) continue;
            var id = NextId();
            using (var cmd = _db.CreateCommand())
            {
                cmd.CommandText = "INSERT INTO atom(id,t,s,proj,src,imp,createdAt) " +
                                  "VALUES($i,$t,$s,$p,$src,$imp,$c)";
                cmd.Parameters.AddWithValue("$i", id);
                cmd.Parameters.AddWithValue("$t", raw.Type.Code());
                cmd.Parameters.AddWithValue("$s", statement);
                cmd.Parameters.AddWithValue("$p", (object?)project ?? DBNull.Value);
                cmd.Parameters.AddWithValue("$src", source);
                cmd.Parameters.AddWithValue("$imp", Math.Clamp(raw.Importance, 1, 10));
                cmd.Parameters.AddWithValue("$c", Now());
                cmd.ExecuteNonQuery();
            }
            using (var cmd = _db.CreateCommand())
            {
                cmd.CommandText = "INSERT INTO atom_ft(s,id) VALUES($s,$i)";
                cmd.Parameters.AddWithValue("$s", statement);
                cmd.Parameters.AddWithValue("$i", id);
                cmd.ExecuteNonQuery();
            }
            foreach (var name in raw.Entities)
            {
                var entityId = UpsertEntity(name, "thing");
                if (entityId is null) continue;
                using var link = _db.CreateCommand();
                link.CommandText = "INSERT OR IGNORE INTO atom_entity(atomId,entityId) VALUES($a,$e)";
                link.Parameters.AddWithValue("$a", id);
                link.Parameters.AddWithValue("$e", entityId);
                link.ExecuteNonQuery();
            }
            written++;
        }

        foreach (var rel in result.Relations)
        {
            var subject = UpsertEntity(rel.Subject, "thing");
            var obj = UpsertEntity(rel.Object, "thing");
            if (subject is null || obj is null || subject == obj) continue;
            using var cmd = _db.CreateCommand();
            cmd.CommandText = "INSERT INTO relation(id,subjectId,predicate,objectId,src) " +
                              "VALUES($i,$s,$p,$o,$src)";
            cmd.Parameters.AddWithValue("$i", NextId());
            cmd.Parameters.AddWithValue("$s", subject);
            cmd.Parameters.AddWithValue("$p", rel.Predicate.Trim());
            cmd.Parameters.AddWithValue("$o", obj);
            cmd.Parameters.AddWithValue("$src", source);
            cmd.ExecuteNonQuery();
        }

        tx.Commit();
        return written;
    }

    private string? UpsertEntity(string name, string kind)
    {
        var trimmed = name.Trim();
        if (trimmed.Length == 0 || trimmed.Length > 120) return null;
        using (var find = _db.CreateCommand())
        {
            find.CommandText = "SELECT id FROM entity WHERE n=$n COLLATE NOCASE";
            find.Parameters.AddWithValue("$n", trimmed);
            if (find.ExecuteScalar() is string existing) return existing;
        }
        var id = NextId();
        using var cmd = _db.CreateCommand();
        cmd.CommandText = "INSERT INTO entity(id,n,k) VALUES($i,$n,$k)";
        cmd.Parameters.AddWithValue("$i", id);
        cmd.Parameters.AddWithValue("$n", trimmed);
        cmd.Parameters.AddWithValue("$k", kind);
        cmd.ExecuteNonQuery();
        return id;
    }

    public int AtomCount() => (int)(ScalarLong("SELECT COUNT(*) FROM atom") ?? 0);
    public int EntityCount() => (int)(ScalarLong("SELECT COUNT(*) FROM entity") ?? 0);

    public List<Atom> Atoms(string? query = null, string? entityId = null, int limit = 200)
    {
        using var cmd = _db.CreateCommand();
        var where = new List<string>();
        if (!string.IsNullOrWhiteSpace(query))
        {
            where.Add("a.id IN (SELECT id FROM atom_ft WHERE atom_ft MATCH $q)");
            cmd.Parameters.AddWithValue("$q", IndexStore.FtsQuery(query));
        }
        if (entityId is not null)
        {
            where.Add("a.id IN (SELECT atomId FROM atom_entity WHERE entityId=$e)");
            cmd.Parameters.AddWithValue("$e", entityId);
        }
        var filter = where.Count == 0 ? "" : "WHERE " + string.Join(" AND ", where);
        cmd.CommandText = $"""
            SELECT a.id,a.t,a.s,a.proj,a.src,a.imp,a.createdAt FROM atom a
            {filter}
            ORDER BY a.imp DESC, a.createdAt DESC LIMIT $l
            """;
        cmd.Parameters.AddWithValue("$l", limit);

        var list = new List<Atom>();
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            list.Add(new Atom(
                reader.GetString(0), AtomTypes.Parse(reader.GetString(1)), reader.GetString(2),
                reader.IsDBNull(3) ? null : reader.GetString(3), reader.GetString(4),
                reader.GetInt32(5), reader.GetDouble(6)));
        }
        return list;
    }

    /// Entities ordered by how much is known about them, which is also the order the graph
    /// draws them in: the biggest node is the thing the sessions kept coming back to.
    public List<Entity> Entities(int limit = 60)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = """
            SELECT e.id, e.n, e.k, COUNT(ae.atomId) AS c
            FROM entity e LEFT JOIN atom_entity ae ON ae.entityId = e.id
            GROUP BY e.id HAVING c > 0 ORDER BY c DESC, e.n LIMIT $l
            """;
        cmd.Parameters.AddWithValue("$l", limit);
        var list = new List<Entity>();
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
            list.Add(new Entity(reader.GetString(0), reader.GetString(1), reader.GetString(2),
                                reader.GetInt32(3)));
        return list;
    }

    /// Two entities are connected when a statement mentions both. Relations extracted
    /// explicitly count as an edge too, so a stated link survives even without a shared atom.
    public List<GraphEdge> Edges(IEnumerable<string> entityIds)
    {
        var ids = entityIds.ToList();
        if (ids.Count < 2) return [];
        var placeholders = string.Join(",", ids.Select((_, i) => "$e" + i));
        using var cmd = _db.CreateCommand();
        cmd.CommandText = $"""
            SELECT a.entityId, b.entityId, COUNT(*) FROM atom_entity a
            JOIN atom_entity b ON a.atomId = b.atomId AND a.entityId < b.entityId
            WHERE a.entityId IN ({placeholders}) AND b.entityId IN ({placeholders})
            GROUP BY a.entityId, b.entityId
            UNION
            SELECT subjectId, objectId, 1 FROM relation
            WHERE subjectId IN ({placeholders}) AND objectId IN ({placeholders})
            """;
        for (var i = 0; i < ids.Count; i++) cmd.Parameters.AddWithValue("$e" + i, ids[i]);

        var edges = new List<GraphEdge>();
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
            edges.Add(new GraphEdge(reader.GetString(0), reader.GetString(1), reader.GetInt32(2)));
        return edges;
    }

    public void Clear()
    {
        Exec("DELETE FROM atom; DELETE FROM entity; DELETE FROM entity_alias; " +
             "DELETE FROM atom_entity; DELETE FROM relation; DELETE FROM atom_ft; " +
             "DELETE FROM ingested; DELETE FROM brain_meta;");
    }

    private static double Now() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;

    private void Exec(string sql)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        cmd.ExecuteNonQuery();
    }

    private long? ScalarLong(string sql, params (string, object)[] args)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        foreach (var (name, value) in args) cmd.Parameters.AddWithValue(name, value);
        var result = cmd.ExecuteScalar();
        return result is null || result is DBNull ? null : Convert.ToInt64(result);
    }

    public void Dispose() => _db.Dispose();
}
