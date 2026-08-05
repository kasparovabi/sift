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
