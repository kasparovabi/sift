import Foundation
import AppKit
import SiftCore

/// Opens a `claude` session in the user's own terminal.
///
/// The app used to embed a terminal emulator and own a PTY per open session, which meant
/// every visible session cost a shell plus a full `claude` process whether or not you were
/// using it. Handing the session to the real terminal costs nothing while idle and gives
/// back the user's actual setup: their prompt, their fonts, their keybindings.
public enum TerminalLauncher {

    /// Ghostty is launched through `open -na`: its own `--help` states that starting the
    /// emulator from the CLI is unsupported on macOS.
    ///
    /// Located by bundle identifier first, so a Homebrew cask install under `~/Applications`
    /// or any other location still counts. The literal paths are the fallback for a machine
    /// whose Launch Services database has not seen the app yet.
    static let ghosttyBundleID = "com.mitchellh.ghostty"

    static func locateGhostty(
        registered: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
        exists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> URL? {
        if let url = registered(ghosttyBundleID), exists(url.path) { return url }
        let candidates = [
            "/Applications/Ghostty.app",
            NSHomeDirectory() + "/Applications/Ghostty.app",
        ]
        return candidates.first(where: exists).map(URL.init(fileURLWithPath:))
    }

    private static var ghostty: URL? { locateGhostty() }

    public static var preferredTerminalName: String {
        ghostty == nil ? "Terminal" : "Ghostty"
    }

    /// Continue an existing session (`claude --resume <id>`) in `cwd`.
    public static func resume(sessionId: String, cwd: String, extraArgs: [String] = []) {
        run(command: claudeCommand(["--resume", sessionId] + extraArgs), cwd: cwd)
    }

    /// Start a fresh session in `cwd`.
    public static func fresh(cwd: String, extraArgs: [String] = []) {
        run(command: claudeCommand(extraArgs), cwd: cwd)
    }

    private static func claudeCommand(_ arguments: [String]) -> String {
        ("exec " + ([claudePath] + arguments).map(shQuoted).joined(separator: " "))
    }

    /// Open a plain shell in `cwd`.
    public static func shell(cwd: String) {
        run(command: nil, cwd: cwd)
    }

    private static var claudePath: String { ClaudeBinary.resolve().path }

    private static func run(command: String?, cwd: String) {
        let directory = FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory()
        guard let ghostty,
              let configURL = writeTempConfig(ghosttyConfig(command: command, cwd: directory)) else {
            runInSystemTerminal(command: command, cwd: directory)
            return
        }
        launch("/usr/bin/open", ["-na", ghostty.path, "--args", "--config-file=\(configURL.path)"])
        // Ghostty reads the file once at startup; a few seconds is ample.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
            try? FileManager.default.removeItem(at: configURL)
        }
    }

    /// The command is handed over in a throwaway config file rather than with Ghostty's `-e`
    /// flag. `-e` makes Ghostty ask "Allow Ghostty to execute …?" on *every* launch, with no
    /// way to remember the answer (ghostty-org/ghostty discussion #10203). `config-file` is
    /// additive and loaded last, so the user's own Ghostty config still applies underneath.
    ///
    /// The command runs through a login+interactive shell so the session gets the same
    /// environment a hand-opened terminal would, then `exec`s into claude so the shell
    /// doesn't linger as an extra process.
    static func ghosttyConfig(command: String?, cwd: String) -> String {
        var lines = ["working-directory = \(cwd)"]
        if let command {
            // Ghostty runs a multi-argument `command` through `/bin/sh -c`, so the inner
            // command sits inside double quotes and needs escaping for that one pass.
            lines.append("command = \(shell) -lic \"\(doubleQuoteEscaped(command))\"")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func writeTempConfig(_ contents: String) -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-ghostty-\(UUID().uuidString).conf")
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// Fallback for a machine without Ghostty, which is most machines.
    ///
    /// Terminal.app has no `-e`, and the obvious alternative — driving it with AppleScript —
    /// makes macOS ask for Automation permission the first time anyone opens a session. Deny
    /// it, or miss the dialog, and the app's main action silently does nothing. Handing
    /// `open` a throwaway executable script asks for no permission at all.
    static func runInSystemTerminal(command: String?, cwd: String) {
        guard let scriptURL = writeLaunchScript(terminalScript(command: command, cwd: cwd)) else { return }
        launch("/usr/bin/open", ["-a", "Terminal", scriptURL.path])
        // Terminal reads the file once, at startup.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) {
            try? FileManager.default.removeItem(at: scriptURL)
        }
    }

    static func terminalScript(command: String?, cwd: String) -> String {
        var lines = ["#!/bin/sh", "cd \(shQuoted(cwd)) || exit 1"]
        // `exec` so the shell does not linger as an extra process; without a command this is
        // just a shell sitting in the directory, so hand over to an interactive one.
        lines.append(command ?? "exec \(shQuoted(shell)) -i")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func writeLaunchScript(_ contents: String) -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-session-\(UUID().uuidString).command")
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }

    private static var shell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// The environment handed to the terminal, deliberately *not* this process's own.
    ///
    /// `open` passes its environment to the app it starts, so inheriting would forward
    /// whatever launched Sift straight through to Ghostty, to the shell, and to
    /// `claude`. Started from inside a Claude Code session that includes
    /// `CLAUDE_CODE_CHILD_SESSION`, which silently turns transcript saving off for every
    /// session opened this way. `EnvironmentResolver` strips those markers.
    static var launchEnvironment: [String: String] { EnvironmentResolver.resolved() }

    private static func launch(_ executable: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = launchEnvironment
        try? process.run()
    }

    /// POSIX single-quote so a path with spaces survives the shell's `-c` parsing.
    static func shQuoted(_ token: String) -> String {
        "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escape what `/bin/sh` would otherwise interpret inside a double-quoted string.
    static func doubleQuoteEscaped(_ token: String) -> String {
        var out = ""
        for character in token {
            if "\\\"$`".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

}
