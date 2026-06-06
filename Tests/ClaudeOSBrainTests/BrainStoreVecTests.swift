import XCTest
import Foundation
@testable import ClaudeOSBrain

final class BrainStoreVecTests: XCTestCase {
    func makeStore() throws -> BrainStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("brain-\(UUID().uuidString).sqlite")
        return try BrainStore(path: url.path)
    }

    func testSetAndGetVector() throws {
        let store = try makeStore()
        let id = try store.insertAtom(t: .fact, s: "x", proj: "p", src: "s#1", imp: 5)
        let v: [Float] = [0.1, 0.2, 0.3, 0.4]
        try store.setVector(atomId: id, v)
        XCTAssertEqual(try store.vector(atomId: id), v)
    }

    func testVectorsForAtomsScoped() throws {
        let store = try makeStore()
        let a = try store.insertAtom(t: .fact, s: "a", proj: "p1", src: "s#1", imp: 5)
        let b = try store.insertAtom(t: .fact, s: "b", proj: "p2", src: "s#2", imp: 5)
        try store.setVector(atomId: a, [1, 0])
        try store.setVector(atomId: b, [0, 1])
        let map = try store.vectors(forAtomIds: [a, b])
        XCTAssertEqual(map[a], [1, 0])
        XCTAssertEqual(map[b], [0, 1])
    }
}
