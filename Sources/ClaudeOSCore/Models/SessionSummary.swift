import Foundation

/// The list-row view of a session, derived from its JSONL file. This is what the
/// browser shows and what it hands to the runtime to resume.
public struct SessionSummary: Identifiable, Hashable, Sendable {
    public var id: String { sessionId }

    public let sessionId: String
    public let projectId: String
    public let filePath: String
    public var cwd: String?
    public var gitBranch: String?
    public var title: String?
    public var firstMessage: String?
    /// Search-only: matched text excerpt with FTS markers (\u{1}…\u{2}). Nil for non-search listings.
    public var snippet: String? = nil
    /// User overlay from SessionMetaStore (not stored in the index).
    public var customName: String? = nil
    public var tags: [String] = []
    public var pinned: Bool = false
    public var archived: Bool = false
    public var slug: String?
    public var entrypoint: String?
    public var version: String?
    public var startedAt: Date?
    public var lastActivity: Date?
    public var messageCount: Int
    public var toolCallCount: Int

    public init(
        sessionId: String,
        projectId: String,
        filePath: String,
        cwd: String? = nil,
        gitBranch: String? = nil,
        title: String? = nil,
        firstMessage: String? = nil,
        slug: String? = nil,
        entrypoint: String? = nil,
        version: String? = nil,
        startedAt: Date? = nil,
        lastActivity: Date? = nil,
        messageCount: Int = 0,
        toolCallCount: Int = 0
    ) {
        self.sessionId = sessionId
        self.projectId = projectId
        self.filePath = filePath
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.title = title
        self.firstMessage = firstMessage
        self.slug = slug
        self.entrypoint = entrypoint
        self.version = version
        self.startedAt = startedAt
        self.lastActivity = lastActivity
        self.messageCount = messageCount
        self.toolCallCount = toolCallCount
    }

    /// What the UI shows: the user's custom name, else the auto title, else a placeholder.
    public var displayTitle: String {
        customName ?? title ?? "Başlıksız oturum"
    }
}

