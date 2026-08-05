import XCTest
import Foundation
@testable import SiftBrain

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
        let a = try store.resolveEntity(name: "sift", kind: "project")
        let b = try store.resolveEntity(name: "GRDB", kind: "lib")
        try store.insertRelation(subjectId: a, predicate: "uses", objectId: b, src: "s#1")
        let neighbors = try store.neighbors(of: a)
        XCTAssertTrue(neighbors.contains(b))
    }

    // MARK: - graph(nodeLimit:)
    //
    // The graph view used to load entities and relations with two independent limits. On a
    // real store that produced 0 usable edges: the alphabetical entity page and the
    // insertion-ordered relation page referenced almost disjoint sets of ids.

    func testGraphReturnsEdgesBetweenTheNodesItReturns() async throws {
        let store = try makeStore()
        let a = try store.resolveEntity(name: "Alpha", kind: "lib")
        let b = try store.resolveEntity(name: "Beta", kind: "lib")
        let c = try store.resolveEntity(name: "Gamma", kind: "lib")
        _ = try store.insertRelation(subjectId: a, predicate: "uses", objectId: b, src: "s#1")
        _ = try store.insertRelation(subjectId: b, predicate: "uses", objectId: c, src: "s#2")

        let graph = try await store.graph(nodeLimit: 50)
        let ids = Set(graph.entities.map(\.id))
        XCTAssertFalse(graph.relations.isEmpty, "a store with relations must produce edges")
        for relation in graph.relations {
            XCTAssertTrue(ids.contains(relation.from), "edge endpoint missing from nodes")
            XCTAssertTrue(ids.contains(relation.to), "edge endpoint missing from nodes")
        }
    }

    /// The node cap must not silently drop every edge, which is exactly how the old
    /// two-limit version failed: nodes were kept, the edges between them were not.
    func testGraphStaysConnectedWhenTheNodeCapBites() async throws {
        let store = try makeStore()
        let hub = try store.resolveEntity(name: "Hub", kind: "lib")
        for i in 0..<12 {
            let leaf = try store.resolveEntity(name: "Leaf\(i)", kind: "lib")
            _ = try store.insertRelation(subjectId: hub, predicate: "uses", objectId: leaf, src: "s#\(i)")
        }
        let graph = try await store.graph(nodeLimit: 5)
        XCTAssertLessThanOrEqual(graph.entities.count, 5)
        XCTAssertFalse(graph.relations.isEmpty, "the hub and its kept leaves must stay linked")
    }

    func testGraphOnAnEmptyStoreIsEmptyRatherThanFailing() async throws {
        let graph = try await makeStore().graph(nodeLimit: 50)
        XCTAssertTrue(graph.entities.isEmpty)
        XCTAssertTrue(graph.relations.isEmpty)
    }
}
