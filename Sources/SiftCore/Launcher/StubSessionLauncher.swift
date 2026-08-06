import Foundation

/// A degraded `SessionLauncher` used until the real PTY runtime lands: it opens
/// Terminal.app and runs `claude` there, so "Resume" works end-to-end on day one.
/// Replaced by the embedded-terminal runtime in a later milestone, with no change
/// to the browser that calls it.
@MainActor
public final class StubSessionLauncher: SessionLauncher {
    private let binary: URL

    public init(binary: URL? = nil) {
        self.binary = binary ?? ClaudeBinary.resolve()
    }

    @discardableResult
    public func launch(_ request: SessionLaunchRequest) async throws -> LaunchedSessionHandle {
        let command: String
        switch request.mode {
        case .resume(let id, let agent):
            let program = agent == .claudeCode ? Self.shellQuote(binary.path) : agent.command
            let arguments = agent.resumeArguments(sessionId: id).joined(separator: " ")
            command = "cd \(Self.shellQuote(request.cwd)) && \(program) \(arguments)"
        case .fresh:
            command = "cd \(Self.shellQuote(request.cwd)) && \(Self.shellQuote(binary.path))"
        }
        try Self.runInTerminal(command)

        let claudeId: String?
        if case .resume(let id, _) = request.mode { claudeId = id } else { claudeId = nil }
        return LaunchedSessionHandle(runtimeSessionId: UUID().uuidString, claudeSessionId: claudeId)
    }

    private static func runInTerminal(_ command: String) throws {
        let script = """
        tell application "Terminal"
            activate
            do script "\(appleScriptEscape(command))"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try process.run()
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
