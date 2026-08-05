import XCTest
import Foundation
@testable import SiftBrain

final class ConsolidatorRelationsTests: XCTestCase {
    func makeStore() throws -> BrainStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("brain-\(UUID().uuidString).sqlite")
        return try BrainStore(path: url.path)
    }

    func fakeEmbed(_ table: [String: [Float]]) -> @Sendable (String) throws -> [Float] {
        { table[$0] ?? [0, 0] }
    }

    /// Ingest a result with relation (sift -uses-> SwiftTerm), then supersede it with
    /// (sift -uses-> GRDB). Assert that only GRDB is a neighbor of sift.
    func testRelationsIngestedAndSuperseded() throws {
        let store = try makeStore()
        let embed = fakeEmbed(["hello": [1, 0]])
        let c = Consolidator(store: store, embed: embed)

        let result1 = ExtractionResult(
            atoms: [ExtractedAtom(t: .fact, s: "hello", imp: 5, entities: [])],
            relations: [(s: "sift", p: "uses", o: "SwiftTerm")]
        )
        try c.ingest(result: result1, proj: "p", src: "s#1")

        let result2 = ExtractionResult(
            atoms: [],
            relations: [(s: "sift", p: "uses", o: "GRDB")]
        )
        try c.ingest(result: result2, proj: "p", src: "s#2")

        let siftId = try store.resolveEntity(name: "sift", kind: "concept")
        let grdbId = try store.resolveEntity(name: "GRDB", kind: "concept")
        let swiftTermId = try store.resolveEntity(name: "SwiftTerm", kind: "concept")

        let neighbors = try store.neighbors(of: siftId)
        XCTAssertTrue(neighbors.contains(grdbId), "GRDB should be a neighbor")
        XCTAssertFalse(neighbors.contains(swiftTermId), "SwiftTerm relation should be superseded")
        XCTAssertEqual(neighbors.count, 1, "Only one valid neighbor expected")
    }
}
