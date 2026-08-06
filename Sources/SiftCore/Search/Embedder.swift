import Foundation

/// Where vectors come from. Sift does not ship a model of its own, and Anthropic has no
/// embeddings API, so a Claude subscription cannot produce these. What it can use is a model
/// already running on the machine: Ollama, LM Studio, llama.cpp's server, anything that
/// answers on one of the two shapes below. That keeps the download at zero and the text on
/// the machine.
public struct EmbeddingBackend: Sendable, Hashable, Codable {
    public var name: String
    public var endpoint: URL
    public var model: String
    /// Ollama's own shape takes `input` and returns `embeddings`. The OpenAI-compatible one
    /// takes `input` and returns `data[].embedding`. Both are spoken by more than one server.
    public var openAICompatible: Bool

    public init(name: String, endpoint: URL, model: String, openAICompatible: Bool) {
        self.name = name
        self.endpoint = endpoint
        self.model = model
        self.openAICompatible = openAICompatible
    }

    /// Identifies which model produced a stored vector. Vectors from two models are not
    /// comparable, so this is written next to every one and a change invalidates them.
    public var fingerprint: String { "\(name):\(model)" }
}

public enum EmbeddingError: Error, Equatable {
    case noBackend
    case badResponse(String)
}

public protocol Embedding: Sendable {
    func embed(_ texts: [String]) async throws -> [[Float]]
    var fingerprint: String { get }
}

/// Talks to a local model server over HTTP. Nothing leaves the machine: the default hosts are
/// loopback, and a backend is only used when it answered a probe on this machine.
public struct LocalEmbedder: Embedding {
    public let backend: EmbeddingBackend
    private let session: URLSession

    public init(backend: EmbeddingBackend, session: URLSession = .shared) {
        self.backend = backend
        self.session = session
    }

    public var fingerprint: String { backend.fingerprint }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        var request = URLRequest(url: backend.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": backend.model,
            "input": texts,
        ])
        request.timeoutInterval = 120

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw EmbeddingError.badResponse("HTTP \(http.statusCode)")
        }
        return try Self.vectors(from: data, openAICompatible: backend.openAICompatible)
    }

    /// Both shapes, read leniently. A server that answers with numbers in the right place is
    /// good enough; there is no value in rejecting one that adds fields.
    public static func vectors(from data: Data, openAICompatible: Bool) throws -> [[Float]] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EmbeddingError.badResponse("not JSON")
        }
        if openAICompatible {
            guard let rows = object["data"] as? [[String: Any]] else {
                throw EmbeddingError.badResponse("no data array")
            }
            return rows.compactMap { row in (row["embedding"] as? [Double])?.map(Float.init) }
        }
        if let rows = object["embeddings"] as? [[Double]] {
            return rows.map { $0.map(Float.init) }
        }
        // The legacy /api/embeddings answers with a single vector under `embedding`.
        if let single = object["embedding"] as? [Double] {
            return [single.map(Float.init)]
        }
        throw EmbeddingError.badResponse("no embeddings")
    }
}

/// Finds a model server that is already running. Nothing is installed and nothing is
/// downloaded; if none answers, search stays lexical and says so.
public enum EmbeddingDiscovery {
    /// The servers worth probing, in the order they are preferred. Ollama first because it is
    /// the one most people already have, and its own shape reports errors more clearly than
    /// the compatibility layer.
    public static let candidates: [(name: String, probe: URL, embed: URL, openAI: Bool)] = [
        ("Ollama", URL(string: "http://127.0.0.1:11434/api/tags")!,
         URL(string: "http://127.0.0.1:11434/api/embed")!, false),
        ("LM Studio", URL(string: "http://127.0.0.1:1234/v1/models")!,
         URL(string: "http://127.0.0.1:1234/v1/embeddings")!, true),
    ]

    /// Model names that are embedding models rather than chat models. A chat model will
    /// happily answer an embedding request on some servers and give something useless.
    public static func looksLikeEmbeddingModel(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return ["embed", "bge", "gte", "e5", "minilm", "nomic"].contains { lowered.contains($0) }
    }

    public static func models(in payload: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return []
        }
        // Ollama answers {models: [{name}]}, the OpenAI shape answers {data: [{id}]}.
        if let rows = object["models"] as? [[String: Any]] {
            return rows.compactMap { $0["name"] as? String ?? $0["model"] as? String }
        }
        if let rows = object["data"] as? [[String: Any]] {
            return rows.compactMap { $0["id"] as? String }
        }
        return []
    }

    public static func discover(session: URLSession = .shared) async -> EmbeddingBackend? {
        for candidate in candidates {
            var request = URLRequest(url: candidate.probe)
            request.timeoutInterval = 2
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200
            else { continue }

            let names = models(in: data)
            guard let model = names.first(where: looksLikeEmbeddingModel) else { continue }
            return EmbeddingBackend(name: candidate.name, endpoint: candidate.embed,
                                    model: model, openAICompatible: candidate.openAI)
        }
        return nil
    }
}

public enum Vectors {
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<n {
            dot += Double(a[i]) * Double(b[i])
            na += Double(a[i]) * Double(a[i])
            nb += Double(b[i]) * Double(b[i])
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    public static func data(_ vector: [Float]) -> Data {
        var copy = vector
        return copy.withUnsafeMutableBufferPointer { Data(buffer: $0) }
    }

    public static func floats(_ data: Data) -> [Float] {
        guard !data.isEmpty, data.count % MemoryLayout<Float>.size == 0 else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Reciprocal rank fusion. Two rankings that disagree about scale still agree about order,
    /// so ranks are what get combined. A word match and a meaning match each pull a result up,
    /// and something both agree on lands at the top.
    public static func fuse(lexical: [String], semantic: [String], k: Double = 60) -> [String] {
        var score: [String: Double] = [:]
        for (index, id) in lexical.enumerated() { score[id, default: 0] += 1 / (k + Double(index + 1)) }
        for (index, id) in semantic.enumerated() { score[id, default: 0] += 1 / (k + Double(index + 1)) }
        return score.sorted { left, right in
            left.value == right.value ? left.key < right.key : left.value > right.value
        }.map(\.key)
    }
}
