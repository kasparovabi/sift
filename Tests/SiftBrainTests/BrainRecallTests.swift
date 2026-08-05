import XCTest
import Foundation
@testable import SiftBrain

final class BrainRecallTests: XCTestCase {
    func makeStore() throws -> BrainStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("brain-\(UUID().uuidString).sqlite")
        return try BrainStore(path: url.path)
    }

    func testRankByQueryVector() throws {
        let store = try makeStore()
        let near = try store.insertAtom(t: .fact, s: "near", proj: "p", src: "s#1", imp: 5)
        let far = try store.insertAtom(t: .fact, s: "far", proj: "p", src: "s#2", imp: 5)
        try store.setVector(atomId: near, [1, 0])
        try store.setVector(atomId: far, [0, 1])
        let recall = BrainRecall(store: store)
        let results = try recall.recall(queryVector: [0.9, 0.1], proj: "p", k: 2)
        XCTAssertEqual(results.first?.id, near)
    }

    func testImportanceBreaksTies() throws {
        let store = try makeStore()
        let lo = try store.insertAtom(t: .fact, s: "lo", proj: "p", src: "s#1", imp: 1)
        let hi = try store.insertAtom(t: .fact, s: "hi", proj: "p", src: "s#2", imp: 10)
        try store.setVector(atomId: lo, [1, 0])
        try store.setVector(atomId: hi, [1, 0]) // identical relevance
        let recall = BrainRecall(store: store)
        let results = try recall.recall(queryVector: [1, 0], proj: "p", k: 2)
        XCTAssertEqual(results.first?.id, hi)
    }

    /// A candidate whose stored vector has a different dimension than the query is not
    /// returned as the top match over a correct-dimension atom, and does not crash.
    /// Without the guard, a dim=1 stored vector [1.0] would score cosine=1.0 against
    /// query [1.0, 0.0], beating a correct dim=2 vector [0.9, 0.1] (~0.994).
    func testDimMismatchNotTopMatch() throws {
        let store = try makeStore()
        let correct = try store.insertAtom(t: .fact, s: "correct", proj: "p", src: "s#1", imp: 5)
        let mismatch = try store.insertAtom(t: .fact, s: "mismatch", proj: "p", src: "s#2", imp: 5)
        // correct atom dim=2 matches query dim=2; cosine ~0.994
        try store.setVector(atomId: correct, [0.9, 0.1])
        // mismatch atom dim=1 differs from query dim=2; current cosine(partial)=1.0 which is wrong
        try store.setVector(atomId: mismatch, [1.0])
        let recall = BrainRecall(store: store)
        let results = try recall.recall(queryVector: [1.0, 0.0], proj: "p", k: 2)
        XCTAssertEqual(results.first?.id, correct, "Dim-mismatch atom must not outscore correct-dim atom")
    }

    func testExcludesInvalidated() throws {
        let store = try makeStore()
        let id = try store.insertAtom(t: .fact, s: "old", proj: "p", src: "s#1", imp: 5)
        try store.setVector(atomId: id, [1, 0])
        var atom = try XCTUnwrap(store.atom(id: id))
        atom.invalidAt = 1
        try store.updateAtom(atom)
        let recall = BrainRecall(store: store)
        XCTAssertTrue(try recall.recall(queryVector: [1, 0], proj: "p", k: 5).isEmpty)
    }
}
