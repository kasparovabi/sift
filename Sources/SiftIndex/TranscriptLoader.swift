import Foundation
import SiftCore

/// Loads a read-only transcript preview from a session JSONL. Small files are
/// parsed fully; large ones are read from the tail so even a 21 MB session opens
/// instantly. Returns at most `maxTurns` most-recent turns.
public enum TranscriptLoader {
    public static func load(filePath: String, maxTurns: Int = 200) async -> [TranscriptTurn] {
        await Task.detached(priority: .userInitiated) {
            parse(filePath: filePath, maxTurns: maxTurns)
        }.value
    }

    static func parse(filePath: String, maxTurns: Int) -> [TranscriptTurn] {
        let url = URL(fileURLWithPath: filePath)
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)

        var lines: [Substring] = []
        if size <= 4 * 1024 * 1024 {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        } else if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            try? handle.seek(toOffset: UInt64(max(0, size - 1024 * 1024)))
            let data = (try? handle.readToEnd()) ?? Data()
            if let text = String(data: data, encoding: .utf8) {
                lines = Array(text.split(separator: "\n", omittingEmptySubsequences: true).dropFirst())
            }
        }

        var turns: [TranscriptTurn] = []
        var seen = Set<String>()
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let uuid = (obj["uuid"] as? String) ?? UUID().uuidString
            if seen.contains(uuid) { continue }
            let ts = (obj["timestamp"] as? String).flatMap(parseDate)

            switch obj["type"] as? String {
            case "user":
                if let text = humanText(obj) {
                    seen.insert(uuid)
                    turns.append(TranscriptTurn(id: uuid, role: .user, text: text, timestamp: ts))
                }
            case "assistant":
                if let text = assistantText(obj) {
                    seen.insert(uuid)
                    turns.append(TranscriptTurn(id: uuid, role: .assistant, text: text, timestamp: ts))
                }
            default:
                break
            }
        }
        return turns.count > maxTurns ? Array(turns.suffix(maxTurns)) : turns
    }

    private static func humanText(_ obj: [String: Any]) -> String? {
        if obj["isMeta"] as? Bool == true { return nil }
        if obj["isSidechain"] as? Bool == true { return nil }
        guard let message = obj["message"] as? [String: Any], let content = message["content"] else { return nil }
        let text: String
        if let s = content as? String {
            text = s
        } else if let blocks = content as? [[String: Any]] {
            let parts = blocks.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
            if parts.isEmpty { return nil }
            text = parts.joined(separator: "\n")
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Slash-command envelopes, hook output and injected reminders arrive as "user"
        // messages but nobody typed them, so they are not part of the conversation.
        for prefix in ["<command-", "<local-command", "<task-notification", "<scheduled-wakeup",
                       "<background-task", "<system-reminder"]
        where trimmed.hasPrefix(prefix) { return nil }
        return trimmed
    }

    /// What the assistant actually said. A turn that only carries `tool_use` blocks has
    /// no prose in it, so it yields nothing and never reaches the transcript.
    private static func assistantText(_ obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any] else { return nil }
        if let s = message["content"] as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
        let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func parseDate(_ s: String) -> Date? {
        isoWithFraction.date(from: s) ?? isoPlain.date(from: s)
    }
    nonisolated(unsafe) private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
}
