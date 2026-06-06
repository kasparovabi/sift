import Foundation

/// High-level façade over the brain engine, used by both the MCP server and the app.
public final class BrainService: @unchecked Sendable {
    public let store: BrainStore
    private let embed: @Sendable (String) throws -> [Float]
    private let recall: BrainRecall
    private let consolidator: Consolidator

    /// Test/explicit init with an injected embed closure.
    public init(path: String, embed: @escaping @Sendable (String) throws -> [Float],
                dedupThreshold: Float = 0.92) throws {
        self.store = try BrainStore(path: path)
        self.embed = embed
        self.recall = BrainRecall(store: store)
        self.consolidator = Consolidator(store: store, embed: embed, dedupThreshold: dedupThreshold)
    }

    /// Production init: builds an on-device Embedder. If assets are unavailable,
    /// degrades to a zero-vector embed (FTS/graph still work; semantic recall disabled).
    public convenience init(path: String, language: NLLanguageBox = .english) throws {
        if let embedder = try? Embedder(), (try? embedder.load()) != nil {
            let box = EmbedderBox(embedder)
            try self.init(path: path, embed: { try box.embed($0) })
        } else {
            FileHandle.standardError.write(Data(
                "ClaudeOS brain: NLContextualEmbedding unavailable; running FTS-only (semantic recall disabled)\n".utf8))
            try self.init(path: path, embed: { _ in [] })
        }
    }

    public func remember(text: String, type: AtomType, importance: Int, proj: String?,
                         src: String = "manual") throws -> String {
        let atom = try consolidator.ingest(.init(t: type, s: text, imp: importance, entities: []),
                                           proj: proj, src: src)
        return "ok: \(atom.id)"
    }

    public func search(query: String, proj: String?, k: Int) throws -> String {
        let qv = (try? embed(query)) ?? []
        let atoms: [Atom]
        if qv.isEmpty {
            atoms = try store.searchFTS(query, limit: k)            // degraded path
        } else {
            atoms = try recall.recall(queryVector: qv, proj: proj, k: k)
        }
        return BrainCodec.encode(atoms: atoms, relations: [], proj: proj)
    }

    public func recall(entity name: String) throws -> String {
        let eid = try store.resolveEntity(name: name, kind: "concept")
        let atomIds = try store.atomIds(forEntity: eid)
        let atoms = try atomIds.compactMap { try store.atom(id: $0) }.filter { $0.invalidAt == nil }
        return BrainCodec.encode(atoms: atoms, relations: [], proj: nil)
    }

    public func projectDigest(proj: String, limit: Int) throws -> String {
        let all = try store.validAtoms(proj: proj).sorted { $0.imp > $1.imp }
        let top = Array(all.prefix(limit))
        return BrainCodec.encode(atoms: top, relations: [], proj: proj)
    }

    public func stats() throws -> String {
        let atoms = try store.validAtoms(proj: nil).count
        return "atoms=\(atoms)"
    }

    @discardableResult
    public func forget() throws -> Int {
        try Forgetter(store: store).sweep()
    }

    public func ingestSession(transcript: String, proj: String?, src: String,
                              extractor: Extractor) throws {
        // Idempotent: skip a session already ingested. Prevents unbounded duplicates
        // on re-fire (e.g. resume→exit again), critical in FTS-only mode where cosine
        // dedup is disabled (empty vectors).
        if try store.hasAtoms(src: src) { return }
        let result = try extractor.extract(transcript: transcript, proj: proj)
        try consolidator.ingest(result: result, proj: proj, src: src)
    }
}

/// Small wrapper so the non-Sendable Embedder can back a @Sendable closure via a lock.
final class EmbedderBox: @unchecked Sendable {
    private let embedder: Embedder
    private let lock = NSLock()
    init(_ e: Embedder) { embedder = e }
    func embed(_ s: String) throws -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return try embedder.embed(s)
    }
}

/// Avoids importing NaturalLanguage in BrainService signature; maps to NLLanguage.
public enum NLLanguageBox { case english }
