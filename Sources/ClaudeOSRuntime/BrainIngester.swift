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

    /// Read a transcript bounded to head+tail so extraction token cost stays capped.
    static func boundedRead(_ path: String, cap: Int) -> String? {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return nil }
        if data.count <= cap { return String(decoding: data, as: UTF8.self) }
        let head = data.prefix(cap / 3)
        let tail = data.suffix(cap - cap / 3)
        return String(decoding: head, as: UTF8.self) + "\n…\n" + String(decoding: tail, as: UTF8.self)
    }
}
