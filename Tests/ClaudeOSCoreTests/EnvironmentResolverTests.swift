import XCTest
@testable import ClaudeOSCore

/// These encode the contract of the PATH fix, the single antidote to the
/// stripped-environment bug that cost nine silent days.
final class EnvironmentResolverTests: XCTestCase {

    func testGuaranteesLocalBinAndHomebrew() {
        let parts = EnvironmentResolver
            .repairedPATH(loginPATH: "/usr/bin:/bin", home: "/Users/x")
            .split(separator: ":").map(String.init)
        XCTAssertTrue(parts.contains("/Users/x/.local/bin"), "~/.local/bin must always be present")
        XCTAssertTrue(parts.contains("/opt/homebrew/bin"), "Homebrew must always be present")
    }

    func testGuaranteedDirsArePrepended() {
        let path = EnvironmentResolver.repairedPATH(loginPATH: "/usr/bin:/bin", home: "/Users/x")
        XCTAssertTrue(path.hasPrefix("/Users/x/.local/bin:"), "our chosen claude should win over others")
    }

    func testPreservesExistingEntries() {
        let parts = EnvironmentResolver
            .repairedPATH(loginPATH: "/custom/tool:/usr/bin", home: "/Users/x")
            .split(separator: ":").map(String.init)
        XCTAssertTrue(parts.contains("/custom/tool"), "existing PATH entries must survive")
    }

    func testNoDuplicates() {
        let parts = EnvironmentResolver
            .repairedPATH(loginPATH: "/Users/x/.local/bin:/usr/bin:/usr/bin:/opt/homebrew/bin", home: "/Users/x")
            .split(separator: ":").map(String.init)
        XCTAssertEqual(parts.count, Set(parts).count, "no duplicate entries")
    }

    func testEmptyLoginPathStillUsable() {
        let parts = EnvironmentResolver
            .repairedPATH(loginPATH: "", home: "/Users/x")
            .split(separator: ":").map(String.init)
        XCTAssertTrue(parts.contains("/Users/x/.local/bin"))
        XCTAssertTrue(parts.contains("/opt/homebrew/bin"))
        XCTAssertFalse(parts.contains(""), "no empty segments")
    }

    func testResolvedPathLooksSane() {
        // Integration-ish: on a real machine the resolved PATH should let us find claude.
        let path = EnvironmentResolver.resolved()["PATH"] ?? ""
        XCTAssertTrue(path.contains(".local/bin") || path.contains("homebrew"))
    }
}
