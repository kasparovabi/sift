import KeyboardShortcuts

public extension KeyboardShortcuts.Name {
    /// Global Spotlight-style session finder. Default ⌥Space, user-rebindable.
    /// Immutable after creation; `nonisolated(unsafe)` since KeyboardShortcuts.Name
    /// predates Swift 6 Sendable annotations.
    nonisolated(unsafe) static let quickOpen = Self("claudeOSQuickOpen", default: .init(.space, modifiers: [.option]))
}
