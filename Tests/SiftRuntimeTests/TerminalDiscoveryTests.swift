import XCTest
@testable import SiftRuntime

/// The Ghostty path used to be hardcoded to `/Applications`, so a Homebrew cask install
/// under `~/Applications` silently fell back to Terminal.app.
final class TerminalDiscoveryTests: XCTestCase {

    func testAnInstallOutsideSlashApplicationsIsFound() {
        let home = NSHomeDirectory() + "/Applications/Ghostty.app"
        let found = TerminalLauncher.locateGhostty(registered: { _ in nil }, exists: { $0 == home })
        XCTAssertEqual(found?.path, home)
    }

    func testTheRegisteredCopyWins() {
        let odd = "/Volumes/Tools/Ghostty.app"
        let found = TerminalLauncher.locateGhostty(
            registered: { _ in URL(fileURLWithPath: odd) },
            exists: { $0 == odd || $0 == "/Applications/Ghostty.app" }
        )
        XCTAssertEqual(found?.path, odd)
    }

    func testAStaleLaunchServicesEntryFallsThroughToDisk() {
        let found = TerminalLauncher.locateGhostty(
            registered: { _ in URL(fileURLWithPath: "/Volumes/Gone/Ghostty.app") },
            exists: { $0 == "/Applications/Ghostty.app" }
        )
        XCTAssertEqual(found?.path, "/Applications/Ghostty.app",
                       "an uninstalled app can linger in Launch Services")
    }

    func testNoGhosttyMeansTerminal() {
        XCTAssertNil(TerminalLauncher.locateGhostty(registered: { _ in nil }, exists: { _ in false }))
    }
}
