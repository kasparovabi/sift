import XCTest
import Foundation
@testable import SiftBrain

final class BrainStoreFTSTests: XCTestCase {
    func makeStore() throws -> BrainStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("brain-\(UUID().uuidString).sqlite")
        return try BrainStore(path: url.path)
    }

    func testPrefixSearch() async throws {
        let store = try makeStore()
        _ = try store.insertAtom(t: .fact, s: "GRDB FTS5 parser configuration", proj: "p", src: "s#1", imp: 5)
        _ = try store.insertAtom(t: .fact, s: "unrelated note about windows", proj: "p", src: "s#2", imp: 5)
        let hits = try await store.searchFTS("pars", limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits.first?.s.contains("parser") ?? false)
    }
}
