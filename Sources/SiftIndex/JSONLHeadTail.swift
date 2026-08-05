import Foundation

/// Metadata extracted from a session JSONL without loading the whole file.
struct ParsedSessionMeta: Sendable {
    var sessionId: String?
    var cwd: String?
    var gitBranch: String?
    var entrypoint: String?
    var version: String?
    var slug: String?
    var firstMessage: String?
    var fullText: String = ""
    var aiTitle: String?
    var startedAt: Date?
    var lastActivity: Date?
    var messageCount: Int = 0
    var toolCallCount: Int = 0
}

/// Reads just enough of a session JSONL to index it: the first real human
/// message + metadata from the head, and the `ai-title` + last timestamp from the
/// tail. Small files are parsed fully; files past `bigFileThreshold` use two
/// bounded reads so the 21 MB session stays cheap.
enum JSONLHeadTail {
    static let bigFileThreshold: Int64 = 4 * 1024 * 1024

    static func parse(fileURL: URL, fileSize: Int64) -> ParsedSessionMeta {
        var meta = ParsedSessionMeta()
        if fileSize <= bigFileThreshold {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return meta }
            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                ingest(String(line), into: &meta)
            }
        } else {
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return meta }
            defer { try? handle.close() }
            let headData = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
            if let headText = String(data: headData, encoding: .utf8) {
                for line in headText.split(separator: "\n").dropLast() { ingest(String(line), into: &meta) }
            }
            let tailStart = max(0, fileSize - 64 * 1024)
            try? handle.seek(toOffset: UInt64(tailStart))
            let tailData = (try? handle.readToEnd()) ?? Data()
            if let tailText = String(data: tailData, encoding: .utf8) {
                for line in tailText.split(separator: "\n").dropFirst() { ingestTail(String(line), into: &meta) }
            }
        }
        return meta
    }

    private static func ingest(_ line: String, into meta: inout ParsedSessionMeta) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if meta.sessionId == nil { meta.sessionId = obj["sessionId"] as? String }
        if meta.cwd == nil { meta.cwd = obj["cwd"] as? String }
        if meta.gitBranch == nil { meta.gitBranch = obj["gitBranch"] as? String }
        if meta.entrypoint == nil { meta.entrypoint = obj["entrypoint"] as? String }
        if meta.version == nil { meta.version = obj["version"] as? String }
        if meta.slug == nil { meta.slug = obj["slug"] as? String }

        if let ts = (obj["timestamp"] as? String).flatMap(parseDate) {
            if meta.startedAt == nil { meta.startedAt = ts }
            meta.lastActivity = ts
        }

        switch obj["type"] as? String {
        case "user":
            if let text = humanUserText(obj) {
                if meta.firstMessage == nil { meta.firstMessage = String(text.prefix(2000)) }
                meta.messageCount += 1
                accumulate(text, into: &meta)
            }
        case "assistant":
            if hasToolUse(obj) { meta.toolCallCount += 1 }
            // Counted only when the turn carries prose, so the number agrees with the
            // transcript, which shows what the two sides said and nothing else.
            if let text = assistantPlainText(obj) {
                meta.messageCount += 1
                accumulate(text, into: &meta)
            }
        case "ai-title":
            if let t = aiTitle(obj) { meta.aiTitle = t }
        default:
            break
        }
    }

    private static func ingestTail(_ line: String, into meta: inout ParsedSessionMeta) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        switch obj["type"] as? String {
        case "ai-title": if let t = aiTitle(obj) { meta.aiTitle = t }
        case "user": if let text = humanUserText(obj) { accumulate(text, into: &meta) }
        case "assistant": if let text = assistantPlainText(obj) { accumulate(text, into: &meta) }
        default: break
        }
        if let ts = (obj["timestamp"] as? String).flatMap(parseDate) {
            if meta.lastActivity == nil || ts > meta.lastActivity! { meta.lastActivity = ts }
        }
    }

    private static let fullTextCap = 100_000

    private static func accumulate(_ text: String, into meta: inout ParsedSessionMeta) {
        guard meta.fullText.count < fullTextCap else { return }
        meta.fullText += text
        meta.fullText += "\n"
    }

    private static func assistantPlainText(_ obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any] else { return nil }
        if let s = message["content"] as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
        let joined = texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func aiTitle(_ obj: [String: Any]) -> String? {
        (obj["aiTitle"] as? String) ?? (obj["title"] as? String)
    }

    /// True human input only: skip meta lines, tool results, and harness wrappers.
    private static func humanUserText(_ obj: [String: Any]) -> String? {
        if obj["isMeta"] as? Bool == true { return nil }
        if obj["isCompactSummary"] as? Bool == true { return nil }
        if obj["isSidechain"] as? Bool == true { return nil }
        guard let message = obj["message"] as? [String: Any], let content = message["content"] else { return nil }

        let text: String
        if let s = content as? String {
            text = s
        } else if let blocks = content as? [[String: Any]] {
            let texts = blocks.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
            if texts.isEmpty { return nil }
            text = texts.joined(separator: " ")
        } else {
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let skip = ["<command-", "[Request interrupted", "<task-notification", "<scheduled-wakeup",
                    "<background-task", "<system-reminder", "Caveat:"]
        for prefix in skip where trimmed.hasPrefix(prefix) { return nil }
        return trimmed
    }

    private static func hasToolUse(_ obj: [String: Any]) -> Bool {
        guard let message = obj["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return false }
        return blocks.contains { ($0["type"] as? String) == "tool_use" }
    }

    private static func parseDate(_ s: String) -> Date? {
        isoWithFraction.date(from: s) ?? isoPlain.date(from: s)
    }

    nonisolated(unsafe) private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
