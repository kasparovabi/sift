import Foundation

/// Debounces "transcript changed" signals and runs one ingest per stabilized path.
/// Time is injectable for testing; in production a timer calls `tick(now:)` periodically.
public final class BrainIngestQueue {
    private let debounce: Double
    private let ingest: (String) -> Void
    private var pending: [String: Double] = [:]   // path -> last touch time

    public init(debounce: Double, ingest: @escaping (String) -> Void) {
        self.debounce = debounce
        self.ingest = ingest
    }

    public func touch(_ path: String, now: Double) {
        pending[path] = now
    }

    /// Fire ingest for any path whose last touch is older than the debounce window.
    public func tick(now: Double) {
        let ready = pending.filter { now - $0.value >= debounce }.map(\.key)
        for path in ready {
            pending.removeValue(forKey: path)
            ingest(path)
        }
    }
}
