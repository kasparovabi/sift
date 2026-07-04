import XCTest
@testable import ClaudeOSRuntime

final class LoopTests: XCTestCase {

    // MARK: - Checker verdict parsing (skeptical: only a clear leading PASS passes)

    func testVerdictPassOnLeadingPass() {
        XCTAssertTrue(SessionRuntime.verdictIsPass("PASS\nölçüt karşılandı"))
        XCTAssertTrue(SessionRuntime.verdictIsPass("  pass  \nküçük harf de geçer"))
        XCTAssertTrue(SessionRuntime.verdictIsPass("PASS"))
    }

    func testVerdictFailOnAnythingElse() {
        XCTAssertFalse(SessionRuntime.verdictIsPass("FAIL\neksik bölüm var"))
        XCTAssertFalse(SessionRuntime.verdictIsPass(""))
        // Ambiguous wording that doesn't START with PASS must not slip through.
        XCTAssertFalse(SessionRuntime.verdictIsPass("Bence iş büyük ölçüde PASS sayılabilir"))
        XCTAssertFalse(SessionRuntime.verdictIsPass("belki"))
    }

    // MARK: - LoopStore round-trip (tasks + proof ledger, cascade delete)

    private func makeStore() throws -> LoopStore {
        let path = NSTemporaryDirectory() + "loops-test-\(UUID().uuidString).sqlite"
        return try LoopStore(path: path)
    }

    func testTaskUpsertAndLoad() throws {
        let store = try makeStore()
        let now = Date()
        var task = LoopTask(title: "Test", prompt: "yap", cwd: "/tmp", doneWhen: "swift test",
                            checkKind: .shell, maxPasses: 4, rememberOnPass: false,
                            createdAt: now, updatedAt: now)
        try store.upsert(task)

        var loaded = try store.allTasks()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.title, "Test")
        XCTAssertEqual(loaded.first?.checkKind, .shell)
        XCTAssertEqual(loaded.first?.maxPasses, 4)
        XCTAssertEqual(loaded.first?.rememberOnPass, false)

        // Upsert on the same id updates rather than duplicating.
        task.state = .passed
        task.lastAttempt = 2
        try store.upsert(task)
        loaded = try store.allTasks()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.state, .passed)
        XCTAssertEqual(loaded.first?.lastAttempt, 2)
    }

    func testProofLedgerOrderingAndCascade() throws {
        let store = try makeStore()
        let now = Date()
        let task = LoopTask(title: "L", prompt: "p", cwd: "/tmp", doneWhen: "d",
                            checkKind: .agent, maxPasses: 3, rememberOnPass: true,
                            createdAt: now, updatedAt: now)
        try store.upsert(task)

        try store.insert(proof: ProofRecord(taskId: task.id, attempt: 1, makerOutput: "v1",
                                            passed: false, checkerOutput: "FAIL", date: now))
        try store.insert(proof: ProofRecord(taskId: task.id, attempt: 2, makerOutput: "v2",
                                            passed: true, checkerOutput: "PASS", date: now))

        let proofs = try store.proofs(taskId: task.id)
        XCTAssertEqual(proofs.map(\.attempt), [1, 2])          // ordered by attempt
        XCTAssertEqual(proofs.last?.passed, true)

        // Deleting the task cascades its proofs (FK ON DELETE CASCADE).
        try store.deleteTask(id: task.id)
        XCTAssertTrue(try store.allTasks().isEmpty)
        XCTAssertTrue(try store.proofs(taskId: task.id).isEmpty)
    }

    func testClearProofs() throws {
        let store = try makeStore()
        let now = Date()
        let task = LoopTask(title: "L", prompt: "p", cwd: "/tmp", doneWhen: "d",
                            checkKind: .agent, maxPasses: 2, rememberOnPass: false,
                            createdAt: now, updatedAt: now)
        try store.upsert(task)
        try store.insert(proof: ProofRecord(taskId: task.id, attempt: 1, makerOutput: "x",
                                            passed: false, checkerOutput: "FAIL", date: now))
        try store.clearProofs(taskId: task.id)
        XCTAssertTrue(try store.proofs(taskId: task.id).isEmpty)
        XCTAssertEqual(try store.allTasks().count, 1)          // task itself survives
    }

    // The maker's session id must survive the v2 migration + insert + read, since the
    // "Claude'da devam et" button resumes exactly that session.
    func testProofMakerSessionIdRoundTrip() throws {
        let store = try makeStore()
        let now = Date()
        let task = LoopTask(title: "L", prompt: "p", cwd: "/tmp", doneWhen: "d",
                            checkKind: .agent, maxPasses: 2, rememberOnPass: false,
                            createdAt: now, updatedAt: now)
        try store.upsert(task)
        try store.insert(proof: ProofRecord(taskId: task.id, attempt: 1, makerOutput: "review",
                                            passed: true, checkerOutput: "PASS",
                                            makerSessionId: "abc-123", date: now))
        XCTAssertEqual(try store.proofs(taskId: task.id).first?.makerSessionId, "abc-123")
    }
}
