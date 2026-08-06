import Foundation

/// What the browser asks the runtime to open. Built straight from a `SessionSummary`
/// row; the browser never needs to know how a terminal is spawned.
public struct SessionLaunchRequest: Sendable, Hashable {
    public enum Mode: Sendable, Hashable {
        /// Hand the session back to the agent that wrote it, by the id its transcript
        /// records: `claude --resume <id>` or `codex resume <id>`.
        case resume(sessionId: String, agent: Agent = .claudeCode)
        case fresh                        // new session in `cwd`
    }

    public let mode: Mode
    public let cwd: String
    public let projectId: String
    public let gitBranch: String?
    public let title: String?

    public init(mode: Mode, cwd: String, projectId: String, gitBranch: String? = nil, title: String? = nil) {
        self.mode = mode
        self.cwd = cwd
        self.projectId = projectId
        self.gitBranch = gitBranch
        self.title = title
    }
}

/// A stable handle to a launched session the UI can use to focus it later.
public struct LaunchedSessionHandle: Sendable, Hashable {
    public let runtimeSessionId: String   // the runtime's own id for its tab/pane
    public let claudeSessionId: String?   // known after resume; may differ on fresh

    public init(runtimeSessionId: String, claudeSessionId: String? = nil) {
        self.runtimeSessionId = runtimeSessionId
        self.claudeSessionId = claudeSessionId
    }
}

/// The single contract between the session browser (index + UI) and the PTY
/// runtime. The browser builds a request from a row it already has; the runtime
/// spawns or focuses the live `claude` process. Neither side imports the other,
/// so each can be built and tested in isolation.
@MainActor
public protocol SessionLauncher: AnyObject {
    @discardableResult
    func launch(_ request: SessionLaunchRequest) async throws -> LaunchedSessionHandle
}

/// Read-only live status the menubar and session list bind to.
@MainActor
public protocol SessionRuntimeStatusProviding: AnyObject {
    var liveSessionIds: Set<String> { get }
    var runningCount: Int { get }
    var attentionCount: Int { get }
}
