import SwiftUI
import SiftRuntime

/// Holds the chosen theme and writes it through to preferences.
///
/// Observable and shared, because the picker lives in the Settings scene while the theme has
/// to repaint the library window: two scenes, one object, so switching is immediate rather
/// than "takes effect on the next launch".
@MainActor
@Observable
public final class ThemeStore {
    public var theme: SiftTheme {
        didSet {
            guard theme.id != oldValue.id else { return }
            Palette.current = theme
            Preferences.themeID = theme.id
        }
    }

    public init(theme: SiftTheme = .named(Preferences.themeID)) {
        self.theme = theme
        Palette.current = theme
    }
}
