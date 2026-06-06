import XCTest
import Foundation
@testable import ClaudeOSBrain

final class ForgetterTests: XCTestCase {
    func makeService() throws -> BrainService {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("brain-\(UUID().uuidString).sqlite")
        return try BrainService(path: url.path, embed: { _ in [1, 0] })
    }
    func testForgetDropsLowValueNeverRetrieved() throws {
        let svc = try makeService()
        // low importance, never retrieved, old -> forgotten
        _ = try svc.store.insertAtom(t: .fact, s: "junk", proj: "p", src: "x", imp: 1, createdAt: 0)
        // high importance -> kept
        _ = try svc.store.insertAtom(t: .decision, s: "key", proj: "p", src: "x", imp: 9, createdAt: 0)
        let removed = try Forgetter(store: svc.store).sweep(now: 10_000_000, maxImportance: 3, minAgeSeconds: 1, requireZeroRetrievals: true)
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(try svc.store.atomCount(), 1)
    }
}
