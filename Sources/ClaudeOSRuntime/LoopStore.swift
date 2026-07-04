import Foundation
import GRDB

/// SQLite-backed store for loop tasks and their proof ledger (`loops.sqlite`). Separate file
/// from the index and the brain: this is the orchestration layer's own state on disk, so a
/// loop can be reviewed, re-run, or resumed across app restarts. Explicit column mapping (UUID
/// as text, dates as doubles) keeps the schema predictable and queryable.
///
/// `@unchecked Sendable` is safe: the only stored property is a `DatabaseQueue`, which
/// serializes all access through its own queue.
public final class LoopStore: @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    public init(path: String) throws {
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        dbQueue = try DatabaseQueue(path: path, configuration: config)
        try migrator.migrate(dbQueue)
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "loop_task") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("prompt", .text).notNull()
                t.column("cwd", .text).notNull()
                t.column("doneWhen", .text).notNull()
                t.column("checkKind", .text).notNull()
                t.column("maxPasses", .integer).notNull()
                t.column("rememberOnPass", .integer).notNull()
                t.column("state", .text).notNull()
                t.column("lastAttempt", .integer).notNull()
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double).notNull()
            }
            try db.create(table: "proof") { t in
                t.primaryKey("id", .text)
                t.column("taskId", .text).notNull()
                    .references("loop_task", onDelete: .cascade)
                t.column("attempt", .integer).notNull()
                t.column("makerOutput", .text).notNull()
                t.column("passed", .integer).notNull()
                t.column("checkerOutput", .text).notNull()
                t.column("date", .double).notNull()
            }
            try db.create(indexOn: "proof", columns: ["taskId"])
        }
        m.registerMigration("v2-makerSessionId") { db in
            try db.alter(table: "proof") { t in
                t.add(column: "makerSessionId", .text)
            }
        }
        return m
    }

    // MARK: - Tasks

    public func allTasks() throws -> [LoopTask] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM loop_task ORDER BY updatedAt DESC").map(Self.task)
        }
    }

    public func upsert(_ task: LoopTask) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO loop_task
                  (id, title, prompt, cwd, doneWhen, checkKind, maxPasses, rememberOnPass, state, lastAttempt, createdAt, updatedAt)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                  title=excluded.title, prompt=excluded.prompt, cwd=excluded.cwd, doneWhen=excluded.doneWhen,
                  checkKind=excluded.checkKind, maxPasses=excluded.maxPasses, rememberOnPass=excluded.rememberOnPass,
                  state=excluded.state, lastAttempt=excluded.lastAttempt, updatedAt=excluded.updatedAt
                """,
                arguments: [task.id.uuidString, task.title, task.prompt, task.cwd, task.doneWhen,
                            task.checkKind.rawValue, task.maxPasses, task.rememberOnPass ? 1 : 0,
                            task.state.rawValue, task.lastAttempt,
                            task.createdAt.timeIntervalSinceReferenceDate,
                            task.updatedAt.timeIntervalSinceReferenceDate])
        }
    }

    public func deleteTask(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM loop_task WHERE id = ?", arguments: [id.uuidString])
        }
    }

    // MARK: - Proof ledger

    public func insert(proof: ProofRecord) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO proof (id, taskId, attempt, makerOutput, passed, checkerOutput, makerSessionId, date)
                VALUES (?,?,?,?,?,?,?,?)
                """,
                arguments: [proof.id.uuidString, proof.taskId.uuidString, proof.attempt,
                            proof.makerOutput, proof.passed ? 1 : 0, proof.checkerOutput,
                            proof.makerSessionId, proof.date.timeIntervalSinceReferenceDate])
        }
    }

    public func proofs(taskId: UUID) throws -> [ProofRecord] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM proof WHERE taskId = ? ORDER BY attempt ASC",
                             arguments: [taskId.uuidString]).map(Self.proof)
        }
    }

    public func clearProofs(taskId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM proof WHERE taskId = ?", arguments: [taskId.uuidString])
        }
    }

    // MARK: - Row mapping

    private static func task(_ r: Row) -> LoopTask {
        LoopTask(
            id: UUID(uuidString: r["id"]) ?? UUID(),
            title: r["title"], prompt: r["prompt"], cwd: r["cwd"], doneWhen: r["doneWhen"],
            checkKind: CheckKind(rawValue: r["checkKind"]) ?? .agent,
            maxPasses: r["maxPasses"], rememberOnPass: (r["rememberOnPass"] as Int) != 0,
            state: LoopState(rawValue: r["state"]) ?? .idle,
            lastAttempt: r["lastAttempt"],
            createdAt: Date(timeIntervalSinceReferenceDate: r["createdAt"]),
            updatedAt: Date(timeIntervalSinceReferenceDate: r["updatedAt"]))
    }

    private static func proof(_ r: Row) -> ProofRecord {
        ProofRecord(
            id: UUID(uuidString: r["id"]) ?? UUID(),
            taskId: UUID(uuidString: r["taskId"]) ?? UUID(),
            attempt: r["attempt"], makerOutput: r["makerOutput"],
            passed: (r["passed"] as Int) != 0, checkerOutput: r["checkerOutput"],
            makerSessionId: r["makerSessionId"],
            date: Date(timeIntervalSinceReferenceDate: r["date"]))
    }
}
