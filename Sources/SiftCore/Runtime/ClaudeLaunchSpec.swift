import Foundation

/// How to invoke `claude` for a session. The runtime turns a UI-level
/// `SessionLaunchRequest` into one of these; for a fresh session it generates the
/// session id up front (`--session-id`) so reattach-by-resume stays deterministic.
public struct ClaudeLaunchSpec: Codable, Hashable, Sendable {
    public enum Mode: Codable, Hashable, Sendable {
        case fresh(sessionId: String)
        case resume(sessionId: String)
        case continueLast
    }

    public var mode: Mode
    public var workingDirectory: URL
    public var extraArgs: [String]

    public init(mode: Mode, workingDirectory: URL, extraArgs: [String] = []) {
        self.mode = mode
        self.workingDirectory = workingDirectory
        self.extraArgs = extraArgs
    }

    /// Build argv for spawning claude in a PTY (interactive, so no `-p`).
    public func argv(resolvedBinary: URL) -> (executable: String, args: [String]) {
        var args: [String] = []
        switch mode {
        case .fresh(let id):
            args += ["--session-id", id]
        case .resume(let id):
            args += ["--resume", id]
        case .continueLast:
            args += ["--continue"]
        }
        args += extraArgs
        return (resolvedBinary.path, args)
    }
}
