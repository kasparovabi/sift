import Foundation

/// Builds the environment used to launch `claude`, guaranteeing a correct PATH no
/// matter how the app itself was launched.
///
/// GUI apps (Finder) and launchd agents inherit a *stripped* environment whose
/// PATH usually omits `~/.local/bin` and Homebrew. That is exactly the trap that
/// made a scheduled job fail silently for nine days. `resolved()` captures the
/// user's real login-shell environment once, then runs it through
/// `repairedPATH(...)` so the dirs `claude` and brew live in are always present.
public enum EnvironmentResolver {

    /// Markers Claude Code sets on the processes it spawns, identifying them as part of a
    /// parent session. Launching the app from inside a Claude Code session (a terminal, a
    /// tool call) leaks them in, and every session started here then inherits the parent's
    /// identity: `CLAUDE_CODE_CHILD_SESSION` alone silently turns transcript saving off, so
    /// the sessions can't be resumed, indexed, or fed to the brain. Strip them at the source
    /// — a session started here is always its own top-level session.
    ///
    /// Deliberately a deny-list: auth (`CLAUDE_CODE_SDK_HAS_*`, tokens) must survive, or a
    /// session launched from a Claude Code context can't authenticate.
    static let nestingSignals: Set<String> = [
        "CLAUDECODE",
        "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_BRIDGE_SESSION_ID",
        "CLAUDE_CODE_HOST_SESSION_ID",
        "CLAUDE_CODE_EXECPATH",
        "CLAUDE_CODE_SSE_PORT",
        "CLAUDE_PID",
        "CLAUDE_EFFORT",
    ]

    nonisolated(unsafe) private static var cache: [String: String]?
    private static let lock = NSLock()

    /// Resolved environment, cached after first use (the login-shell probe is not cheap).
    public static func resolved() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let cache { return cache }
        let value = compute()
        cache = value
        return value
    }

    /// SwiftTerm expects the environment as an array of "KEY=VALUE" strings.
    public static func environmentStrings() -> [String] {
        resolved().map { "\($0.key)=\($0.value)" }
    }

    /// Parse those strings back into the dictionary `Process.environment` wants.
    public static func dictionary(from strings: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for entry in strings {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            out[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return out
    }

    private static func compute() -> [String: String] {
        var env = loginShellEnvironment()
        for key in nestingSignals { env.removeValue(forKey: key) }
        let home = NSHomeDirectory()
        let base = env["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        env["PATH"] = repairedPATH(loginPATH: base, home: home)
        if (env["LANG"] ?? "").isEmpty { env["LANG"] = "en_US.UTF-8" }
        env["TERM"] = "xterm-256color"
        return env
    }

    /// Run the user's login + interactive shell and capture its environment, so we
    /// inherit nvm / pyenv / `brew shellenv` / etc. exactly like a real terminal.
    public static func loginShellEnvironment() -> [String: String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", "env"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return ProcessInfo.processInfo.environment
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return ProcessInfo.processInfo.environment
        }
        var dict: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            dict[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return dict.isEmpty ? ProcessInfo.processInfo.environment : dict
    }

    /// Pure, testable PATH repair. Guarantees the dirs `claude` and Homebrew live
    /// in are present (prepended so our chosen binaries win), preserves the user's
    /// existing entries, keeps the unix basics, and de-dups while preserving order.
    public static func repairedPATH(loginPATH: String, home: String) -> String {
        let guaranteed = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
        ]
        let basics = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existing = loginPATH.split(separator: ":").map(String.init).filter { !$0.isEmpty }

        var seen = Set<String>()
        var result: [String] = []
        for dir in guaranteed + existing + basics where seen.insert(dir).inserted {
            result.append(dir)
        }
        return result.joined(separator: ":")
    }
}
