import Foundation

/// Demotes/removes low-value atoms: low importance, aged, and never retrieved.
public struct Forgetter {
    public let store: BrainStore
    public init(store: BrainStore) { self.store = store }

    /// Delete atoms with importance <= maxImportance, older than minAgeSeconds, and
    /// (optionally) never retrieved. Returns the number removed.
    @discardableResult
    public func sweep(now: Double = Date().timeIntervalSince1970,
                      maxImportance: Int = 2,
                      minAgeSeconds: Double = 60 * 60 * 24 * 30,
                      requireZeroRetrievals: Bool = true) throws -> Int {
        try store.forgetLowValue(now: now, maxImportance: maxImportance,
                                 minAgeSeconds: minAgeSeconds, requireZeroRetrievals: requireZeroRetrievals)
    }
}
