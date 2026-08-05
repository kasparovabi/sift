import XCTest
@testable import SiftCore
@testable import SiftIndex

/// End-to-end version of the launch-blocker fix, against the real store rather than a stub:
/// a garbage file where the index belongs used to be `fatalError` before any window existed.
final class CorruptIndexRecoveryTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testGarbageWhereTheIndexBelongsStillYieldsAWorkingIndex() async throws {
        let db = dir.appendingPathComponent("index.sqlite")
        try Data(repeating: 0x41, count: 4096).write(to: db)

        let outcome = try StoreRecovery.open(at: db) { try IndexStore(path: $0) }

        XCTAssertNotNil(outcome.quarantined, "the unopenable file has to be moved out of the way")
        let count = try await outcome.store.sessionCount()
        XCTAssertEqual(count, 0, "and what is left is a usable empty index")
        XCTAssertTrue(FileManager.default.fileExists(atPath: db.path), "a fresh file took its place")
    }

    func testAHealthyIndexIsNeverQuarantined() throws {
        let db = dir.appendingPathComponent("index.sqlite")
        _ = try IndexStore(path: db)

        let outcome = try StoreRecovery.open(at: db) { try IndexStore(path: $0) }

        XCTAssertNil(outcome.quarantined)
        XCTAssertFalse(FileManager.default.fileExists(atPath: db.path + ".corrupt"),
                       "a working index must never be moved aside")
    }
}
