import Foundation

/// A Claude Code project: one `~/.claude/projects/<encoded>` directory.
public struct Project: Identifiable, Hashable, Sendable {
    public let id: String           // encoded dir name, the stable key
    public var decodedPath: String
    public var displayName: String
    public var sessionCount: Int
    public var lastActivity: Date?
    public var exists: Bool          // is the working directory still on disk?
    public var pinned: Bool = false  // user overlay (from SessionMetaStore)

    public init(
        id: String,
        decodedPath: String,
        displayName: String,
        sessionCount: Int = 0,
        lastActivity: Date? = nil,
        exists: Bool = true
    ) {
        self.id = id
        self.decodedPath = decodedPath
        self.displayName = displayName
        self.sessionCount = sessionCount
        self.lastActivity = lastActivity
        self.exists = exists
    }
}
