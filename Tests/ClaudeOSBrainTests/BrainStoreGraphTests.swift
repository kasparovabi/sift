import XCTest
import Foundation
@testable import ClaudeOSBrain

final class BrainStoreGraphTests: XCTestCase {
    func makeStore() throws -> BrainStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("brain-\(UUID().uuidString).sqlite")
        return try BrainStore(path: url.path)
    }

    func testResolveEntityIsStable() throws {
        let store = try makeStore()
        let e1 = try store.resolveEntity(name: "SwiftTerm", kind: "lib")
        let e2 = try store.resolveEntity(name: "SwiftTerm", kind: "lib")
        XCTAssertEqual(e1, e2)
    }

    func testLinkAtomToEntities() throws {
        let store = try makeStore()
        let atomId = try store.insertAtom(t: .decision, s: "x", proj: "p", src: "s#1", imp: 5)
        let e = try store.resolveEntity(name: "GRDB", kind: "lib")
        try store.linkAtom(atomId, toEntities: [e])
        let ids = try store.entityIds(forAtom: atomId)
        XCTAssertEqual(ids, [e])
    }

    func testRelationAndNeighbors() throws {
        let store = try makeStore()
        let a = try store.resolveEntity(name: "claudeos", kind: "project")
        let b = try store.resolveEntity(name: "GRDB", kind: "lib")
        try store.insertRelation(subjectId: a, predicate: "uses", objectId: b, src: "s#1")
        let neighbors = try store.neighbors(of: a)
        XCTAssertTrue(neighbors.contains(b))
    }
}
