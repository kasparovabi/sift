import Foundation

/// One rendered turn in a session transcript preview (read-only).
public struct TranscriptTurn: Identifiable, Sendable, Hashable {
    public enum Role: Sendable, Hashable {
        case user
        case assistant
        case tool
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
