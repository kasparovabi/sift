import XCTest
@testable import SiftRuntime

/// The generated Ghostty config is the whole contract of "Devam et": it is handed to another
/// process and interpreted by `/bin/sh`, so quoting is the part that can silently break.
final class TerminalLauncherTests: XCTestCase {

    func testConfigCarriesWorkingDirectoryAndCommand() {
        let config = TerminalLauncher.ghosttyConfig(command: "exec 'claude' --resume 'abc'",
                                                    cwd: "/tmp/project")
        XCTAssertTrue(config.contains("working-directory = /tmp/project"))
        XCTAssertTrue(config.contains("command = "))
        XCTAssertTrue(config.contains("-lic"), "the session needs the user's login environment")
    }

    func testConfigWithoutCommandOnlySetsTheDirectory() {
        let config = TerminalLauncher.ghosttyConfig(command: nil, cwd: "/tmp/project")
        XCTAssertTrue(config.contains("working-directory = /tmp/project"))
        XCTAssertFalse(config.contains("command = "), "a plain shell must not be given a command")
    }

    /// Ghostty reads one key per line, so a command that spilled onto a second line would be
    /// silently truncated.
    func testConfigCommandStaysOnOneLine() {
        let config = TerminalLauncher.ghosttyConfig(command: "exec 'claude' --resume 'abc'",
                                                    cwd: "/tmp/project")
        let commandLines = config.split(separator: "\n").filter { $0.hasPrefix("command = ") }
        XCTAssertEqual(commandLines.count, 1)
    }

    func testSingleQuotingSurvivesAnApostropheInAPath() {
        XCTAssertEqual(TerminalLauncher.shQuoted("/Users/o'brien/dev"), "'/Users/o'\\''brien/dev'")
    }

    /// The command is embedded in a double-quoted string that `/bin/sh` expands once, so
    /// these four characters would otherwise change what actually runs.
    func testDoubleQuoteEscapingCoversShellExpansion() {
        XCTAssertEqual(TerminalLauncher.doubleQuoteEscaped("a\"b"), "a\\\"b")
        XCTAssertEqual(TerminalLauncher.doubleQuoteEscaped("a$b"), "a\\$b")
        XCTAssertEqual(TerminalLauncher.doubleQuoteEscaped("a`b"), "a\\`b")
        XCTAssertEqual(TerminalLauncher.doubleQuoteEscaped("a\\b"), "a\\\\b")
        XCTAssertEqual(TerminalLauncher.doubleQuoteEscaped("plain"), "plain")
    }

    /// `open` forwards its environment to the app it starts, so a parent-session marker here
    /// reaches `claude` and silently disables transcript saving. Inheriting this process's
    /// environment is the regression; the launcher must hand over a resolved one.
    func testLaunchEnvironmentCarriesNoParentSessionMarkers() {
        let environment = TerminalLauncher.launchEnvironment
        XCTAssertFalse(environment.isEmpty, "an empty environment would break PATH lookup")
        for marker in ["CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID"] {
            XCTAssertNil(environment[marker], "\(marker) would reach the launched session")
        }
        XCTAssertNotNil(environment["PATH"], "the terminal still needs a usable PATH")
    }

    func testAPathWithSpacesRoundTripsThroughBothLayers() {
        let command = "exec \(TerminalLauncher.shQuoted("/Applications/My App/claude")) --resume 'x'"
        let config = TerminalLauncher.ghosttyConfig(command: command, cwd: "/tmp")
        XCTAssertTrue(config.contains("/Applications/My App/claude"))
        XCTAssertEqual(config.split(separator: "\n").filter { $0.hasPrefix("command = ") }.count, 1)
    }
}
