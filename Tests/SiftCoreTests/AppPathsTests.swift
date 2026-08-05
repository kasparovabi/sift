import XCTest
@testable import SiftCore

/// Data locations are overridable so a run can be pointed at throwaway data: that is how
/// the README screenshots are made without publishing anyone's real session titles.
final class AppPathsTests: XCTestCase {

    func testAnUnsetVariableLeavesTheRealLocationAlone() {
        XCTAssertNil(AppPaths.resolve(AppPaths.projectsRootKey, environment: [:]))
        XCTAssertTrue(AppPaths.projectsRoot.path.hasSuffix(".claude/projects"))
        XCTAssertTrue(AppPaths.supportDirectory.path.hasSuffix("/Sift"))
    }

    func testAnOverrideRedirectsAndExpandsTilde() {
        let resolved = AppPaths.resolve(AppPaths.supportDirectoryKey,
                                        environment: [AppPaths.supportDirectoryKey: "~/demo/support"])
        XCTAssertEqual(resolved?.path, NSHomeDirectory() + "/demo/support")
    }

    func testBlankAndWhitespaceCountAsUnset() {
        for value in ["", "   "] {
            XCTAssertNil(AppPaths.resolve(AppPaths.projectsRootKey,
                                          environment: [AppPaths.projectsRootKey: value]),
                         "an empty variable must not redirect data to the filesystem root")
        }
    }
}

/// Every store has to go through AppPaths, or a demo run reads the real thing. The loop
/// store computed its own path, so a screenshot session showed real loop titles.
final class SupportPathSingleSourceTests: XCTestCase {

    func testNoStoreComputesItsOwnSupportDirectory() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // SiftCoreTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("Sources")

        let fm = FileManager.default
        var offenders: [String] = []
        let files = fm.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []

        for file in files where file.lastPathComponent != "AppPaths.swift" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if text.contains("applicationSupportDirectory") {
                offenders.append(file.lastPathComponent)
            }
        }
        // LegacyMigration is handed the directory by the caller, so the app's entry point
        // is the one legitimate place that names it.
        XCTAssertEqual(offenders, ["SiftApp.swift"],
                       "these reach past AppPaths, so SIFT_SUPPORT_DIR will not redirect them")
    }
}
