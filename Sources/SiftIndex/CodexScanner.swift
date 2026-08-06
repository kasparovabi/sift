import Foundation
import SiftCore

/// Walks `~/.codex/sessions`, which nests by date rather than by project, and turns each
/// rollout into the same record a Claude Code transcript produces.
///
/// Most of what is in there is not a session anyone had: on the library this was built
/// against, 64 of 76 files were threads Codex spawned for itself. Those are dropped for the
/// same reason Claude Code's sidechains are.
enum CodexScanner {
    static func scan(
        root: URL,
        known: [String: FileFingerprint] = [:],
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) -> ScanResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else {
            return ScanResult(upserts: [], presentPaths: [])
        }

        var files: [URL] = []
        if let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in walker
            where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
                files.append(url)
            }
        }

        var upserts: [SessionRecord] = []
        var presentPaths = Set<String>()
        let now = Date()
        var done = 0

        for file in files {
            let path = file.path
            presentPaths.insert(path)
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            let mtime = values?.contentModificationDate ?? now
            let fingerprint = FileFingerprint(size: size, mtime: mtime)

            done += 1
            progress?(done, files.count)

            if known[path] == fingerprint { continue }
            guard let meta = CodexTranscript.parse(fileURL: file, fileSize: size) else {
                // A subagent thread. Kept out of `presentPaths` so the store does not treat
                // it as a session that vanished on the next pass.
                presentPaths.remove(path)
                continue
            }
            guard meta.messageCount > 0 else {
                presentPaths.remove(path)
                continue
            }

            let sessionId = meta.sessionId ?? file.deletingPathExtension().lastPathComponent
            upserts.append(SessionRecord(
                sessionId: sessionId,
                projectId: meta.cwd ?? "codex",
                filePath: path,
                cwd: meta.cwd,
                gitBranch: meta.gitBranch,
                title: meta.aiTitle,
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
                headOnly: false,
                agent: .codex
            ))
        }

        return ScanResult(upserts: upserts, presentPaths: presentPaths)
    }
}
