import XCTest
import Foundation
@testable import ClaudeOSBrain

final class BrainStoreUITests: XCTestCase {
    func makeStore() throws -> BrainStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("brain-\(UUID().uuidString).sqlite")
        return try BrainStore(path: url.path)
    }
    func testRecentAtomsOrdersByCreatedAtDesc() throws {
        let s = try makeStore()
        _ = try s.insertAtom(t: .fact, s: "old", proj: "p", src: "x", imp: 5, createdAt: 100)
        _ = try s.insertAtom(t: .fact, s: "new", proj: "p", src: "x", imp: 5, createdAt: 200)
        let recent = try s.recentAtoms(limit: 10)
        XCTAssertEqual(recent.first?.s, "new")
        XCTAssertEqual(recent.count, 2)
    }
    func testDeleteAtom() throws {
        let s = try makeStore()
        let id = try s.insertAtom(t: .fact, s: "x", proj: "p", src: "x", imp: 5)
        try s.deleteAtom(id: id)
        XCTAssertNil(try s.atom(id: id))
    }
    func testSetImportanceAndInvalidate() throws {
        let s = try makeStore()
        let id = try s.insertAtom(t: .fact, s: "x", proj: "p", src: "x", imp: 5)
        try s.setImportance(id: id, imp: 9)
        XCTAssertEqual(try s.atom(id: id)?.imp, 9)
        try s.invalidate(id: id, at: 123)
        XCTAssertEqual(try s.atom(id: id)?.invalidAt, 123)
    }
    func testAllEntities() throws {
        let s = try makeStore()
        _ = try s.resolveEntity(name: "SwiftTerm", kind: "lib")
        _ = try s.resolveEntity(name: "GRDB", kind: "lib")
        XCTAssertEqual(try s.allEntities(limit: 10).count, 2)
    }
    func testAtomCount() throws {
        let s = try makeStore()
        _ = try s.insertAtom(t: .fact, s: "a", proj: "p", src: "x", imp: 5)
        _ = try s.insertAtom(t: .fact, s: "b", proj: "p", src: "x", imp: 5)
        let id = try s.insertAtom(t: .fact, s: "c", proj: "p", src: "x", imp: 5)
        // invalidate one — atomCount excludes invalid
        try s.invalidate(id: id, at: 1)
        XCTAssertEqual(try s.atomCount(), 2)
    }
    func testEntityCount() throws {
        let s = try makeStore()
        _ = try s.resolveEntity(name: "E1", kind: "lib")
        _ = try s.resolveEntity(name: "E2", kind: "tool")
        XCTAssertEqual(try s.entityCount(), 2)
    }
}
