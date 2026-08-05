import XCTest
@testable import SiftCore

/// The rename moves both places macOS keys user data on. Getting this wrong doesn't crash:
/// the app just looks freshly installed and silently abandons an existing index, knowledge
/// store, saved prompts and scheduled jobs.
final class LegacyMigrationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFolder(_ name: String, marker: String) throws {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try marker.write(to: folder.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
    }

    private func marker(_ name: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(name).appendingPathComponent("marker.txt"),
                    encoding: .utf8)
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
    }

    func testOldSupportFolderIsCarriedOver() throws {
        try makeFolder("Old", marker: "index+brain")
        LegacyMigration.moveSupportDirectory(in: root, from: "Old", to: "New")
        XCTAssertEqual(marker("New"), "index+brain")
        XCTAssertFalse(exists("Old"))
    }

    /// If the app has already run under the new name, its data is the live one and must not
    /// be replaced by a stale folder left over from before.
    func testExistingDataIsNeverOverwritten() throws {
        try makeFolder("Old", marker: "stale")
        try makeFolder("New", marker: "current")
        LegacyMigration.moveSupportDirectory(in: root, from: "Old", to: "New")
        XCTAssertEqual(marker("New"), "current")
    }

    func testNothingToMigrateIsHarmless() {
        LegacyMigration.moveSupportDirectory(in: root, from: "Old", to: "New")
        XCTAssertFalse(exists("New"))
    }

    /// A project-wide rename that also rewrote the legacy constants would make old and new
    /// identical; moving a folder onto itself must not destroy it.
    func testSameNameIsANoOp() throws {
        try makeFolder("Same", marker: "data")
        LegacyMigration.moveSupportDirectory(in: root, from: "Same", to: "Same")
        XCTAssertEqual(marker("Same"), "data")
    }

    func testAValueTheUserAlreadySetIsNotReplaced() throws {
        let suite = "migration-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("mine", forKey: "sift.savedPrompts")
        LegacyMigration.copyPreferences(from: "com.example.absent", into: defaults)
        XCTAssertEqual(defaults.string(forKey: "sift.savedPrompts"), "mine")
    }
}
