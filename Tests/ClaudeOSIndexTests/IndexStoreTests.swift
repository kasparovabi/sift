import XCTest
import ClaudeOSCore
@testable import ClaudeOSIndex

final class IndexStoreTests: XCTestCase {

    private func makeStore() throws -> (IndexStore, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claudeos-test-\(UUID().uuidString).sqlite")
        return (try IndexStore(path: url), url)
    }

    private func session(_ id: String, project: String, path: String, title: String, cwd: String? = nil) -> SessionRecord {
        SessionRecord(
            sessionId: id, projectId: project, filePath: path,
            cwd: cwd, gitBranch: "main", title: title, firstMessage: title,
            slug: nil, entrypoint: "cli", version: "2.1", startedAt: nil, lastActivity: Date(),
            messageCount: 1, toolCallCount: 0, fileSize: 100, fileMtime: Date(),
            indexedAt: Date(), headOnly: false
        )
    }

    func testApplyAndFullTextSearch() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let s = session("s1", project: "-Users-x-proj", path: "/tmp/s1.jsonl",
                        title: "Refactor the JSONL parser", cwd: "/Users/x/proj")
        try await store.apply(ScanResult(upserts: [s], presentPaths: ["/tmp/s1.jsonl"]))

        let all = try await store.search("", filters: SearchFilters())
        XCTAssertEqual(all.count, 1)

        let refactor = try await store.search("refactor", filters: SearchFilters())
        XCTAssertEqual(refactor.first?.sessionId, "s1")

        let prefix = try await store.search("pars", filters: SearchFilters())
        XCTAssertEqual(prefix.first?.sessionId, "s1", "prefix match")

        let miss = try await store.search("kubernetes", filters: SearchFilters())
        XCTAssertTrue(miss.isEmpty)

