import XCTest
import Foundation
import SiftBrain
@testable import SiftRuntime

final class BrainIngesterPathTests: XCTestCase {

    // firstLineCwd returns the cwd field from a well-formed first line
    func testFirstLineCwdReturnsField() throws {
        let f = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-\(UUID().uuidString).jsonl")
        let line = """
        {"cwd":"/Users/x/proj","type":"system"}
        """
        try line.write(to: f, atomically: true, encoding: .utf8)
        XCTAssertEqual(BrainIngester.firstLineCwd(f.path), "/Users/x/proj")
    }

    // firstLineCwd returns nil when no cwd field is present
    func testFirstLineCwdReturnsNilWhenNoCwdField() throws {
        let f = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-\(UUID().uuidString).jsonl")
        let line = """
        {"type":"assistant","message":"hello"}
        """
        try line.write(to: f, atomically: true, encoding: .utf8)
        XCTAssertNil(BrainIngester.firstLineCwd(f.path))
    }

    // firstLineCwd returns nil for a missing file
    func testFirstLineCwdReturnsNilForMissingFile() {
        XCTAssertNil(BrainIngester.firstLineCwd("/no/such/file.jsonl"))
    }

    // firstLineCwd only reads the first line, ignoring subsequent ones
    func testFirstLineCwdUsesOnlyFirstLine() throws {
        let f = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-\(UUID().uuidString).jsonl")
        let content = """
        {"cwd":"/first/line"}
        {"cwd":"/second/line"}
        """
        try content.write(to: f, atomically: true, encoding: .utf8)
        XCTAssertEqual(BrainIngester.firstLineCwd(f.path), "/first/line")
    }

    // Machine-generated sessions (our extractor + other memory tools) are skipped;
    // real human sessions are ingested. This is what keeps the background `claude -p`
    // load from exploding when other tools churn the sessions folder.
    func testIsNoiseTranscriptSkipsMachineSessions() {
        XCTAssertTrue(BrainIngester.isNoiseTranscript("… \(Extractor.instructionMarker) from the transcript …"))
        XCTAssertTrue(BrainIngester.isNoiseTranscript("You are a Claude-Mem, a specialized observer tool"))
        XCTAssertTrue(BrainIngester.isNoiseTranscript("Hello memory agent, you are continuing to observe the primary Claude session."))
        XCTAssertFalse(BrainIngester.isNoiseTranscript("user: let us refactor this function"))
    }
}
