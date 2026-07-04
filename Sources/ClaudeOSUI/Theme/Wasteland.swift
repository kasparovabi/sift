import SwiftUI

/// Wasteland design system: radioactive neon + CRT phosphor. Single source of truth for the
/// whole app's colours, type and surface treatments, derived 1:1 from ~/.config/ghostty/config
/// so the UI and the embedded terminals read as one machine.
public enum Wasteland {
    // Core palette (sRGB). Tuned to the dim, warm CRT phosphor of the Ghostty wasteland
    // setup: a green-dominant body that glows under the CRT layer effect, with brighter
    // neon and acid reserved for emphasis so the UI reads as a tube, not flat neon.
    public static let base        = Color(hex: 0x080a04)   // near-black olive (app background)
    public static let surface     = Color(hex: 0x10140a)   // panel
    public static let surfaceHi   = Color(hex: 0x18200e)   // raised panel / selected row
    public static let border      = Color(hex: 0x46502a)   // dim olive hairline
    public static let textPrimary = Color(hex: 0xbfe84a)   // medium phosphor green (body text)
    public static let textDim     = Color(hex: 0x7a9438)   // dim olive-green (secondary)
    public static let accent      = Color(hex: 0xc6ff2e)   // bright neon green (primary accent)
    public static let acid        = Color(hex: 0xf5e000)   // acid yellow (cursor / hot accent / labels)
    public static let cyan        = Color(hex: 0x5ef0d0)
    public static let magenta     = Color(hex: 0xc86bff)
    public static let danger      = Color(hex: 0xff3b1f)

    /// Departure Mono everywhere; SwiftUI falls back to the system monospaced face when the
    /// font isn't installed, so this is always safe.
    public static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Departure Mono", size: size).weight(weight)
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
    /// Dark panel with a neon hairline border; optionally a soft phosphor glow.
    func wastelandPanel(cornerRadius: CGFloat = 8, glow: Bool = false) -> some View {
        self
            .background(Wasteland.surface, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Wasteland.border, lineWidth: 1)
            )
            .shadow(color: glow ? Wasteland.accent.opacity(0.22) : .clear, radius: glow ? 10 : 0)
    }

    /// Neon text/element glow.
    func neonGlow(_ color: Color = Wasteland.accent, radius: CGFloat = 6) -> some View {
        shadow(color: color.opacity(0.7), radius: radius)
    }
}

/// Fine horizontal CRT scanlines. Drawn as thin dark rows so lit phosphor reads as a tube.
public struct Scanlines: View {
    public var gap: CGFloat
    public var opacity: Double
    public init(gap: CGFloat = 3, opacity: Double = 0.22) { self.gap = gap; self.opacity = opacity }
    public var body: some View {
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

/// Faint neon phosphor grid for the desktop wallpaper, so the screen reads as a CRT surface
/// (it blooms softly under the desktop's Core Image filter).
public struct WastelandGrid: View {
    public var spacing: CGFloat
    public init(spacing: CGFloat = 46) { self.spacing = spacing }
    public var body: some View {
        Canvas { ctx, size in
            let shade = GraphicsContext.Shading.color(Wasteland.accent.opacity(0.5))
            var x: CGFloat = 0
            while x < size.width {
                ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                           with: shade, lineWidth: 0.5)
                x += spacing
            }
            var y: CGFloat = 0
            while y < size.height {
                ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                           with: shade, lineWidth: 0.5)
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

public extension View {
    /// Lay the wasteland CRT tube over a view: visible horizontal scanlines plus a soft corner
    /// vignette. Pure SwiftUI (no Metal toolchain needed), non-interactive overlay so layout,
    /// hit-testing and events are untouched. Pairs with the Core Image phosphor bloom applied
    /// at the window layer.
    func crtPhosphor() -> some View {
        overlay {
            ZStack {
                Scanlines(gap: 3, opacity: 0.22)
                RadialGradient(colors: [.clear, Color.black.opacity(0.32)],
                               center: .center, startRadius: 140, endRadius: 820)
            }
            .allowsHitTesting(false)
        }
    }
}
