import Foundation
import NaturalLanguage

public func cosine(_ a: [Float], _ b: [Float]) -> Float {
    let n = min(a.count, b.count)
    guard n > 0 else { return 0 }
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    for i in 0..<n {
        dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]
    }
    let denom = (na.squareRoot() * nb.squareRoot())
    return denom == 0 ? 0 : dot / denom
}

/// On-device sentence embedder using Apple's NLContextualEmbedding (mean-pooled token vectors).
public final class Embedder {
    private let model: NLContextualEmbedding
    public let dimension: Int

    public init(language: NLLanguage = .english) throws {
        guard let model = NLContextualEmbedding(language: language) else {
            throw EmbedderError.unavailable
        }
        self.model = model
        self.dimension = model.dimension
    }

    @discardableResult
    public func load() throws -> Bool {
        if !model.hasAvailableAssets {
            throw EmbedderError.assetsMissing
        }
        try model.load()
        return true
    }

    public func embed(_ text: String) throws -> [Float] {
        guard !text.isEmpty else { return [Float](repeating: 0, count: dimension) }
        let result = try model.embeddingResult(for: text, language: nil)
        var sum = [Double](repeating: 0, count: dimension)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            for i in 0..<Swift.min(self.dimension, vector.count) { sum[i] += vector[i] }
            count += 1
            return true
        }
        guard count > 0 else { return [Float](repeating: 0, count: dimension) }
        return sum.map { Float($0 / Double(count)) }
    }

    public enum EmbedderError: Error { case unavailable, assetsMissing }
}
