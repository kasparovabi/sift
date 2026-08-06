import Foundation

/// Which coding agent wrote a session. Sift started out reading only Claude Code, and the
/// rest of the tools write their history to disk in the same spirit: a directory of
/// transcripts nobody can search.
public enum Agent: String, Codable, Sendable, CaseIterable, Identifiable {
    case claudeCode = "claude"
    case codex = "codex"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// The executable, and the arguments that reopen one session by id. Both agents take
    /// the id the transcript records, so a result can be handed back to the tool that
    /// wrote it. A session written by Codex Desktop still resumes in the Codex CLI.
    public var command: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        }
    }

    public func resumeArguments(sessionId: String) -> [String] {
        switch self {
        case .claudeCode: ["--resume", sessionId]
        case .codex: ["resume", sessionId]
        }
    }

    public var defaultRoot: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claudeCode: return home.appendingPathComponent(".claude/projects")
        case .codex: return home.appendingPathComponent(".codex/sessions")
        }
    }
}
