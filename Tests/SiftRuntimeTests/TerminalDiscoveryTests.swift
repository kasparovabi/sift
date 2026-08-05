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

/// Most machines do not have Ghostty, so the fallback is the path most people meet.
/// It must not need a permission grant to work.
@MainActor
final class TerminalFallbackTests: XCTestCase {

    func testTheFallbackScriptRunsTheCommandInTheRightDirectory() {
        let script = TerminalLauncher.terminalScript(
            command: "exec '/usr/bin/claude' --resume 'abc'", cwd: "/Users/alex/code/app")
        let lines = script.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "#!/bin/sh")
        XCTAssertEqual(lines[1], "cd '/Users/alex/code/app' || exit 1",
                       "a directory that has gone missing must not silently run in $HOME")
        XCTAssertEqual(lines.last, "exec '/usr/bin/claude' --resume 'abc'")
    }

    func testADirectoryWithQuotesCannotBreakOutOfTheScript() {
        let script = TerminalLauncher.terminalScript(command: nil, cwd: "/tmp/it's here")
        XCTAssertTrue(script.contains("cd '/tmp/it'\\''s here'"))
        XCTAssertFalse(script.contains("; rm"), "no injection surface")
    }

    func testWithoutACommandItOpensAnInteractiveShell() {
        let script = TerminalLauncher.terminalScript(command: nil, cwd: "/tmp")
        XCTAssertTrue(script.hasSuffix("-i\n"), "a plain shell, not a script that exits at once")
    }

    func testTheScriptIsExecutableAndActuallyRuns() throws {
        // The mechanism, end to end: Terminal.app runs this file because `open` hands it
        // over, and that needs no Automation permission.
        let marker = "SIFT-FALLBACK-\(UUID().uuidString)"
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-fb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let script = TerminalLauncher.terminalScript(command: "echo \(marker)", cwd: dir.path)
        let url = dir.appendingPathComponent("run.command")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        let process = Process()
        process.executableURL = url
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(marker))
    }
}
