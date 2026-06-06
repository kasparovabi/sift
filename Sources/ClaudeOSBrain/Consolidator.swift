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
    public let embed: (String) throws -> [Float]
    public let dedupThreshold: Float

    public init(store: BrainStore, embed: @escaping (String) throws -> [Float], dedupThreshold: Float = 0.92) {
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

    private func linkEntities(_ names: [String], to atomId: String) throws {
        guard !names.isEmpty else { return }
        var ids: [String] = []
        for name in names {
            ids.append(try store.resolveEntity(name: name, kind: "concept"))
        }
        try store.linkAtom(atomId, toEntities: ids)
    }
}
