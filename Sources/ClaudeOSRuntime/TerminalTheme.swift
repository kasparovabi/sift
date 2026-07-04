import AppKit

/// A terminal colour preset. Stored by `id` in UserDefaults; the NSColors are rebuilt
/// on apply so the value type stays Sendable. Beyond foreground/background a preset may
/// carry a cursor colour, a selection colour and a full 16-entry ANSI palette (the
/// wasteland preset uses all of them; the plain built-ins leave SwiftTerm's defaults).
public struct TerminalTheme: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let bg: [Double]            // r,g,b in 0...1
    public let fg: [Double]
    public let cursor: [Double]?
    public let selectionBg: [Double]?
    public let ansi: [[Double]]?       // exactly 16 entries when present (ANSI 0...15)

    public init(id: String, name: String, bg: [Double], fg: [Double],
                cursor: [Double]? = nil, selectionBg: [Double]? = nil, ansi: [[Double]]? = nil) {
        self.id = id; self.name = name; self.bg = bg; self.fg = fg
        self.cursor = cursor; self.selectionBg = selectionBg; self.ansi = ansi
    }

    public var background: NSColor { Self.color(bg) }
    public var foreground: NSColor { Self.color(fg) }
    public var cursorColor: NSColor? { cursor.map(Self.color) }
    public var selectionColor: NSColor? { selectionBg.map(Self.color) }
    /// ANSI palette as NSColors, when the preset defines one.
    public var ansiColors: [NSColor]? { ansi?.map(Self.color) }

    private static func color(_ c: [Double]) -> NSColor {
        NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1)
    }

    /// Parse an "rrggbb" (or "#rrggbb") hex string into [r,g,b] in 0...1.
    public static func rgb(_ hex: String) -> [Double] {
        var s = Substring(hex)
        if s.hasPrefix("#") { s = s.dropFirst() }
        let v = UInt32(s, radix: 16) ?? 0
        return [Double((v >> 16) & 0xff) / 255.0,
                Double((v >> 8) & 0xff) / 255.0,
                Double(v & 0xff) / 255.0]
    }

    public static let presets: [TerminalTheme] = [
        // Signature look: radioactive neon + CRT phosphor, mirrored from
        // ~/.config/ghostty/config so the embedded terminal matches the wasteland setup.
        TerminalTheme(
            id: "wasteland", name: "Wasteland",
            bg: rgb("0a0c06"), fg: rgb("c6ff2e"),
            cursor: rgb("f5e000"), selectionBg: rgb("2a3410"),
            ansi: [
                rgb("0a0c06"), rgb("ff3b1f"), rgb("c6ff2e"), rgb("f5e000"),
                rgb("3ad6c0"), rgb("c86bff"), rgb("5ef0d0"), rgb("b9c79a"),
                rgb("46502a"), rgb("ff6a4f"), rgb("d8ff5a"), rgb("ffe838"),
                rgb("5cf0d8"), rgb("e08cff"), rgb("8affe0"), rgb("eaffc0"),
            ]),
        TerminalTheme(id: "dark",   name: "Koyu",  bg: [0.11, 0.11, 0.12], fg: [0.86, 0.86, 0.88]),
        TerminalTheme(id: "night",  name: "Gece",  bg: [0.06, 0.08, 0.16], fg: [0.82, 0.86, 0.96]),
        TerminalTheme(id: "forest", name: "Orman", bg: [0.05, 0.10, 0.07], fg: [0.80, 0.92, 0.82]),
        TerminalTheme(id: "light",  name: "Açık",  bg: [0.97, 0.97, 0.95], fg: [0.16, 0.16, 0.18]),
    ]

    public static func preset(id: String) -> TerminalTheme {
        presets.first { $0.id == id } ?? presets[0]
    }
}
