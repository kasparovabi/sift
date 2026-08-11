import Foundation

/// Folders whose sessions you do not want to see. A harness that gives every run its own
/// directory produces hundreds of sessions nobody had and nobody will resume, and they crowd
/// out the ones you did have.
///
/// A list rather than a rule, because which folders are machinery is a judgement only the
/// person whose machine it is can make. Plain text so it can be edited by hand, and read by
/// all three versions of Sift from the same place.
public enum HiddenProjects {
    public static var fileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("hidden-projects.txt")
    }

    public static func all() -> [String] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return parse(text)
    }

    static func parse(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { trimSeparators($0) }
    }

    private static func trimSeparators(_ path: String) -> String {
        var trimmed = path
        while trimmed.hasSuffix("/") || trimmed.hasSuffix("\\") { trimmed.removeLast() }
        return trimmed
    }

    /// True when `hidden` is the path itself or one of its ancestors, matched on whole path
    /// components so hiding `~/harness` does not also hide `~/harness-notes`.
    public static func covers(_ hidden: String, _ path: String) -> Bool {
        let candidate = trimSeparators(path)
        if candidate.compare(hidden, options: .caseInsensitive) == .orderedSame { return true }
        guard candidate.count > hidden.count,
              candidate.lowercased().hasPrefix(hidden.lowercased()) else { return false }
        let next = candidate[candidate.index(candidate.startIndex, offsetBy: hidden.count)]
        return next == "/" || next == "\\"
    }

    public static func isHidden(_ path: String, in hidden: [String] = all()) -> Bool {
        hidden.contains { covers($0, path) }
    }

    public static func hide(_ path: String) {
        let trimmed = trimSeparators(path)
        guard !trimmed.isEmpty, !isHidden(trimmed) else { return }
        let header = """
            # Folders Sift will not list. One path per line.
            # Everything under a listed folder is hidden too. Delete a line to bring it back.

            """
        let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? header
        try? FileManager.default.createDirectory(at: AppPaths.supportDirectory,
                                                 withIntermediateDirectories: true)
        try? (existing + trimmed + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }

    public static func show(_ path: String) {
        let trimmed = trimSeparators(path)
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).filter {
            trimSeparators($0.trimmingCharacters(in: .whitespaces))
                .compare(trimmed, options: .caseInsensitive) != .orderedSame
        }
        try? kept.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// SQL that is false for a session under any hidden folder. Nil when nothing is hidden,
    /// so the common case adds nothing to the query.
    ///
    /// The wildcard comes after a separator, never straight after the name. Without that,
    /// hiding `~/harness` also hides `~/harness-notes`, which is a different folder.
    public static func predicate(_ hidden: [String]) -> String? {
        guard !hidden.isEmpty else { return nil }
        let column = "COALESCE(session.cwd, session.projectId)"
        let clauses = hidden.map { path -> String in
            let quoted = path.replacingOccurrences(of: "'", with: "''")
            let escaped = quoted
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            return "(\(column) = '\(quoted)' OR "
                 + "\(column) LIKE '\(escaped)\\\\%' ESCAPE '\\' OR "
                 + "\(column) LIKE '\(escaped)/%' ESCAPE '\\')"
        }
        return "NOT (" + clauses.joined(separator: " OR ") + ")"
    }
}
