import XCTest
import Foundation
@testable import SiftBrain

final class BrainServiceTests: XCTestCase {
    func makeService(_ table: [String: [Float]]) throws -> BrainService {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("brain-\(UUID().uuidString).sqlite")
        let embed: @Sendable (String) throws -> [Float] = { table[$0] ?? [0, 0] }
        return try BrainService(path: url.path, embed: embed)
    }

    func testRememberThenSearch() throws {
        let table: [String: [Float]] = ["use SwiftTerm for PTY": [1, 0], "find pty": [0.95, 0.05]]
        let svc = try makeService(table)
        _ = try svc.remember(text: "use SwiftTerm for PTY", type: .decision, importance: 8, proj: "sift")
        let out = try svc.search(query: "find pty", proj: "sift", k: 5)
        XCTAssertTrue(out.contains("SwiftTerm"))
        XCTAssertTrue(out.hasPrefix("#brain1"))  // BrainText
    }

    func testStats() throws {
        let svc = try makeService(["a": [1, 0]])
        _ = try svc.remember(text: "a", type: .fact, importance: 5, proj: "p")
        let stats = try svc.stats()
        XCTAssertTrue(stats.contains("1"))  // at least one atom counted
    }

    func testProjectDigest() throws {
        let table: [String: [Float]] = ["x": [1, 0], "y": [0, 1]]
        let svc = try makeService(table)
        _ = try svc.remember(text: "x", type: .decision, importance: 9, proj: "p")
        _ = try svc.remember(text: "y", type: .fact, importance: 3, proj: "p")
        let digest = try svc.projectDigest(proj: "p", limit: 1)
        XCTAssertTrue(digest.contains("x"))   // highest-importance atom surfaces
        XCTAssertFalse(digest.contains("\ny,")) // limit respected (only 1 atom row)
    }
}
