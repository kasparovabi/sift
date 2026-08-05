import XCTest
import Foundation
@testable import SiftBrain

final class BrainStoreTests: XCTestCase {
    func makeStore() throws -> BrainStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("brain-\(UUID().uuidString).sqlite")
        return try BrainStore(path: url.path)
    }

    func testInsertAndFetchAtom() throws {
        let store = try makeStore()
        let id = try store.insertAtom(t: .decision, s: "use SwiftTerm", proj: "sift", src: "s#1", imp: 8)
        let fetched = try store.atom(id: id)
        XCTAssertEqual(fetched?.s, "use SwiftTerm")
        XCTAssertEqual(fetched?.imp, 8)
        XCTAssertEqual(fetched?.t, .decision)
    }

    func testIdsAreSequentialBase62() throws {
        let store = try makeStore()
        let a = try store.insertAtom(t: .fact, s: "a", proj: nil, src: "s#1", imp: 1)
        let b = try store.insertAtom(t: .fact, s: "b", proj: nil, src: "s#2", imp: 1)
        XCTAssertNotEqual(a, b)
    }

    func testVectorData() {
        let v: [Float] = [1.0, -2.5, 3.0]
        let data = v.dataLE
        XCTAssertEqual([Float](dataLE: data), v)
    }
}
