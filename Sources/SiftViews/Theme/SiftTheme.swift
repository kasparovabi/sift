import SwiftUI
import SiftRuntime

/// A design the user can pick in Settings → Appearance.
///
/// Views name what a colour is for (`Palette.textDim`) and never which theme is on, so a
/// new design is a value in this file rather than an edit across the view layer. The System
/// theme's colours come from AppKit semantic colours, which is how it follows the user's
/// light/dark setting and accent colour without any special-casing.
public struct SiftTheme: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let blurb: String

    /// nil follows the system setting.
    public let colorScheme: ColorScheme?
    public let fontDesign: Font.Design
    /// Set only when a theme ships a specific face; nil uses the system font in `fontDesign`.
    public let customFontName: String?

    public let base: Color
    public let surface: Color
    public let surfaceHi: Color
    public let border: Color
    public let textPrimary: Color
    public let textDim: Color
    public let accent: Color
    public let acid: Color
    public let cyan: Color
    public let magenta: Color
    public let danger: Color

    public let cornerRadius: CGFloat
    /// Whether panels and accents bloom. Only the CRT-derived design wants this; on the
    /// light theme a glow reads as a printing defect.
    public let glows: Bool

    public func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let customFontName {
            return .custom(customFontName, size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: fontDesign)
    }

    public var selectionFill: Color { accent.opacity(0.18) }
}

public extension SiftTheme {
    /// Follows macOS: light or dark, and the accent colour set in System Settings.
    /// Every colour here is dynamic, so it re-resolves when the user flips appearance.
    static let system = SiftTheme(
        id: "system",
        name: "System",
        blurb: "Follows macOS. Your light or dark setting, your accent colour.",
        colorScheme: nil,
        fontDesign: .default,
        customFontName: nil,
        base: Color(nsColor: .windowBackgroundColor),
        surface: Color(nsColor: .controlBackgroundColor),
        surfaceHi: Color(nsColor: .unemphasizedSelectedContentBackgroundColor),
        border: Color(nsColor: .separatorColor),
        textPrimary: Color(nsColor: .labelColor),
        textDim: Color(nsColor: .secondaryLabelColor),
        accent: Color(nsColor: .controlAccentColor),
        acid: Color(nsColor: .systemYellow),
        cyan: Color(nsColor: .systemTeal),
        magenta: Color(nsColor: .systemPurple),
        danger: Color(nsColor: .systemRed),
        cornerRadius: 6,
        glows: false
    )

    static let graphite = SiftTheme(
        id: "graphite",
        name: "Graphite",
        blurb: "Neutral dark. Low colour, nothing competing with the text.",
        colorScheme: .dark,
        fontDesign: .default,
        customFontName: nil,
        base: Color(hex: 0x1c1d20),
        surface: Color(hex: 0x26282c),
        surfaceHi: Color(hex: 0x33363c),
        border: Color(hex: 0x3f4349),
        textPrimary: Color(hex: 0xe7e9ec),
        textDim: Color(hex: 0x9aa1aa),
        accent: Color(hex: 0x8ea3c4),
        acid: Color(hex: 0xdfb347),
        cyan: Color(hex: 0x74c0c8),
        magenta: Color(hex: 0xb08cc9),
        danger: Color(hex: 0xe0685c),
        cornerRadius: 10,
        glows: false
    )

    static let ocean = SiftTheme(
        id: "ocean",
        name: "Ocean",
        blurb: "Deep blue with soft edges. Warmer than Graphite, still dark.",
        colorScheme: .dark,
        fontDesign: .rounded,
        customFontName: nil,
        base: Color(hex: 0x0e1a26),
        surface: Color(hex: 0x172a3a),
        surfaceHi: Color(hex: 0x22394d),
        border: Color(hex: 0x2d4c66),
        textPrimary: Color(hex: 0xdcecf5),
        textDim: Color(hex: 0x8aabc0),
        accent: Color(hex: 0x5ac8e8),
        acid: Color(hex: 0xffd479),
        cyan: Color(hex: 0x6fe3d2),
        magenta: Color(hex: 0xa78bfa),
        danger: Color(hex: 0xff7a6b),
        cornerRadius: 14,
        glows: false
    )

    static let paper = SiftTheme(
        id: "paper",
        name: "Paper",
        blurb: "Light and warm, set in a serif face. Made for reading long transcripts.",
        colorScheme: .light,
        fontDesign: .serif,
        customFontName: nil,
        base: Color(hex: 0xf6f2e9),
        surface: Color(hex: 0xfdfbf6),
        surfaceHi: Color(hex: 0xefe7d8),
        border: Color(hex: 0xd8cfbc),
        textPrimary: Color(hex: 0x2e2a24),
        textDim: Color(hex: 0x6d6557),
        accent: Color(hex: 0x9a5b2c),
        acid: Color(hex: 0x9a7b12),
        cyan: Color(hex: 0x2f7d76),
        magenta: Color(hex: 0x8a4f7d),
        danger: Color(hex: 0xb3392c),
        cornerRadius: 4,
        glows: false
    )

