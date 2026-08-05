import Foundation

/// One rendered turn in a session transcript preview (read-only).
///
/// Only the two sides of the conversation exist here. A session's transcript also holds
/// the machinery between them — tool calls, their results, injected reminders — and none
/// of that is what someone is looking for when they reopen a session months later.
public struct TranscriptTurn: Identifiable, Sendable, Hashable {
    public enum Role: Sendable, Hashable {
        case user
        case assistant
    }

    public let id: String
    public let role: Role
    public let text: String
    public let timestamp: Date?

    public init(id: String, role: Role, text: String, timestamp: Date?) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}
