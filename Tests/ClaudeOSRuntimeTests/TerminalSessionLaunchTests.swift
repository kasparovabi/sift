import XCTest
@testable import ClaudeOSRuntime

final class TerminalSessionLaunchTests: XCTestCase {
    private let flag = "claudeos.wastelandShell"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: flag)
        super.tearDown()
    }

    func testShQuoteWrapsAndEscapes() {
        XCTAssertEqual(TerminalSession.shQuote("plain"), "'plain'")
        XCTAssertEqual(TerminalSession.shQuote("a b"), "'a b'")
        XCTAssertEqual(TerminalSession.shQuote("it's"), "'it'\\''s'")
    }

    /// By default the session boots the wasteland login shell, then execs claude verbatim.
    func testLaunchVectorWrapsInWastelandShellByDefault() {
        UserDefaults.standard.removeObject(forKey: flag)
        let v = TerminalSession.launchVector(executable: "/bin/claude",
                                             args: ["--session-id", "abc"],
                                             environment: ["SHELL=/opt/bin/zsh", "PATH=/usr/bin"])
        XCTAssertEqual(v.executable, "/opt/bin/zsh")
        XCTAssertEqual(v.execName, "zsh")
        XCTAssertEqual(v.args, ["-l", "-i", "-c", "exec '/bin/claude' '--session-id' 'abc'"])
    }

    func testLaunchVectorFallsBackToZshWhenNoShellInEnv() {
        let v = TerminalSession.launchVector(executable: "/bin/claude", args: [], environment: [])
        XCTAssertEqual(v.executable, "/bin/zsh")
        XCTAssertEqual(v.args, ["-l", "-i", "-c", "exec '/bin/claude'"])
    }

    /// With the flag off, claude is launched bare (no shell wrapper).
    func testLaunchVectorBareWhenDisabled() {
        UserDefaults.standard.set(false, forKey: flag)
        let v = TerminalSession.launchVector(executable: "/bin/claude",
                                             args: ["--continue"],
                                             environment: ["SHELL=/bin/zsh"])
        XCTAssertEqual(v.executable, "/bin/claude")
        XCTAssertEqual(v.args, ["--continue"])
        XCTAssertEqual(v.execName, "claude")
    }
}
