import XCTest
import Foundation
@testable import SiftBrain

final class BrainServiceIngestTests: XCTestCase {
    struct StubRunner: CommandRunning {
        let output: String
        func run(_ executable: String, _ args: [String], stdin: String?, env: [String: String]) throws -> String {
            output
        }
    }

    func testIngestSessionIsIdempotentBySrc() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("brain-\(UUID().uuidString).sqlite")
        // Distinct vectors per claim so the two atoms don't cosine-merge.
        let svc = try BrainService(path: url.path, embed: { $0 == "alpha" ? [1, 0] : [0, 1] })
        let json = #"{"atoms":[{"t":"F","s":"alpha","imp":5,"entities":[]},{"t":"D","s":"beta","imp":7,"entities":[]}],"relations":[]}"#
        let extractor = Extractor(runner: StubRunner(output: json), claudePath: "/usr/bin/true", env: [:])

        try svc.ingestSession(transcript: "t", proj: "p", src: "sess-1", extractor: extractor)
        XCTAssertEqual(try svc.stats(), "atoms=2")

        // Re-fire for the same session: must be skipped, not re-ingested.
        try svc.ingestSession(transcript: "t (longer)", proj: "p", src: "sess-1", extractor: extractor)
        XCTAssertEqual(try svc.stats(), "atoms=2")
    }
}
