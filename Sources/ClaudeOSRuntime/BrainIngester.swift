import Foundation
import ClaudeOSCore
import ClaudeOSBrain

/// Extracts a finished session's transcript into the brain on a background serial
/// queue (one `claude -p` extraction at a time). The session transcript lives at
/// `~/.claude/projects/<encoded-cwd>/<claudeSessionId>.jsonl`.
public final class BrainIngester: @unchecked Sendable {
    private let service: BrainService
    private let claudePath: String
    private let env: [String: String]
    private let projectsRoot: URL
    private let cap: Int
    private let queue = DispatchQueue(label: "claudeos.brain.ingest", qos: .utility)

    public init(service: BrainService,
                claudePath: String = ClaudeBinary.resolve().path,
                env: [String: String] = EnvironmentResolver.resolved(),
                projectsRoot: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects"),
                cap: Int = 60_000) {
        self.service = service
        self.claudePath = claudePath
        self.env = env
        self.projectsRoot = projectsRoot
        self.cap = cap
    }

    /// Absolute transcript path for a session.
    public func transcriptPath(cwd: String, claudeSessionId: String) -> String {
        projectsRoot.appendingPathComponent(PathCodec.encode(cwd))
            .appendingPathComponent("\(claudeSessionId).jsonl").path
    }

    /// Enqueue background extraction of a finished session (no-op if transcript missing).
    public func ingestFinished(cwd: String, claudeSessionId: String) {
        let path = transcriptPath(cwd: cwd, claudeSessionId: claudeSessionId)
        let proj = cwd
        let service = self.service
        let claudePath = self.claudePath
        let env = self.env
        let cap = self.cap
        queue.async {
            guard let text = Self.boundedRead(path, cap: cap) else { return }
            let extractor = Extractor(runner: ProcessRunner(), claudePath: claudePath, env: env)
            try? service.ingestSession(transcript: text, proj: proj, src: claudeSessionId, extractor: extractor)
        }
    }

    /// Ingest an arbitrary JSONL transcript by absolute path.
    /// The session id is derived from the filename (no extension).
    /// The cwd is read from the first line's "cwd" JSON field; if absent,
    /// the parent folder name is decoded via PathCodec.
    public func ingestPath(_ jsonlPath: String) {
        let service = self.service
        let claudePath = self.claudePath
        let env = self.env
        let cap = self.cap
        queue.async {
            let url = URL(fileURLWithPath: jsonlPath)
            let claudeSessionId = url.deletingPathExtension().lastPathComponent
            let cwd: String
            if let detected = Self.firstLineCwd(jsonlPath) {
                cwd = detected
            } else {
                cwd = PathCodec.decode(url.deletingLastPathComponent().lastPathComponent)
            }
            guard let text = Self.boundedRead(jsonlPath, cap: cap) else { return }
            let extractor = Extractor(runner: ProcessRunner(), claudePath: claudePath, env: env)
            try? service.ingestSession(transcript: text, proj: cwd, src: claudeSessionId, extractor: extractor)
        }
    }

    /// Read the first line of a JSONL file, parse it as JSON, and return the "cwd" string field.
    public static func firstLineCwd(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return nil }
        let firstLine: Data
        if let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            firstLine = data[data.startIndex..<newline]
        } else {
            firstLine = data
        }
        guard let obj = try? JSONSerialization.jsonObject(with: firstLine) as? [String: Any] else { return nil }
        return obj["cwd"] as? String
    }

    /// Read a transcript bounded to head+tail so extraction token cost stays capped.
    static func boundedRead(_ path: String, cap: Int) -> String? {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return nil }
        if data.count <= cap { return String(decoding: data, as: UTF8.self) }
        let head = data.prefix(cap / 3)
        let tail = data.suffix(cap - cap / 3)
        return String(decoding: head, as: UTF8.self) + "\n…\n" + String(decoding: tail, as: UTF8.self)
    }
}
