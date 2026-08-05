import XCTest
@testable import SiftCore

/// A store that will not open used to be `fatalError` at launch, which left the app
/// permanently unopenable for anyone who did not know where its files live.
final class StoreRecoveryTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testUnopenableFileIsMovedAsideAndTheStoreOpens() throws {
        let db = dir.appendingPathComponent("index.sqlite")
        try "not a database".write(to: db, atomically: true, encoding: .utf8)
        try "wal".write(to: URL(fileURLWithPath: db.path + "-wal"), atomically: true, encoding: .utf8)

        var attempts = 0
        let outcome = try StoreRecovery.open(at: db) { url -> String in
            attempts += 1
            if attempts == 1 { throw NSError(domain: "corrupt", code: 1) }
            return url.path
        }

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(outcome.store, db.path)
        let moved = try XCTUnwrap(outcome.quarantined)
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "not a database",
                       "the damaged file is kept, not deleted: the brain cannot be rebuilt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path + "-wal"),
                      "sidecars move too, or the fresh database inherits a stale WAL")
        XCTAssertFalse(FileManager.default.fileExists(atPath: db.path))
    }

    func testAHealthyFileIsLeftAlone() throws {
        let db = dir.appendingPathComponent("index.sqlite")
        try "fine".write(to: db, atomically: true, encoding: .utf8)
        let outcome = try StoreRecovery.open(at: db) { $0.path }
        XCTAssertNil(outcome.quarantined)
        XCTAssertTrue(FileManager.default.fileExists(atPath: db.path))
    }

    func testEachFailureGetsItsOwnQuarantineName() throws {
        let db = dir.appendingPathComponent("brain.sqlite")
        for expected in ["brain.sqlite.corrupt", "brain.sqlite.corrupt-2", "brain.sqlite.corrupt-3"] {
            try "x".write(to: db, atomically: true, encoding: .utf8)
            let moved = try XCTUnwrap(StoreRecovery.quarantine(db))
            XCTAssertEqual(moved.lastPathComponent, expected, "an earlier salvage must not be overwritten")
        }
    }

    func testAMissingFileSurfacesTheOriginalError() {
        let absent = dir.appendingPathComponent("absent.sqlite")
        XCTAssertThrowsError(try StoreRecovery.open(at: absent) { _ -> String in
            throw NSError(domain: "denied", code: 1)
        }, "a permissions failure must surface, not be mistaken for corruption")
    }
}
