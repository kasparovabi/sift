import Foundation
import GRDB

public final class BrainStore {
    private let dbQueue: DatabaseQueue

    public init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try migrator.migrate(dbQueue)
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "brain_meta") { t in
                t.primaryKey("key", .text)
                t.column("value", .integer).notNull()
            }
            try db.create(table: "atom") { t in
                t.primaryKey("id", .text)
                t.column("t", .text).notNull()
                t.column("s", .text).notNull()
                t.column("proj", .text)
                t.column("src", .text).notNull()
                t.column("imp", .integer).notNull()
                t.column("createdAt", .double).notNull()
                t.column("validAt", .double)
                t.column("invalidAt", .double)
                t.column("retrievals", .integer).notNull().defaults(to: 0)
                t.column("lastRetrievedAt", .double)
            }
            try db.create(table: "entity") { t in
                t.primaryKey("id", .text)
                t.column("n", .text).notNull()
                t.column("k", .text).notNull()
            }
            try db.create(table: "entity_alias") { t in
                t.column("entityId", .text).notNull().references("entity", onDelete: .cascade)
                t.column("alias", .text).notNull()
            }
            try db.create(table: "atom_entity") { t in
                t.column("atomId", .text).notNull().references("atom", onDelete: .cascade)
                t.column("entityId", .text).notNull().references("entity", onDelete: .cascade)
                t.primaryKey(["atomId", "entityId"])
            }
            try db.create(table: "relation") { t in
                t.primaryKey("id", .text)
                t.column("subjectId", .text).notNull()
                t.column("predicate", .text).notNull()
                t.column("objectId", .text).notNull()
                t.column("validAt", .double)
                t.column("invalidAt", .double)
                t.column("src", .text).notNull()
            }
            try db.create(virtualTable: "atom_ft", using: FTS5()) { t in
                t.synchronize(withTable: "atom")
                t.column("s")
                t.tokenizer = .unicode61()
                t.prefixes = [2, 3]
            }
            try db.create(table: "atom_vec") { t in
                t.primaryKey("atomId", .text).references("atom", onDelete: .cascade)
                t.column("dim", .integer).notNull()
                t.column("vec", .blob).notNull()
            }
        }
        return m
    }

    // MARK: - IDs

    private func nextId(_ db: Database) throws -> String {
        let current = try Int.fetchOne(db, sql: "SELECT value FROM brain_meta WHERE key = 'seq'") ?? 0
        let next = current + 1
        try db.execute(sql: """
            INSERT INTO brain_meta(key, value) VALUES('seq', ?)
            ON CONFLICT(key) DO UPDATE SET value = ?
            """, arguments: [next, next])
        return Base62.encode(next)
    }

    // MARK: - Atoms

    @discardableResult
    public func insertAtom(t: AtomType, s: String, proj: String?, src: String, imp: Int,
                           createdAt: Double = Date().timeIntervalSince1970) throws -> String {
        try dbQueue.write { db in
            let id = try nextId(db)
            let atom = Atom(id: id, t: t, s: s, proj: proj, src: src, imp: imp,
                            createdAt: createdAt, validAt: nil, invalidAt: nil,
                            retrievals: 0, lastRetrievedAt: nil)
            try atom.insert(db)
            return id
        }
    }

    public func atom(id: String) throws -> Atom? {
        try dbQueue.read { db in try Atom.fetchOne(db, key: id) }
    }

    public func updateAtom(_ atom: Atom) throws {
        try dbQueue.write { db in try atom.update(db) }
    }

    /// Valid (non-superseded) atoms, optionally scoped to a project.
    public func validAtoms(proj: String?) throws -> [Atom] {
        try dbQueue.read { db in
            if let proj {
                return try Atom.filter(sql: "invalidAt IS NULL AND proj = ?", arguments: [proj]).fetchAll(db)
            }
            return try Atom.filter(sql: "invalidAt IS NULL").fetchAll(db)
        }
    }

    public func markRetrieved(_ ids: [String], at: Double = Date().timeIntervalSince1970) throws {
        guard !ids.isEmpty else { return }
        try dbQueue.write { db in
            for id in ids {
                try db.execute(sql: "UPDATE atom SET retrievals = retrievals + 1, lastRetrievedAt = ? WHERE id = ?",
                               arguments: [at, id])
            }
        }
    }

    // MARK: - Entities

    /// Find an entity by exact name (or alias), else create it. Returns its id.
    public func resolveEntity(name: String, kind: String) throws -> String {
        try dbQueue.write { db in
            if let existing = try Entity.filter(sql: "n = ?", arguments: [name]).fetchOne(db) {
                return existing.id
            }
            if let aliasId = try String.fetchOne(db, sql: "SELECT entityId FROM entity_alias WHERE alias = ?", arguments: [name]) {
                return aliasId
            }
            let id = try nextId(db)
            try Entity(id: id, n: name, k: kind).insert(db)
            return id
        }
    }

    public func linkAtom(_ atomId: String, toEntities entityIds: [String]) throws {
        try dbQueue.write { db in
            for eid in entityIds {
                try db.execute(sql: "INSERT OR IGNORE INTO atom_entity(atomId, entityId) VALUES(?, ?)",
                               arguments: [atomId, eid])
            }
        }
    }

    public func entityIds(forAtom atomId: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT entityId FROM atom_entity WHERE atomId = ? ORDER BY entityId",
                                arguments: [atomId])
        }
    }

    public func atomIds(forEntity entityId: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT atomId FROM atom_entity WHERE entityId = ?", arguments: [entityId])
        }
    }

    // MARK: - Relations

    @discardableResult
    public func insertRelation(subjectId: String, predicate: String, objectId: String, src: String,
                               at: Double = Date().timeIntervalSince1970) throws -> String {
        try dbQueue.write { db in
            let id = try nextId(db)
            try Relation(id: id, subjectId: subjectId, predicate: predicate, objectId: objectId,
                         validAt: at, invalidAt: nil, src: src).insert(db)
            return id
        }
    }

    /// 1-hop neighbor entity ids (valid relations only), in either direction.
    public func neighbors(of entityId: String) throws -> [String] {
        try dbQueue.read { db in
            let out = try String.fetchAll(db, sql: "SELECT objectId FROM relation WHERE subjectId = ? AND invalidAt IS NULL", arguments: [entityId])
            let inc = try String.fetchAll(db, sql: "SELECT subjectId FROM relation WHERE objectId = ? AND invalidAt IS NULL", arguments: [entityId])
            return Array(Set(out + inc))
        }
    }

    /// Mark relations matching (subject, predicate) as superseded.
    public func supersedeRelations(subjectId: String, predicate: String, at: Double = Date().timeIntervalSince1970) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE relation SET invalidAt = ? WHERE subjectId = ? AND predicate = ? AND invalidAt IS NULL",
                           arguments: [at, subjectId, predicate])
        }
    }

    // MARK: - Vectors

    public func setVector(atomId: String, _ vector: [Float]) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO atom_vec(atomId, dim, vec) VALUES(?, ?, ?)
                ON CONFLICT(atomId) DO UPDATE SET dim = excluded.dim, vec = excluded.vec
                """, arguments: [atomId, vector.count, vector.dataLE])
        }
    }

    public func vector(atomId: String) throws -> [Float]? {
        try dbQueue.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT vec FROM atom_vec WHERE atomId = ?",
                                              arguments: [atomId]) else {
                return nil
            }
            return [Float](dataLE: data)
        }
    }

    public func vectors(forAtomIds ids: [String]) throws -> [String: [Float]] {
        guard !ids.isEmpty else { return [:] }
        return try dbQueue.read { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db,
                sql: "SELECT atomId, vec FROM atom_vec WHERE atomId IN (\(placeholders))",
                arguments: StatementArguments(ids))
            var result: [String: [Float]] = [:]
            for row in rows {
                let atomId: String = row["atomId"]
                let data: Data = row["vec"]
                result[atomId] = [Float](dataLE: data)
            }
            return result
        }
    }

    // MARK: - Full-text search

    public func searchFTS(_ query: String, limit: Int) throws -> [Atom] {
        try dbQueue.read { db in
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let pattern = FTS5Pattern(matchingAllPrefixesIn: trimmed) else {
                return []
            }
            return try Atom.fetchAll(db, sql: """
                SELECT atom.* FROM atom
                JOIN atom_ft ON atom_ft.rowid = atom.rowid
                WHERE atom_ft MATCH ? AND atom.invalidAt IS NULL
                ORDER BY bm25(atom_ft)
                LIMIT ?
                """, arguments: [pattern, limit])
        }
    }
}
