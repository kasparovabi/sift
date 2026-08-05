import XCTest
@testable import SiftCore

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

    // MARK: - Parent-session markers
    //
    // Launching the app from inside a Claude Code session leaks that session's markers in.
    // `CLAUDE_CODE_CHILD_SESSION` alone turns transcript saving off for every session started
    // here, silently — the loss only surfaces later, when a session can't be resumed or indexed.

    func testNestingSignalsCoverTheMarkersThatDisableTranscripts() {
        for marker in ["CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID"] {
            XCTAssertTrue(EnvironmentResolver.nestingSignals.contains(marker), marker)
        }
    }

    func testAuthVariablesAreNotStripped() {
        for kept in ["CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH", "CLAUDE_CODE_OAUTH_TOKEN", "PATH", "HOME"] {
            XCTAssertFalse(EnvironmentResolver.nestingSignals.contains(kept),
                           "\(kept) must survive — a session launched from a Claude context needs it")
        }
    }

    func testResolvedEnvironmentCarriesNoParentSessionMarkers() {
        let resolved = EnvironmentResolver.resolved()
        for marker in EnvironmentResolver.nestingSignals {
            XCTAssertNil(resolved[marker], "\(marker) leaked into a launched session")
        }
    }

    func testDictionaryRoundTripsAndKeepsValuesContainingEquals() {
        let parsed = EnvironmentResolver.dictionary(from: [
            "PATH=/usr/bin:/bin",
            "MSG=a=b=c",
            "EMPTY=",
            "malformed-no-equals",
        ])
        XCTAssertEqual(parsed["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(parsed["MSG"], "a=b=c", "only the first = separates key from value")
        XCTAssertEqual(parsed["EMPTY"], "")
        XCTAssertNil(parsed["malformed-no-equals"])
    }
}
