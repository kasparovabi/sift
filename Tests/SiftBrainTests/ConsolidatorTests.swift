import XCTest
import Foundation
@testable import SiftBrain

final class ConsolidatorTests: XCTestCase {
    func makeStore() throws -> BrainStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("brain-\(UUID().uuidString).sqlite")
        return try BrainStore(path: url.path)
    }

    // Fake embedder: maps known strings to fixed vectors.
    // The closure captures only a local [String:[Float]] dictionary, which is Sendable.
    func fakeEmbed(_ table: [String: [Float]]) -> @Sendable (String) throws -> [Float] {
        { table[$0] ?? [0, 0] }
    }

    func testNewAtomInserted() throws {
        let store = try makeStore()
        let c = Consolidator(store: store, embed: fakeEmbed(["alpha": [1, 0]]), dedupThreshold: 0.92)
        let atom = try c.ingest(.init(t: .fact, s: "alpha", imp: 5, entities: []), proj: "p", src: "s#1")
        XCTAssertEqual(atom.s, "alpha")
        XCTAssertEqual(try store.validAtoms(proj: "p").count, 1)
    }

    func testNearDuplicateUpdatesNotInserts() throws {
        let store = try makeStore()
        let table: [String: [Float]] = ["alpha": [1, 0], "alpha2": [0.999, 0.01]]
        let c = Consolidator(store: store, embed: fakeEmbed(table), dedupThreshold: 0.92)
        _ = try c.ingest(.init(t: .fact, s: "alpha", imp: 5, entities: []), proj: "p", src: "s#1")
        _ = try c.ingest(.init(t: .fact, s: "alpha2", imp: 9, entities: []), proj: "p", src: "s#2")
        let atoms = try store.validAtoms(proj: "p")
        XCTAssertEqual(atoms.count, 1)              // merged, not duplicated
        XCTAssertEqual(atoms.first?.imp, 9)          // importance bumped
    }

    func testDistinctAtomsCoexist() throws {
        let store = try makeStore()
        let table: [String: [Float]] = ["alpha": [1, 0], "beta": [0, 1]]
        let c = Consolidator(store: store, embed: fakeEmbed(table), dedupThreshold: 0.92)
        _ = try c.ingest(.init(t: .fact, s: "alpha", imp: 5, entities: []), proj: "p", src: "s#1")
        _ = try c.ingest(.init(t: .fact, s: "beta", imp: 5, entities: []), proj: "p", src: "s#2")
        XCTAssertEqual(try store.validAtoms(proj: "p").count, 2)
    }

    func testEntitiesLinked() throws {
        let store = try makeStore()
        let c = Consolidator(store: store, embed: fakeEmbed(["x": [1, 0]]), dedupThreshold: 0.92)
        let atom = try c.ingest(.init(t: .decision, s: "x", imp: 5, entities: ["SwiftTerm"]), proj: "p", src: "s#1")
        let eids = try store.entityIds(forAtom: atom.id)
        XCTAssertEqual(eids.count, 1)
    }
}
