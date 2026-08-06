import XCTest
@testable import SiftIndex
import SiftCore

final class CodexTranscriptTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, _ lines: [[String: Any]]) throws -> URL {
        let day = root.appendingPathComponent("2026/07/14")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let url = day.appendingPathComponent(name)
        let text = try lines
            .map { String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
            .joined(separator: "\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func meta(_ extra: [String: Any] = [:]) -> [String: Any] {
        var payload: [String: Any] = [
            "id": "019f6138-0cae-7fd3-9a3d-159643b3b09f",
            "session_id": "019f5d14-82f8-74d1-b5ea-33d96bc0a348",
            "cwd": "/Users/alex/code/orbit-api",
            "cli_version": "0.144.2",
            "originator": "Codex Desktop",
            "git": ["branch": "main"],
        ]
        payload.merge(extra) { _, new in new }
        return ["timestamp": "2026-07-14T15:21:31.121Z", "type": "session_meta", "payload": payload]
    }

    private func message(_ role: String, _ text: String, at: String = "2026-07-14T15:22:00.000Z")
        -> [String: Any]
    {
        ["timestamp": at, "type": "response_item",
         "payload": ["type": "message", "role": role,
                     "content": [["type": role == "user" ? "input_text" : "output_text",
                                  "text": text]]]]
    }

    func testATranscriptYieldsOnlyWhatTheTwoSidesSaid() throws {
        let file = try write("rollout-a.jsonl", [
            meta(),
            message("developer", "<permissions instructions>\nread-only"),
            message("user", "offset pagination is slow past page 200"),
            message("assistant", "Switched to keyset pagination."),
            ["timestamp": "2026-07-14T15:23:00.000Z", "type": "response_item",
             "payload": ["type": "function_call", "name": "shell"]],
        ])
        let parsed = try XCTUnwrap(CodexTranscript.parse(fileURL: file, fileSize: 0))

        XCTAssertEqual(parsed.sessionId, "019f6138-0cae-7fd3-9a3d-159643b3b09f")
        XCTAssertEqual(parsed.cwd, "/Users/alex/code/orbit-api")
        XCTAssertEqual(parsed.gitBranch, "main")
        XCTAssertEqual(parsed.messageCount, 2, "the developer turn is the harness, not a side")
        XCTAssertEqual(parsed.toolCallCount, 1)
        XCTAssertTrue(parsed.fullText.contains("keyset pagination"))
        XCTAssertFalse(parsed.fullText.contains("permissions instructions"))
        XCTAssertEqual(parsed.firstMessage, "offset pagination is slow past page 200")
    }

    func testTheHarnessesOwnPreambleIsNotTheUsersFirstMessage() throws {
        // Without this every session in a repository gets the same title.
        let file = try write("rollout-b.jsonl", [
            meta(),
            message("user", "# AGENTS.md instructions\n<INSTRUCTIONS>do the thing</INSTRUCTIONS>"),
            message("user", "<recommended_plugins>\nhere is a list"),
            message("user", "actually fix the rate limiter"),
        ])
        let parsed = try XCTUnwrap(CodexTranscript.parse(fileURL: file, fileSize: 0))
        XCTAssertEqual(parsed.messageCount, 1)
        XCTAssertEqual(parsed.firstMessage, "actually fix the rate limiter")
    }

    func testAThreadCodexSpawnedForItselfIsNotASession() throws {
        // On the library this was built against, 64 of 76 rollouts were these.
        let file = try write("rollout-c.jsonl", [
            meta(["thread_source": "subagent", "parent_thread_id": "019f6138-0c35"]),
            message("user", "judge this action"),
            message("assistant", "{\"outcome\":\"allow\"}"),
        ])
        XCTAssertNil(CodexTranscript.parse(fileURL: file, fileSize: 0))
    }

    func testScanningKeepsRealSessionsAndDropsTheRest() throws {
        _ = try write("rollout-real.jsonl", [
            meta(), message("user", "why is the build slow"), message("assistant", "Caching."),
        ])
        _ = try write("rollout-sub.jsonl", [
            meta(["thread_source": "subagent", "parent_thread_id": "x"]),
            message("user", "judge"),
        ])
        _ = try write("rollout-empty.jsonl", [meta()])

        let result = CodexScanner.scan(root: root)
        XCTAssertEqual(result.upserts.count, 1)
        XCTAssertEqual(result.presentPaths.count, 1,
                       "a dropped file must not look like a session that vanished")
        let record = try XCTUnwrap(result.upserts.first)
        XCTAssertEqual(record.agent, .codex)
        XCTAssertEqual(record.cwd, "/Users/alex/code/orbit-api")
        XCTAssertEqual(record.projectId, "/Users/alex/code/orbit-api")
    }

    func testAnUnchangedFileIsNotReadTwice() throws {
        _ = try write("rollout-d.jsonl", [
            meta(), message("user", "hello"), message("assistant", "hi"),
        ])
        let first = CodexScanner.scan(root: root)
        XCTAssertEqual(first.upserts.count, 1)

        // Built the way the store builds it, from what the previous pass recorded.
        let known = Dictionary(uniqueKeysWithValues: first.upserts.map {
            ($0.filePath, FileFingerprint(size: $0.fileSize, mtime: $0.fileMtime))
        })
        XCTAssertTrue(CodexScanner.scan(root: root, known: known).upserts.isEmpty)
    }

    func testAMissingCodexDirectoryIsNotAnError() {
        let absent = root.appendingPathComponent("nowhere")
        let result = CodexScanner.scan(root: absent)
        XCTAssertTrue(result.upserts.isEmpty)
        XCTAssertTrue(result.presentPaths.isEmpty)
    }

    func testBothAgentsResumeByTheIdTheirTranscriptRecords() {
        XCTAssertEqual(Agent.claudeCode.command, "claude")
        XCTAssertEqual(Agent.claudeCode.resumeArguments(sessionId: "abc"), ["--resume", "abc"])
        XCTAssertEqual(Agent.codex.command, "codex")
        XCTAssertEqual(Agent.codex.resumeArguments(sessionId: "abc"), ["resume", "abc"])
    }

    func testOnePassOverTwoAgentsLooksLikeOnePassToTheStore() {
        // Applying them separately would make each scanner's view the whole truth, and the
        // second apply would delete what the first had just written.
        let a = ScanResult(upserts: [], presentPaths: ["/a.jsonl"])
        let b = ScanResult(upserts: [], presentPaths: ["/b.jsonl"])
        XCTAssertEqual(a.merged(with: b).presentPaths, ["/a.jsonl", "/b.jsonl"])
    }
}

@MainActor
final class TwoAgentIndexTests: XCTestCase {
    /// The wiring test: one pass has to land both agents in one index, and neither scanner
    /// may delete the other's rows on the way through.
    func testOnePassIndexesBothAgents() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-two-\(UUID().uuidString)")
        let claudeRoot = base.appendingPathComponent("claude")
        let codexRoot = base.appendingPathComponent("codex/2026/07/14")
        try FileManager.default.createDirectory(
            at: claudeRoot.appendingPathComponent("-Users-alex-orbit"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let claudeLines = [
            #"{"type":"user","uuid":"u1","sessionId":"c1","cwd":"/Users/alex/orbit","timestamp":"2026-08-01T10:00:00.000Z","message":{"role":"user","content":"offset pagination is slow"}}"#,
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-08-01T10:00:20.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Use keyset."}]}}"#,
        ].joined(separator: "\n")
        try claudeLines.write(
            to: claudeRoot.appendingPathComponent("-Users-alex-orbit/c1.jsonl"),
            atomically: true, encoding: .utf8)

        let codexLines = [
            #"{"timestamp":"2026-07-14T15:21:31.121Z","type":"session_meta","payload":{"id":"x1","cwd":"/Users/alex/orbit","git":{"branch":"main"}}}"#,
            #"{"timestamp":"2026-07-14T15:22:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"why is the build slow"}]}}"#,
            #"{"timestamp":"2026-07-14T15:22:30.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Nothing is cached."}]}}"#,
        ].joined(separator: "\n")
        try codexLines.write(
            to: codexRoot.appendingPathComponent("rollout-x1.jsonl"), atomically: true, encoding: .utf8)

        let store = try IndexStore(path: base.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(store: store, projectsRoot: claudeRoot,
                                           codexRoot: base.appendingPathComponent("codex"))
        await coordinator.rescan()

        let all = try await store.search("", filters: SearchFilters())
        XCTAssertEqual(all.count, 2, "one pass, both agents")
        XCTAssertEqual(Set(all.map { $0.agent }), Set<Agent>([.claudeCode, .codex]))

        let build = try await store.search("build", filters: SearchFilters())
        XCTAssertEqual(build.first?.agent, .codex, "the Codex session is searchable by its text")

        // A second pass changes nothing and must not drop either side.
        await coordinator.rescan()
        let again = try await store.search("", filters: SearchFilters())
        XCTAssertEqual(again.count, 2)
    }
}