        let projects = try await store.projects()
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.displayName, "proj")
        XCTAssertEqual(projects.first?.sessionCount, 1)
        XCTAssertEqual(projects.first?.exists, false, "/Users/x/proj does not exist on disk")
    }

    func testProjectScopedSearch() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let a = session("a", project: "p1", path: "/a.jsonl", title: "alpha shared")
        let b = session("b", project: "p2", path: "/b.jsonl", title: "beta shared")
        try await store.apply(ScanResult(upserts: [a, b], presentPaths: ["/a.jsonl", "/b.jsonl"]))

        let scoped = try await store.search("shared", filters: SearchFilters(projectId: "p1"))
        XCTAssertEqual(scoped.map(\.sessionId), ["a"])

        let projects = try await store.projects()
        XCTAssertEqual(projects.count, 2)
    }

    func testIncrementalUpsertAndDelete() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let s1 = session("s1", project: "p1", path: "/s1.jsonl", title: "first")
        let s2 = session("s2", project: "p1", path: "/s2.jsonl", title: "second")
        try await store.apply(ScanResult(upserts: [s1, s2], presentPaths: ["/s1.jsonl", "/s2.jsonl"]))

        let initialCount = try await store.sessionCount()
        XCTAssertEqual(initialCount, 2)

        // s2's file disappears; s1's title changes. Only s1 is present now.
        var s1b = s1
        s1b.title = "renamed first"
        try await store.apply(ScanResult(upserts: [s1b], presentPaths: ["/s1.jsonl"]))

        let afterCount = try await store.sessionCount()
        XCTAssertEqual(afterCount, 1, "deleted file should drop its row")

        let renamed = try await store.search("renamed", filters: SearchFilters())
        XCTAssertEqual(renamed.first?.sessionId, "s1", "FTS index should reflect the updated title")

        let deleted = try await store.search("second", filters: SearchFilters())
        XCTAssertTrue(deleted.isEmpty, "deleted session should leave the FTS index")

        let projects = try await store.projects()
        XCTAssertEqual(projects.first?.sessionCount, 1)
    }

    func testStructuredFilters() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        var cli = session("c", project: "p1", path: "/c.jsonl", title: "shared work")
        cli.entrypoint = "cli"; cli.gitBranch = "main"
        var desktop = session("d", project: "p1", path: "/d.jsonl", title: "shared work")
        desktop.entrypoint = "claude-desktop"; desktop.gitBranch = "feature"
        try await store.apply(ScanResult(upserts: [cli, desktop], presentPaths: ["/c.jsonl", "/d.jsonl"]))

        let byEntrypoint = try await store.search("shared", filters: SearchFilters(entrypoint: "cli"))
        XCTAssertEqual(byEntrypoint.map(\.sessionId), ["c"])

        let byBranch = try await store.search("", filters: SearchFilters(gitBranch: "feature"))
        XCTAssertEqual(byBranch.map(\.sessionId), ["d"])

        let branches = try await store.distinctBranches()
        XCTAssertEqual(Set(branches), ["main", "feature"])
    }

    func testFullTextBodySearch() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        var s = session("s1", project: "p1", path: "/s1.jsonl", title: "Generic title")
        s.firstMessage = "hello world"
        s.fullText = "the user asked about kubernetes ingress controllers"
        try await store.apply(ScanResult(upserts: [s], presentPaths: ["/s1.jsonl"]))

        // A word only present in the message body must be findable.
        let hit = try await store.search("kubernetes", filters: SearchFilters())
        XCTAssertEqual(hit.first?.sessionId, "s1", "search should match the message body via fullText")

        let snippet = hit.first?.snippet ?? ""
        XCTAssertTrue(snippet.contains("\u{1}"), "snippet should wrap matches in markers")
        XCTAssertTrue(snippet.lowercased().contains("kubernetes"), "snippet should include the matched term")

        let backfill = try await store.needsContentBackfill()
        XCTAssertFalse(backfill, "this session has fullText, so no backfill is needed")
    }

    func testTranscriptParsing() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("t-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let lines = [
            #"{"type":"user","uuid":"u1","timestamp":"2026-06-05T10:00:00.000Z","message":{"role":"user","content":"hello there"}}"#,
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-06-05T10:00:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"hi, how can I help"}]}}"#,
            #"{"type":"assistant","uuid":"a2","timestamp":"2026-06-05T10:00:02.000Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash"}]}}"#
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: tmp, atomically: true, encoding: .utf8)

        let turns = TranscriptLoader.parse(filePath: tmp.path, maxTurns: 100)
        XCTAssertEqual(turns.count, 3)
        XCTAssertEqual(turns[0].role, .user)
        XCTAssertEqual(turns[0].text, "hello there")
        XCTAssertEqual(turns[1].role, .assistant)
        XCTAssertEqual(turns[2].role, .tool)
    }

    @MainActor
    func testSessionMetaStore() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("meta-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SessionMetaStore(url: url)
        store.setName("Önemli oturum", for: "s1")
        store.setTags(["iş", "acil", "iş"], for: "s1")  // duplicate dropped

        XCTAssertEqual(store.meta(for: "s1").name, "Önemli oturum")
        XCTAssertEqual(store.meta(for: "s1").tags, ["iş", "acil"])

        // Clearing the name keeps the tags.
        store.setName("   ", for: "s1")
        XCTAssertNil(store.meta(for: "s1").name)
        XCTAssertEqual(store.meta(for: "s1").tags, ["iş", "acil"])

        // Pinning sessions and projects, archiving another session.
        store.togglePin(for: "s1")
        store.toggleProjectPin("p1")
        store.toggleArchive(for: "s2")
        XCTAssertTrue(store.isPinned("s1"))
        XCTAssertTrue(store.isProjectPinned("p1"))
        XCTAssertTrue(store.isArchived("s2"))

        // Persists across reloads (separate from the index).
        let reloaded = SessionMetaStore(url: url)
        XCTAssertEqual(reloaded.meta(for: "s1").tags, ["iş", "acil"])
        XCTAssertEqual(reloaded.allTags, ["acil", "iş"])
        XCTAssertTrue(reloaded.isPinned("s1"))
        XCTAssertTrue(reloaded.isProjectPinned("p1"))
        XCTAssertTrue(reloaded.isArchived("s2"))
    }

    func testFingerprintsRoundTrip() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let s = session("s1", project: "p1", path: "/s1.jsonl", title: "x")
        try await store.apply(ScanResult(upserts: [s], presentPaths: ["/s1.jsonl"]))

        let prints = try await store.fingerprints()
        XCTAssertEqual(prints["/s1.jsonl"]?.size, 100)
    }
}
