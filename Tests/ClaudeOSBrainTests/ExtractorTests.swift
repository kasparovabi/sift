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

    final class CapturingRunner: CommandRunning, @unchecked Sendable {
        var args: [String] = []
        func run(_ executable: String, _ args: [String], stdin: String?, env: [String: String]) throws -> String {
            self.args = args
            return #"{"atoms":[],"relations":[]}"#
        }
    }

    /// Extraction must NOT pass --no-session-persistence. On current claude builds that flag
    /// makes `-p ... --output-format json` return an empty `result` (the agent loops and
    /// never emits a final answer), which silently produced zero atoms. The duties the flag
    /// used to serve are handled elsewhere now: BrainIngester.isNoiseTranscript breaks the
    /// re-ingest loop, and the persisted run is cleaned up after extraction.
    func testExtractionDoesNotSendNoPersistenceFlag() throws {
        let runner = CapturingRunner()
        let extractor = Extractor(runner: runner, claudePath: "/usr/bin/true", env: [:])
        _ = try extractor.extract(transcript: "hi", proj: nil)
        XCTAssertFalse(runner.args.contains("--no-session-persistence"))
        XCTAssertTrue(runner.args.contains("-p"))
        XCTAssertTrue(runner.args.contains("--output-format"))
        XCTAssertTrue(runner.args.contains("json"))
    }

    /// Regression for the empty-result bug: an envelope whose `result` is "" must yield an
    /// empty extraction, NOT a thrown parse error. The caller ingests via `try?`, so a throw
    /// here is swallowed and looks identical to "nothing worth extracting" — masking failures.
    func testEmptyResultEnvelopeYieldsEmptyExtraction() throws {
        let envelope = #"{"type":"result","subtype":"success","is_error":false,"result":""}"#
        let extractor = Extractor(runner: StubRunner(output: envelope), claudePath: "/usr/bin/true", env: [:])
        let result = try extractor.extract(transcript: "anything", proj: nil)
        XCTAssertTrue(result.atoms.isEmpty)
        XCTAssertTrue(result.relations.isEmpty)
    }

    func testLooksLikeExtractionDetectsOwnPrompt() {
        XCTAssertTrue(Extractor.looksLikeExtraction(Extractor.instruction))
        XCTAssertTrue(Extractor.looksLikeExtraction("...\nAşağıdaki Claude Code oturum transkriptinden KALICI DEĞERLİ bilgi çıkar."))
        XCTAssertFalse(Extractor.looksLikeExtraction("normal bir oturum, kod yazdık"))
    }

    func testSessionIdParsedFromEnvelope() {
        XCTAssertEqual(Extractor.sessionId(fromEnvelope: #"{"type":"result","result":"x","session_id":"abc-123"}"#), "abc-123")
        XCTAssertNil(Extractor.sessionId(fromEnvelope: #"{"result":"x"}"#))
        XCTAssertNil(Extractor.sessionId(fromEnvelope: #"{"result":"x","session_id":""}"#))
        XCTAssertNil(Extractor.sessionId(fromEnvelope: "not json at all"))
    }

    /// Since the run now persists, we delete its transcript by the session_id the envelope
    /// reports — without disturbing the user's real sessions in the same project folder.
    func testDeletePersistedSessionRemovesOnlyMatchingTranscript() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("claudeos-extract-\(UUID().uuidString)")
        let projDir = root.appendingPathComponent("-Users-someone-proj")
        try fm.createDirectory(at: projDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let sid = "11111111-2222-3333-4444-555555555555"
        let extraction = projDir.appendingPathComponent("\(sid).jsonl")
        let realSession = projDir.appendingPathComponent("99999999-0000-0000-0000-000000000000.jsonl")
        try Data("{}\n".utf8).write(to: extraction)
        try Data("{}\n".utf8).write(to: realSession)

        Extractor.deletePersistedSession(envelope: #"{"result":"x","session_id":"\#(sid)"}"#, projectsRoot: root)

        XCTAssertFalse(fm.fileExists(atPath: extraction.path), "extraction transcript should be deleted")
        XCTAssertTrue(fm.fileExists(atPath: realSession.path), "unrelated session must survive")
    }

    func testDeletePersistedSessionNoOpWithoutSessionId() {
        // No session_id, and a non-existent root: must not throw, crash, or create anything.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claudeos-missing-\(UUID().uuidString)")
        Extractor.deletePersistedSession(envelope: #"{"result":""}"#, projectsRoot: root)
        Extractor.deletePersistedSession(envelope: #"{"result":""}"#, projectsRoot: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
