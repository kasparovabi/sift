import Foundation

public struct ExtractedAtom {
    public var t: AtomType
    public var s: String
    public var imp: Int
    public var entities: [String]
    public init(t: AtomType, s: String, imp: Int, entities: [String]) {
        self.t = t; self.s = s; self.imp = imp; self.entities = entities
    }
}

public struct Consolidator {
    public let store: BrainStore
    public let embed: @Sendable (String) throws -> [Float]
    public let dedupThreshold: Float

    public init(store: BrainStore, embed: @escaping @Sendable (String) throws -> [Float], dedupThreshold: Float = 0.92) {
        self.store = store
        self.embed = embed
        self.dedupThreshold = dedupThreshold
    }

    /// Ingest one extracted atom: dedup against same-project atoms, else insert.
    @discardableResult
    public func ingest(_ extracted: ExtractedAtom, proj: String?, src: String,
                       now: Double = Date().timeIntervalSince1970) throws -> Atom {
        let vec = try embed(extracted.s)

        // Find nearest existing valid atom in the same project.
        let existing = try store.validAtoms(proj: proj)
        let vectors = try store.vectors(forAtomIds: existing.map(\.id))
        var best: (atom: Atom, cos: Float)?
        for atom in existing {
            guard let v = vectors[atom.id] else { continue }
            // Treat dimension mismatch as non-comparable (skip dedup candidate).
            guard v.count == vec.count else { continue }
            let c = cosine(vec, v)
            if best == nil || c > best!.cos { best = (atom, c) }
        }

        if let best, best.cos >= dedupThreshold {
            // Merge: bump importance, refresh recency.
            var merged = best.atom
            merged.imp = max(merged.imp, extracted.imp)
            merged.createdAt = now
            try store.updateAtom(merged)
            try linkEntities(extracted.entities, to: merged.id)
            return merged
        }

        // Insert new.
        let id = try store.insertAtom(t: extracted.t, s: extracted.s, proj: proj, src: src, imp: extracted.imp, createdAt: now)
        try store.setVector(atomId: id, vec)
        try linkEntities(extracted.entities, to: id)
        return try store.atom(id: id)!
    }

    /// Ingest a full extraction result: atoms (deduped) then relations (bi-temporal supersede).
    public func ingest(result: ExtractionResult, proj: String?, src: String,
                       now: Double = Date().timeIntervalSince1970) throws {
        // Pre-resolve entities with their real kinds before ingesting atoms.
        // resolveEntity is idempotent by name, so if the entity already exists it
        // keeps its current kind; if new, it gets the extracted kind.
        for (name, kind) in result.entityKinds {
            _ = try store.resolveEntity(name: name, kind: kind)
        }
        for atom in result.atoms { try ingest(atom, proj: proj, src: src, now: now) }
        for rel in result.relations {
            let s = try store.resolveEntity(name: rel.s, kind: "concept")
            let o = try store.resolveEntity(name: rel.o, kind: "concept")
            try store.supersedeRelations(subjectId: s, predicate: rel.p, at: now)
            try store.insertRelation(subjectId: s, predicate: rel.p, objectId: o, src: src, at: now)
        }
    }

    private func linkEntities(_ names: [String], to atomId: String) throws {
        guard !names.isEmpty else { return }
        var ids: [String] = []
        for name in names {
            ids.append(try store.resolveEntity(name: name, kind: "concept"))
        }
        try store.linkAtom(atomId, toEntities: ids)
    }
}
