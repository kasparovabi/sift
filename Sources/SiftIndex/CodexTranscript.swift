import Foundation
import SiftCore

/// Codex writes one JSONL per session under `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`.
/// Every line is `{timestamp, type, payload}`. The first line is `session_meta` and carries
/// the working directory and git state; the turns arrive as `response_item` payloads of type
/// `message`.
///
/// The shape differs enough from Claude Code's that sharing one parser would mean a parser
/// full of branches. It produces the same `ParsedSessionMeta`, so everything downstream —
/// the index, search, the reader — stays unaware there are two formats.
enum CodexTranscript {
    /// A thread Codex spawned for itself. The equivalent of Claude Code's `isSidechain`:
    /// machinery rather than a session anyone had, and indexing it buries the real ones.
    static func isSubagent(_ meta: [String: Any]) -> Bool {
        if let source = meta["thread_source"] as? String, source == "subagent" { return true }
        return meta["source"] as? [String: Any] != nil && meta["parent_thread_id"] != nil
    }

    static func parse(fileURL: URL, fileSize: Int64) -> ParsedSessionMeta? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        var meta = ParsedSessionMeta()
        var texts: [String] = []
        var isSubagentThread = false

        for line in LineReader(handle: handle) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let stamp = (object["timestamp"] as? String).flatMap(parseDate)
            if meta.startedAt == nil { meta.startedAt = stamp }
            if let stamp { meta.lastActivity = stamp }

            guard let payload = object["payload"] as? [String: Any] else { continue }

            switch object["type"] as? String {
            case "session_meta":
                if isSubagent(payload) { isSubagentThread = true }
                meta.sessionId = payload["id"] as? String ?? payload["session_id"] as? String
                meta.cwd = payload["cwd"] as? String
                meta.version = payload["cli_version"] as? String
                meta.entrypoint = payload["originator"] as? String
                if let git = payload["git"] as? [String: Any] {
                    meta.gitBranch = git["branch"] as? String
                }
            case "response_item":
                guard payload["type"] as? String == "message" else {
                    if payload["type"] as? String == "function_call" { meta.toolCallCount += 1 }
                    continue
                }
                let role = payload["role"] as? String
                // `developer` is the harness talking to the model about sandboxing and
                // policy. It is not one of the two sides of the conversation.
                guard role == "user" || role == "assistant" else { continue }
                guard let text = text(from: payload["content"]), !text.isEmpty else { continue }
                if role == "user", isInjected(text) { continue }

                meta.messageCount += 1
                texts.append(text)
                if role == "user", meta.firstMessage == nil {
                    meta.firstMessage = String(text.prefix(400))
                }
            default:
                continue
            }
        }

        if isSubagentThread { return nil }
        meta.fullText = texts.joined(separator: "\n")
        meta.aiTitle = meta.firstMessage.map { String($0.prefix(90)) }
        return meta
    }

    /// Codex prepends AGENTS.md and permission blocks to the user's own words. Indexing
    /// those makes every session in a repository look identical to every other one.
    private static func isInjected(_ text: String) -> Bool {
        let openings = ["# AGENTS.md instructions", "<permissions instructions>",
                        "<INSTRUCTIONS>", "<environment_context>", "<user_instructions>",
                        "<recommended_plugins>"]
        return openings.contains { text.hasPrefix($0) }
    }

    private static func text(from content: Any?) -> String? {
        if let string = content as? String { return string }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let parts = blocks.compactMap { block -> String? in
            switch block["type"] as? String {
            case "input_text", "output_text", "text": return block["text"] as? String
            default: return nil
            }
        }
        let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func parseDate(_ string: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: string)
    }
}

/// Reads a file a line at a time. A Codex rollout can be tens of megabytes and holding one
/// in memory to split it is the difference between indexing a library and swapping.
struct LineReader: Sequence, IteratorProtocol {
    private let handle: FileHandle
    private var buffer = Data()
    private var finished = false
    private let chunk = 1 << 16

    init(handle: FileHandle) { self.handle = handle }

    mutating func next() -> String? {
        while true {
            if let index = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<index]
                buffer.removeSubrange(buffer.startIndex...index)
                if let string = String(data: line, encoding: .utf8), !string.isEmpty { return string }
                continue
            }
            if finished {
                guard !buffer.isEmpty else { return nil }
                let rest = String(data: buffer, encoding: .utf8)
                buffer.removeAll()
                return rest?.isEmpty == false ? rest : nil
            }
            let data = handle.readData(ofLength: chunk)
            if data.isEmpty { finished = true } else { buffer.append(data) }
        }
    }
}
