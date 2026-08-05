import Foundation
import Observation

/// Tracks which sessions are *currently running* in any Claude process (not just
/// ours) by reading `~/.claude/sessions/<pid>.json` and checking the PID is alive.
/// Refreshed on a short timer; the set is volatile so it never touches the DB.
@MainActor
@Observable
public final class LiveSessionMonitor {
    public private(set) var liveSessionIds: Set<String> = []

    @ObservationIgnored private let sessionsDir: URL
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(sessionsDir: URL? = nil) {
        self.sessionsDir = sessionsDir
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func refresh() async {
        let dir = sessionsDir
        liveSessionIds = await Task.detached(priority: .utility) {
            Self.scanLive(dir)
        }.value
    }

    nonisolated static func scanLive(_ dir: URL) -> Set<String> {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var ids = Set<String>()
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionId = obj["sessionId"] as? String,
                  let pid = obj["pid"] as? Int else { continue }
            if kill(pid_t(pid), 0) == 0 { ids.insert(sessionId) }
        }
        return ids
    }
}
