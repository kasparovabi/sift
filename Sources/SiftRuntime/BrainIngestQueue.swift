import Foundation

/// Debounces "transcript changed" signals and runs one ingest per stabilized path.
/// Time is injectable for tests; in production a periodic timer calls `tick(now:)`.
///
/// @unchecked Sendable: all access (touch/tick) happens on the main thread — the
/// IndexCoordinator change callback and the app's tick timer both run on main.
public final class BrainIngestQueue: @unchecked Sendable {
    private let debounce: Double
    private let maxPerTick: Int
    private let ingest: (String) -> Void
    private var pending: [String: Double] = [:]

    public init(debounce: Double, maxPerTick: Int = .max, ingest: @escaping (String) -> Void) {
        self.debounce = debounce
        self.maxPerTick = max(1, maxPerTick)
        self.ingest = ingest
    }

    public var pendingCount: Int { pending.count }

    public func touch(_ path: String, now: Double) { pending[path] = now }

    /// Forget everything queued. Called when extraction is switched off, so switching it
    /// back on later cannot flush a backlog into `claude -p` all at once.
    public func drop() { pending.removeAll() }

    /// Drains at most `maxPerTick` stabilized paths. Reopening the app after a week away
    /// hands the watcher every session that changed meanwhile; each one costs a `claude -p`
    /// run on the user's quota, so the drain is paced instead of firing the whole backlog.
    public func tick(now: Double) {
        let ready = pending
            .filter { now - $0.value >= debounce }
            .map(\.key)
            .sorted()
            .prefix(maxPerTick)
        for path in ready {
            pending.removeValue(forKey: path)
            ingest(path)
        }
    }
}
