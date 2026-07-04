import XCTest
@testable import ClaudeOSRuntime

final class TerminalThemeTests: XCTestCase {
    func testRGBParsesHex() {
        let c = TerminalTheme.rgb("c6ff2e")
        XCTAssertEqual(c[0], Double(0xc6) / 255.0, accuracy: 0.001)
        XCTAssertEqual(c[1], 1.0, accuracy: 0.001)
        XCTAssertEqual(c[2], Double(0x2e) / 255.0, accuracy: 0.001)
    }

    func testRGBIgnoresLeadingHash() {
        XCTAssertEqual(TerminalTheme.rgb("#0a0c06"), TerminalTheme.rgb("0a0c06"))
    }

    /// The wasteland preset mirrors ~/.config/ghostty/config exactly: neon fg/bg,
    /// a cursor colour, a selection colour and the full 16-entry ANSI palette.
    func testWastelandPresetMatchesGhosttyConfig() {
        let w = TerminalTheme.preset(id: "wasteland")
        XCTAssertEqual(w.id, "wasteland")
        XCTAssertEqual(w.bg, TerminalTheme.rgb("0a0c06"))
        XCTAssertEqual(w.fg, TerminalTheme.rgb("c6ff2e"))
        XCTAssertEqual(w.ansi?.count, 16)
        XCTAssertEqual(w.ansi?[1], TerminalTheme.rgb("ff3b1f"))   // ANSI red
        XCTAssertEqual(w.ansi?[10], TerminalTheme.rgb("d8ff5a"))  // bright green
        XCTAssertNotNil(w.cursorColor)
        XCTAssertNotNil(w.selectionColor)
    }

    func testPresetsStillIncludeBuiltInsWithoutPalette() {
        let dark = TerminalTheme.preset(id: "dark")
        XCTAssertEqual(dark.id, "dark")
        XCTAssertNil(dark.ansi)        // built-ins keep SwiftTerm's default palette
        XCTAssertNil(dark.cursorColor)
    }
}
