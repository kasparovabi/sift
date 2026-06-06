import XCTest
@testable import ClaudeOSBrain

final class ExtractorTests: XCTestCase {
    struct StubRunner: CommandRunning {
        let output: String
        func run(_ executable: String, _ args: [String], stdin: String?, env: [String: String]) throws -> String {
            output
        }
    }

    func testParsesEnvelopeAndInnerJSON() throws {
        let inner = #"{"atoms":[{"t":"D","s":"use SwiftTerm","imp":8,"entities":["SwiftTerm"]}],"relations":[{"s":"claudeos","p":"uses","o":"SwiftTerm"}]}"#
        let envelope = #"{"type":"result","result":"\#(inner.replacingOccurrences(of: "\"", with: "\\\""))"}"#
        let extractor = Extractor(runner: StubRunner(output: envelope), claudePath: "/usr/bin/true", env: [:])
        let result = try extractor.extract(transcript: "...", proj: "claudeos")
        XCTAssertEqual(result.atoms.count, 1)
        XCTAssertEqual(result.atoms[0].t, .decision)
        XCTAssertEqual(result.atoms[0].entities, ["SwiftTerm"])
        XCTAssertEqual(result.relations.count, 1)
        XCTAssertEqual(result.relations[0].p, "uses")
    }

    func testParsesBarePlainJSON() throws {
        // If runner returns the inner JSON directly (no envelope), still parse.
        let inner = #"{"atoms":[{"t":"F","s":"x","imp":3,"entities":[]}],"relations":[]}"#
        let extractor = Extractor(runner: StubRunner(output: inner), claudePath: "/usr/bin/true", env: [:])
        let result = try extractor.extract(transcript: "...", proj: nil)
        XCTAssertEqual(result.atoms.count, 1)
        XCTAssertEqual(result.atoms[0].imp, 3)
    }
}
