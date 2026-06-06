import Foundation

public struct BrainRecall {
    public let store: BrainStore
    public var wRecency: Float
    public var wImportance: Float
    public var wRelevance: Float
    public var decayHalfLifeSeconds: Float

    public init(store: BrainStore,
                wRecency: Float = 0.25, wImportance: Float = 0.25, wRelevance: Float = 0.5,
                decayHalfLifeSeconds: Float = 60 * 60 * 24 * 30) {
        self.store = store
        self.wRecency = wRecency
        self.wImportance = wImportance
        self.wRelevance = wRelevance
        self.decayHalfLifeSeconds = decayHalfLifeSeconds
    }

    /// Hybrid recall using a precomputed query vector. Returns top-K valid atoms, marks them retrieved.
    public func recall(queryVector: [Float], proj: String?, k: Int,
                       now: Double = Date().timeIntervalSince1970) throws -> [Atom] {
        let candidates = try store.validAtoms(proj: proj)
        guard !candidates.isEmpty else { return [] }
        let vectors = try store.vectors(forAtomIds: candidates.map(\.id))
        let scored: [(Atom, Float)] = candidates.map { atom in
            let relevance = vectors[atom.id].map { cosine(queryVector, $0) } ?? 0
            let age = Float(now - (atom.lastRetrievedAt ?? atom.createdAt))
            let recency = exp(-max(0, age) / decayHalfLifeSeconds)
            let score = wRecency * recency
                      + wImportance * Float(atom.imp) / 10
                      + wRelevance * relevance
            return (atom, score)
        }
        let top = scored.sorted { $0.1 > $1.1 }.prefix(k).map(\.0)
        try store.markRetrieved(top.map(\.id), at: now)
        return Array(top)
    }
}
