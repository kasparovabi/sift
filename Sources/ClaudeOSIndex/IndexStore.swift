import Foundation
import GRDB
import ClaudeOSCore

public struct SearchFilters: Sendable, Equatable {
    public var projectId: String?
    public var since: Date?
    public var gitBranch: String?
    public var entrypoint: String?

    public init(projectId: String? = nil, since: Date? = nil, gitBranch: String? = nil, entrypoint: String? = nil) {
        self.projectId = projectId
        self.since = since
        self.gitBranch = gitBranch
        self.entrypoint = entrypoint
    }
}

/// SQLite-backed index over all sessions, with FTS5 full-text search. The index
/// is a rebuildable cache; the JSONL files are the source of truth.
public final class IndexStore: Sendable {
    private let dbQueue: DatabaseQueue

    public init(path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        dbQueue = try DatabaseQueue(path: path.path)
        try Self.migrator.migrate(dbQueue)
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ClaudeOS/index.sqlite")
    }

    private static let migrator: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "project") { t in
                t.column("id", .text).primaryKey()
                t.column("decodedPath", .text).notNull()
                t.column("displayName", .text).notNull()
                t.column("sessionCount", .integer).notNull().defaults(to: 0)
                t.column("lastActivity", .datetime)
                t.column("cwdExists", .boolean).notNull().defaults(to: true)
            }
            try db.create(table: "session") { t in
                t.column("sessionId", .text).primaryKey()
                t.column("projectId", .text).notNull().indexed()
                t.column("filePath", .text).notNull()
                t.column("cwd", .text)
                t.column("gitBranch", .text)
                t.column("title", .text)
                t.column("firstMessage", .text)
                t.column("slug", .text)
                t.column("entrypoint", .text)
                t.column("version", .text)
                t.column("startedAt", .datetime)
                t.column("lastActivity", .datetime).indexed()
                t.column("messageCount", .integer).notNull().defaults(to: 0)
                t.column("toolCallCount", .integer).notNull().defaults(to: 0)
                t.column("fileSize", .integer).notNull()
                t.column("fileMtime", .datetime).notNull()
                t.column("indexedAt", .datetime).notNull()
                t.column("headOnly", .boolean).notNull().defaults(to: false)
            }
            try db.create(virtualTable: "session_ft", using: FTS5()) { t in
                t.synchronize(withTable: "session")
                t.tokenizer = .unicode61()
                t.prefixes = [2, 3]
                t.column("title")
                t.column("firstMessage")
            }
        }
        m.registerMigration("v2_fulltext") { db in
            try db.alter(table: "session") { t in
                t.add(column: "fullText", .text)
            }
            // v1's FTS sync triggers live on `session`; drop them (and the FTS
            // table) before re-synchronizing with the new column set.
            try db.execute(sql: "DROP TRIGGER IF EXISTS __session_ft_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS __session_ft_au")
            try db.execute(sql: "DROP TRIGGER IF EXISTS __session_ft_ad")
            try db.execute(sql: "DROP TABLE IF EXISTS session_ft")
            try db.create(virtualTable: "session_ft", using: FTS5()) { t in
                t.synchronize(withTable: "session")
                t.tokenizer = .unicode61()
                t.prefixes = [2, 3]
                t.column("title")
                t.column("firstMessage")
                t.column("fullText")
            }
        }
        return m
    }()

    // MARK: - Writes

    /// Current (size, mtime) per session file, so a scan can skip unchanged files.
    func fingerprints() async throws -> [String: FileFingerprint] {
        try await dbQueue.read { db in
            var map: [String: FileFingerprint] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT filePath, fileSize, fileMtime FROM session")
            for row in rows {
                let path: String = row["filePath"]
                let size: Int64 = row["fileSize"]
                let mtime: Date = row["fileMtime"]
                map[path] = FileFingerprint(size: size, mtime: mtime)
            }
            return map
        }
    }

    /// Apply a (possibly partial) scan: upsert changed sessions, drop rows whose
    /// files vanished, then recompute the project rollups from the session table.
    func apply(_ result: ScanResult) async throws {
        try await dbQueue.write { db in
            for session in result.upserts { try session.save(db) }
            let storedPaths = try String.fetchAll(db, sql: "SELECT filePath FROM session")
            for path in storedPaths where !result.presentPaths.contains(path) {
                try db.execute(sql: "DELETE FROM session WHERE filePath = ?", arguments: [path])
            }
            try Self.recomputeProjects(db)
        }
    }

    private static func recomputeProjects(_ db: Database) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT projectId AS pid,
                   count(*) AS cnt,
                   max(lastActivity) AS la,
                   (SELECT cwd FROM session s2 WHERE s2.projectId = s1.projectId AND cwd IS NOT NULL LIMIT 1) AS sampleCwd
            FROM session s1
            GROUP BY projectId
            """)
        try db.execute(sql: "DELETE FROM project")
        let fm = FileManager.default
        for row in rows {
            let pid: String = row["pid"]
            let count: Int = row["cnt"]
            let lastActivity: Date? = row["la"]
            let sampleCwd: String? = row["sampleCwd"]
            let decoded = sampleCwd ?? PathCodec.decode(pid)
            try ProjectRecord(
                id: pid,
                decodedPath: decoded,
                displayName: PathCodec.displayName(forDecodedPath: decoded),
                sessionCount: count,
                lastActivity: lastActivity,
                cwdExists: fm.fileExists(atPath: decoded)
            ).save(db)
        }
    }

    // MARK: - Reads

    public func projects() async throws -> [Project] {
        try await dbQueue.read { db in
            try ProjectRecord.order(sql: "lastActivity DESC").fetchAll(db).map(\.project)
        }
    }

    public func sessionCount() async throws -> Int {
        try await dbQueue.read { db in try SessionRecord.fetchCount(db) }
    }

    /// True if some indexed sessions predate the full-text column and need a reparse.
    public func needsContentBackfill() async throws -> Bool {
        try await dbQueue.read { db in
            let total = try SessionRecord.fetchCount(db)
            guard total > 0 else { return false }
            let withText = try Int.fetchOne(db, sql: "SELECT count(*) FROM session WHERE fullText IS NOT NULL") ?? 0
            return withText < total
        }
    }

    public func search(_ rawQuery: String, filters: SearchFilters) async throws -> [SessionSummary] {
        try await dbQueue.read { db in
            let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let pattern = trimmed.isEmpty ? nil : try? FTS5Pattern(matchingAllPrefixesIn: trimmed)

            // Structured filters apply equally to keyword and recency queries.
            var conditions: [String] = []
            var conditionArgs: [DatabaseValueConvertible] = []
            if let projectId = filters.projectId { conditions.append("session.projectId = ?"); conditionArgs.append(projectId) }
            if let branch = filters.gitBranch { conditions.append("session.gitBranch = ?"); conditionArgs.append(branch) }
            if let entrypoint = filters.entrypoint { conditions.append("session.entrypoint = ?"); conditionArgs.append(entrypoint) }
            if let since = filters.since { conditions.append("session.lastActivity >= ?"); conditionArgs.append(since) }

            if let pattern {
                // snippet() marks matches with char(1)…char(2) so the UI can highlight them.
                var sql = """
                    SELECT session.*, snippet(session_ft, -1, char(1), char(2), '…', 12) AS snippet
                    FROM session JOIN session_ft ON session_ft.rowid = session.rowid
                    WHERE session_ft MATCH ?
                    """
                var args: [DatabaseValueConvertible] = [pattern]
                for condition in conditions { sql += " AND \(condition)" }
                args.append(contentsOf: conditionArgs)
                sql += " ORDER BY bm25(session_ft, 5.0, 2.0, 1.0) LIMIT 500"
                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                return try rows.map { row in
                    var summary = try SessionRecord(row: row).summary
                    summary.snippet = row["snippet"]
                    return summary
                }
            } else {
                var sql = "SELECT session.* FROM session"
                if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
                sql += " ORDER BY session.lastActivity DESC LIMIT 500"
                return try SessionRecord.fetchAll(db, sql: sql, arguments: StatementArguments(conditionArgs)).map(\.summary)
            }
        }
    }

    public func sessions(ids: [String]) async throws -> [SessionSummary] {
        guard !ids.isEmpty else { return [] }
        return try await dbQueue.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let sql = "SELECT * FROM session WHERE sessionId IN (\(placeholders)) ORDER BY lastActivity DESC"
            return try SessionRecord
                .fetchAll(db, sql: sql, arguments: StatementArguments(ids))
                .map(\.summary)
        }
    }

    public func distinctBranches() async throws -> [String] {
        try await dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT gitBranch FROM session WHERE gitBranch IS NOT NULL AND gitBranch <> '' ORDER BY gitBranch")
        }
    }

    public func distinctEntrypoints() async throws -> [String] {
        try await dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT entrypoint FROM session WHERE entrypoint IS NOT NULL AND entrypoint <> '' ORDER BY entrypoint")
        }
    }
}
