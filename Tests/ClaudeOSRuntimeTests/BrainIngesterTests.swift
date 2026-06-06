import XCTest
import Foundation
import ClaudeOSBrain
@testable import ClaudeOSRuntime

final class BrainIngesterTests: XCTestCase {
    func makeIngester(root: URL) throws -> BrainIngester {
        let dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("brain-\(UUID().uuidString).sqlite")
        let svc = try BrainService(path: dbURL.path, embed: { _ in [0, 0] })
        return BrainIngester(service: svc, claudePath: "/usr/bin/true", env: [:], projectsRoot: root, cap: 60_000)
    }

    func testTranscriptPathEncodesCwd() throws {
        let ing = try makeIngester(root: URL(fileURLWithPath: "/tmp/projects"))
        XCTAssertEqual(ing.transcriptPath(cwd: "/Users/x/proj", claudeSessionId: "abc"),
                       "/tmp/projects/-Users-x-proj/abc.jsonl")
    }

    func testBoundedReadSmallReturnsAll() throws {
        let f = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("t-\(UUID().uuidString).txt")
        try "hello".write(to: f, atomically: true, encoding: .utf8)
        XCTAssertEqual(BrainIngester.boundedRead(f.path, cap: 60_000), "hello")
    }

    func testBoundedReadMissingReturnsNil() {
        XCTAssertNil(BrainIngester.boundedRead("/no/such/file.jsonl", cap: 100))
    }

    func testBoundedReadLargeTruncatesWithMarker() throws {
        let f = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("t-\(UUID().uuidString).txt")
        let big = String(repeating: "A", count: 300) + String(repeating: "B", count: 300)
        try big.write(to: f, atomically: true, encoding: .utf8)
        let out = try XCTUnwrap(BrainIngester.boundedRead(f.path, cap: 120))
        XCTAssertTrue(out.contains("…"))
        XCTAssertLessThan(out.count, big.count)
    }
}
