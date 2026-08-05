import XCTest
@testable import SiftBrain

final class EmbedderTests: XCTestCase {
    func testCosine() {
        XCTAssertEqual(cosine([1, 0], [1, 0]), 1.0, accuracy: 0.0001)
        XCTAssertEqual(cosine([1, 0], [0, 1]), 0.0, accuracy: 0.0001)
        XCTAssertEqual(cosine([1, 0], [-1, 0]), -1.0, accuracy: 0.0001)
    }

    func testEmbedSemantics() throws {
        guard let embedder = try? Embedder(), (try? embedder.load()) != nil else {
            throw XCTSkip("NLContextualEmbedding assets unavailable in this environment")
        }
        let a = try embedder.embed("the cat sat on the mat")
        let b = try embedder.embed("a feline rested on the rug")
        let c = try embedder.embed("quarterly financial report figures")
        XCTAssertGreaterThan(cosine(a, b), cosine(a, c))
    }
}
