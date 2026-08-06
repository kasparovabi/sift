import XCTest
@testable import SiftCore

final class EmbedderTests: XCTestCase {
    func testOllamaAndTheOpenAIShapeBothRead() throws {
        let ollama = Data(#"{"embeddings":[[0.1,0.2],[0.3,0.4]]}"#.utf8)
        let read = try LocalEmbedder.vectors(from: ollama, openAICompatible: false)
        XCTAssertEqual(read.count, 2)
        XCTAssertEqual(read[1][1], 0.4, accuracy: 1e-6)

        let openAI = Data(#"{"object":"list","data":[{"index":0,"embedding":[1,2,3]}]}"#.utf8)
        XCTAssertEqual(try LocalEmbedder.vectors(from: openAI, openAICompatible: true), [[1, 2, 3]])
    }

    func testTheLegacySingleVectorShapeStillReads() throws {
        let legacy = Data(#"{"embedding":[0.5,0.5]}"#.utf8)
        XCTAssertEqual(try LocalEmbedder.vectors(from: legacy, openAICompatible: false), [[0.5, 0.5]])
    }

    func testAServerThatAnswersSomethingElseIsAnError() {
        XCTAssertThrowsError(try LocalEmbedder.vectors(from: Data("nope".utf8), openAICompatible: false))
        XCTAssertThrowsError(try LocalEmbedder.vectors(from: Data("{}".utf8), openAICompatible: false))
    }

    func testModelListsAreReadInBothShapes() {
        let ollama = Data(#"{"models":[{"name":"llama3:8b"},{"name":"nomic-embed-text:latest"}]}"#.utf8)
        XCTAssertEqual(EmbeddingDiscovery.models(in: ollama), ["llama3:8b", "nomic-embed-text:latest"])

        let openAI = Data(#"{"data":[{"id":"text-embedding-bge-m3"}]}"#.utf8)
        XCTAssertEqual(EmbeddingDiscovery.models(in: openAI), ["text-embedding-bge-m3"])
    }

    func testAChatModelIsNotAnEmbeddingModel() {
        // Some servers will answer an embedding request with a chat model and hand back
        // something that ranks like noise, which is worse than having no semantic search.
        XCTAssertTrue(EmbeddingDiscovery.looksLikeEmbeddingModel("nomic-embed-text:latest"))
        XCTAssertTrue(EmbeddingDiscovery.looksLikeEmbeddingModel("bge-m3"))
        XCTAssertTrue(EmbeddingDiscovery.looksLikeEmbeddingModel("all-MiniLM-L6-v2"))
        XCTAssertFalse(EmbeddingDiscovery.looksLikeEmbeddingModel("llama3:8b"))
        XCTAssertFalse(EmbeddingDiscovery.looksLikeEmbeddingModel("qwen2.5-coder"))
    }

    func testAVectorSurvivesTheRoundTripToDisk() {
        let vector: [Float] = [0.25, -0.5, 1, 0]
        XCTAssertEqual(Vectors.floats(Vectors.data(vector)), vector)
        XCTAssertEqual(Vectors.floats(Data()), [])
        XCTAssertEqual(Vectors.floats(Data([1, 2, 3])), [], "a truncated blob is not a vector")
    }

    func testCosineOrdersByCloseness() {
        let query: [Float] = [1, 0, 0]
        XCTAssertEqual(Vectors.cosine(query, [1, 0, 0]), 1, accuracy: 1e-6)
        XCTAssertEqual(Vectors.cosine(query, [0, 1, 0]), 0, accuracy: 1e-6)
        XCTAssertEqual(Vectors.cosine(query, [-1, 0, 0]), -1, accuracy: 1e-6)
        XCTAssertEqual(Vectors.cosine(query, [0, 0, 0]), 0, "a zero vector cannot be close to anything")
    }

    func testWhatBothRankingsAgreeOnComesFirst() {
        // The word search found b then a; the meaning search found a then b. `a` is the one
        // both put near the top.
        let fused = Vectors.fuse(lexical: ["b", "a", "c"], semantic: ["a", "d", "b"])
        XCTAssertEqual(fused.first, "a")
        XCTAssertEqual(Set(fused), ["a", "b", "c", "d"], "neither side's results are thrown away")
    }

    func testOneSidedResultsStillRank() {
        XCTAssertEqual(Vectors.fuse(lexical: ["a", "b"], semantic: []), ["a", "b"])
        XCTAssertEqual(Vectors.fuse(lexical: [], semantic: ["x", "y"]), ["x", "y"])
        XCTAssertEqual(Vectors.fuse(lexical: [], semantic: []), [])
    }

    func testVectorsFromTwoModelsAreNotComparable() {
        // Which is why the fingerprint is stored beside every vector and a change throws them
        // away rather than silently mixing two coordinate systems.
        let a = EmbeddingBackend(name: "Ollama", endpoint: URL(string: "http://127.0.0.1:11434/api/embed")!,
                                 model: "nomic-embed-text", openAICompatible: false)
        let b = EmbeddingBackend(name: "Ollama", endpoint: a.endpoint, model: "bge-m3",
                                 openAICompatible: false)
        XCTAssertNotEqual(a.fingerprint, b.fingerprint)
    }
}
