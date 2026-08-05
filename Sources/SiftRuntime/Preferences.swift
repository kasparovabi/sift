import Foundation

/// User-facing switches that change what the app does on its own.
///
/// Knowledge extraction defaults to OFF. It is the one feature that leaves the machine:
/// it sends session transcripts to `claude -p` under the user's own account, which costs
/// them tokens and puts their transcript text on the wire. A tool that indexes everything
/// you ever typed does not get to turn that on for you.
public enum Preferences {
    private static let extractionKey = "sift.knowledgeExtractionEnabled"

    public static var knowledgeExtractionEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: extractionKey) }
        set { UserDefaults.standard.set(newValue, forKey: extractionKey) }
    }

    /// Bounds how many transcripts one drain may extract. Reopening the app after a week
    /// away hands the watcher every session that changed meanwhile; without a bound that
    /// is one `claude -p` per session, all at once, on the user's quota.
    public static let extractionsPerTick = 2

    /// Whether the extraction question has been put to the user yet. Separate from the
    /// answer, so "no, thanks" is remembered as a decision rather than re-asked every launch.
    private static let extractionAskedKey = "sift.knowledgeExtractionAsked"

    public static var knowledgeExtractionAsked: Bool {
        get { UserDefaults.standard.bool(forKey: extractionAskedKey) }
        set { UserDefaults.standard.set(newValue, forKey: extractionAskedKey) }
    }

    /// Identifier of the chosen appearance. Resolved to a theme in the view layer, which is
    /// where the designs live; an unknown id falls back to the system one.
    private static let themeKey = "sift.themeID"

    public static var themeID: String? {
        get { UserDefaults.standard.string(forKey: themeKey) }
        set { UserDefaults.standard.set(newValue, forKey: themeKey) }
    }
}
