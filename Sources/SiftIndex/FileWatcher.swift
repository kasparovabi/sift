import Foundation
import CoreServices

/// Watches a directory tree via FSEvents and fires a debounced callback when
/// anything changes. The callback only signals "something moved" — the
/// coordinator then does a fingerprint diff to find what actually changed.
final class FileWatcher: @unchecked Sendable {
    private let path: String
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.sift.filewatcher")
    private var stream: FSEventStreamRef?
    private var debounce: DispatchWorkItem?

    init(path: String, onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue().scheduleDebounced()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    private func scheduleDebounced() {
        debounce?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        debounce = work
        queue.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
