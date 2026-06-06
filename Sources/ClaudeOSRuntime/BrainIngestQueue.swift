import Foundation

/// Debounces "transcript changed" signals and runs one ingest per stabilized path.
/// Time is injectable for tests; in production a periodic timer calls `tick(now:)`.
///
/// @unchecked Sendable: all access (touch/tick) happens on the main thread — the
/// IndexCoordinator change callback and the app's tick timer both run on main.
public final class BrainIngestQueue: @unchecked Sendable {
    private let debounce: Double
    private let ingest: (String) -> Void
    private var pending: [String: Double] = [:]
    public init(debounce: Double, ingest: @escaping (String) -> Void) {
        self.debounce = debounce; self.ingest = ingest
    }
    public func touch(_ path: String, now: Double) { pending[path] = now }
    public func tick(now: Double) {
        let ready = pending.filter { now - $0.value >= debounce }.map(\.key)
        for path in ready { pending.removeValue(forKey: path); ingest(path) }
    }
}
