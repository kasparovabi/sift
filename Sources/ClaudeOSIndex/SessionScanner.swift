import Foundation
import ClaudeOSCore

/// A cheap change key for a session file: size + mtime (to the second, since the
/// DB stores Date at millisecond precision and we don't want sub-second jitter to
/// look like a change).
struct FileFingerprint: Sendable, Equatable {
    var size: Int64
    var mtimeEpoch: Int

    init(size: Int64, mtime: Date) {
        self.size = size
        self.mtimeEpoch = Int(mtime.timeIntervalSince1970)
    }
}

/// The result of a scan pass: sessions that are new or changed (and were parsed),
/// plus every session file path currently on disk so the store can drop rows for
/// files that disappeared. Projects are derived in the store from the session
/// table, so they are not carried here.
struct ScanResult: Sendable {
    var upserts: [SessionRecord]
    var presentPaths: Set<String>
}

/// Walks `~/.claude/projects`, parsing only top-level session JSONLs whose
/// fingerprint changed versus `known`. The authoritative project path comes from a
/// session's own `cwd`; the lossy decoded dir name is only a fallback.
enum SessionScanner {
    static func scan(
        projectsRoot: URL,
        known: [String: FileFingerprint] = [:],
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) -> ScanResult {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ScanResult(upserts: [], presentPaths: [])
        }

        var files: [(url: URL, encoded: String)] = []
        for dir in dirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let encoded = dir.lastPathComponent
            let jsonls = ((try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []).filter { $0.pathExtension == "jsonl" }
            for f in jsonls { files.append((f, encoded)) }
        }

        var upserts: [SessionRecord] = []
        var presentPaths = Set<String>()
        let now = Date()
        let total = files.count
        var done = 0

        for (file, encoded) in files {
            let path = file.path
            presentPaths.insert(path)
            let rv = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(rv?.fileSize ?? 0)
            let mtime = rv?.contentModificationDate ?? now
            let fingerprint = FileFingerprint(size: size, mtime: mtime)

            done += 1
            progress?(done, total)

            if known[path] == fingerprint { continue }  // unchanged → leave the DB row as-is

            let meta = JSONLHeadTail.parse(fileURL: file, fileSize: size)
            let sessionId = meta.sessionId ?? file.deletingPathExtension().lastPathComponent
            let title = meta.aiTitle ?? meta.firstMessage.map { String($0.prefix(90)) }
            upserts.append(SessionRecord(
                sessionId: sessionId,
                projectId: encoded,
                filePath: path,
                cwd: meta.cwd,
                gitBranch: meta.gitBranch,
                title: title,
                firstMessage: meta.firstMessage,
                fullText: meta.fullText.isEmpty ? nil : meta.fullText,
                slug: meta.slug,
                entrypoint: meta.entrypoint,
                version: meta.version,
                startedAt: meta.startedAt,
                lastActivity: meta.lastActivity ?? mtime,
                messageCount: meta.messageCount,
                toolCallCount: meta.toolCallCount,
                fileSize: size,
                fileMtime: mtime,
                indexedAt: now,
                headOnly: size > JSONLHeadTail.bigFileThreshold
            ))
        }

        return ScanResult(upserts: upserts, presentPaths: presentPaths)
    }
}