    /// Sift began as a CRT-styled app, and this is that palette, kept exactly. It is now one
    /// option among several rather than the only look on offer.
    static let terminal = SiftTheme(
        id: "terminal",
        name: "Terminal",
        blurb: "Phosphor green on near-black, monospaced, with the CRT glow.",
        colorScheme: .dark,
        fontDesign: .monospaced,
        customFontName: "Departure Mono",
        base: Color(hex: 0x080a04),
        surface: Color(hex: 0x10140a),
        surfaceHi: Color(hex: 0x18200e),
        border: Color(hex: 0x46502a),
        textPrimary: Color(hex: 0xbfe84a),
        textDim: Color(hex: 0x7a9438),
        accent: Color(hex: 0xc6ff2e),
        acid: Color(hex: 0xf5e000),
        cyan: Color(hex: 0x5ef0d0),
        magenta: Color(hex: 0xc86bff),
        danger: Color(hex: 0xff3b1f),
        cornerRadius: 8,
        glows: true
    )

    static let all: [SiftTheme] = [.system, .graphite, .ocean, .paper, .terminal]

    static func named(_ id: String?) -> SiftTheme {
        all.first { $0.id == id } ?? .system
    }
}

/// The active theme's tokens, reachable from anywhere in the view layer without threading a
/// value through every initialiser. `ThemeStore` is what changes it, and it re-keys the root
/// view so the whole tree repaints on the switch.
@MainActor
public enum Palette {
    public static var current: SiftTheme = .named(Preferences.themeID)

    public static var base: Color { current.base }
    public static var surface: Color { current.surface }
    public static var surfaceHi: Color { current.surfaceHi }
    public static var border: Color { current.border }
    public static var textPrimary: Color { current.textPrimary }
    public static var textDim: Color { current.textDim }
    public static var accent: Color { current.accent }
    public static var acid: Color { current.acid }
    public static var cyan: Color { current.cyan }
    public static var magenta: Color { current.magenta }
    public static var danger: Color { current.danger }

    public static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        current.font(size, weight: weight)
    }
}

public extension Color {
    /// 0xRRGGBB literal initialiser (distinct signature so it never clashes with a hex-string one).
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }
}

public extension View {
    /// Everything a theme changes app-wide, applied at the root.
    ///
    /// The `.id(theme.id)` is load-bearing: views read their colours from `Palette`, which is
    /// plain state rather than something SwiftUI observes, so switching themes has to rebuild
    /// the tree to repaint it. Re-keying costs the current scroll position on a switch, which
    /// is a fair trade for not threading a theme value through every view in the app.
    func siftThemed(_ theme: SiftTheme) -> some View {
        self
            .environment(\.locale, SiftLocale.ui)
            .tint(theme.accent)
            .background(theme.base)
            .preferredColorScheme(theme.colorScheme)
            .id(theme.id)
    }

    /// Panel surface with a hairline border, and a bloom on the themes that ask for one.
    func siftPanel(cornerRadius: CGFloat? = nil, glow: Bool = false) -> some View {
        let theme = Palette.current
        let radius = cornerRadius ?? theme.cornerRadius
        return background(theme.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(theme.border, lineWidth: 1)
            )
            .shadow(color: (glow && theme.glows) ? theme.accent.opacity(0.22) : .clear,
                    radius: (glow && theme.glows) ? 10 : 0)
    }

    /// Accent bloom. A no-op on the themes that do not glow, so call sites stay unchanged.
    func siftGlow(_ color: Color? = nil, radius: CGFloat = 6) -> some View {
        let theme = Palette.current
        return shadow(color: theme.glows ? (color ?? theme.accent).opacity(0.7) : .clear,
                      radius: theme.glows ? radius : 0)
    }
}

/// Fine horizontal CRT scanlines, drawn only for themes that want the tube.
public struct Scanlines: View {
    public var gap: CGFloat
    public var opacity: Double
    public init(gap: CGFloat = 3, opacity: Double = 0.22) { self.gap = gap; self.opacity = opacity }
    public var body: some View {
        if Palette.current.glows {
            Canvas { ctx, size in
                var y: CGFloat = 0
                while y < size.height {
                    ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                             with: .color(.black.opacity(opacity)))
                    y += gap
                }
            }
            .allowsHitTesting(false)
        }
    }
}
