import Foundation
import GRDB
import SiftCore

/// GRDB storage record for a project. Kept separate from the Core `Project` model
/// so the index layer owns its persistence concerns and the UI stays DB-agnostic.
struct ProjectRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "project"
    var id: String
    var decodedPath: String
    var displayName: String
    var sessionCount: Int
    var lastActivity: Date?
    var cwdExists: Bool

    var project: Project {
        Project(
            id: id,
            decodedPath: decodedPath,
            displayName: displayName,
            sessionCount: sessionCount,
            lastActivity: lastActivity,
            exists: cwdExists
        )
    }
}

/// GRDB storage record for a session, mirroring the `session` table.
struct SessionRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "session"
    var sessionId: String
    var projectId: String
    var filePath: String
    var cwd: String?
    var gitBranch: String?
    var title: String?
    var firstMessage: String?
    var fullText: String? = nil
    var slug: String?
    var entrypoint: String?
    var version: String?
    var startedAt: Date?
    var lastActivity: Date?
    var messageCount: Int
    var toolCallCount: Int
    var fileSize: Int64
    var fileMtime: Date
    var indexedAt: Date
    var headOnly: Bool

    var summary: SessionSummary {
        SessionSummary(
            sessionId: sessionId,
            projectId: projectId,
            filePath: filePath,
            cwd: cwd,
            gitBranch: gitBranch,
            title: title,
            firstMessage: firstMessage,
            slug: slug,
            entrypoint: entrypoint,
            version: version,
            startedAt: startedAt,
            lastActivity: lastActivity,
            messageCount: messageCount,
            toolCallCount: toolCallCount
        )
    }
}
