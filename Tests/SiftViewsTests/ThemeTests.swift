import SwiftUI
import XCTest
@testable import SiftRuntime
@testable import SiftViews

/// Preference save/restore happens inside each test rather than in `setUp`/`tearDown`.
/// Those overrides are nonisolated, so on Swift 6.1 they cannot touch the main-actor state
/// these tests exercise, and the suite failed to compile on the CI toolchain while building
/// fine on a newer local one.
@MainActor
final class ThemeTests: XCTestCase {

    func testEveryThemeIsListedOnceAndHasCopy() {
        let ids = SiftTheme.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "two themes sharing an id would be unselectable")
        XCTAssertGreaterThanOrEqual(SiftTheme.all.count, 4, "the point is a choice, not one look")
        for theme in SiftTheme.all {
            XCTAssertFalse(theme.name.isEmpty)
            XCTAssertFalse(theme.blurb.isEmpty, "\(theme.id) needs a line explaining what it is")
        }
    }

    func testThemesAreActuallyDifferentFromEachOther() {
        let fixed = SiftTheme.all.filter { $0.id != "system" }
        let backgrounds = Set(fixed.map { $0.base.description })
        XCTAssertEqual(backgrounds.count, fixed.count, "two themes with one background is one theme")

        let designs = Set(fixed.map { String(describing: $0.fontDesign) })
        XCTAssertGreaterThanOrEqual(designs.count, 3, "type design is what separates them at a glance")
    }

    func testBothLightAndDarkAreOnOffer() {
        XCTAssertTrue(SiftTheme.all.contains { $0.colorScheme == .light })
        XCTAssertTrue(SiftTheme.all.contains { $0.colorScheme == .dark })
        XCTAssertTrue(SiftTheme.all.contains { $0.colorScheme == nil }, "and one that follows macOS")
    }

    func testTheOriginalLookSurvivedAsAnOption() {
        let terminal = SiftTheme.named("terminal")
        XCTAssertEqual(terminal.id, "terminal")
        XCTAssertEqual(terminal.accent, Color(hex: 0xc6ff2e), "the CRT accent, unchanged")
        XCTAssertTrue(terminal.glows)
        XCTAssertEqual(terminal.customFontName, "Departure Mono")
    }

    func testOnlyTheCRTThemeGlows() {
        let glowing = SiftTheme.all.filter(\.glows).map(\.id)
        XCTAssertEqual(glowing, ["terminal"], "a bloom on the paper theme reads as a printing defect")
    }

    func testAnUnknownOrMissingIDFallsBackToSystem() {
        XCTAssertEqual(SiftTheme.named(nil).id, "system")
        XCTAssertEqual(SiftTheme.named("").id, "system")
        XCTAssertEqual(SiftTheme.named("wasteland").id, "system", "a removed theme must not break launch")
    }

    func testSystemThemeDefersToAppKitSoItTracksLightAndDark() {
        XCTAssertNil(SiftTheme.system.colorScheme)
        XCTAssertEqual(SiftTheme.system.accent, Color(nsColor: .controlAccentColor))
        XCTAssertNil(SiftTheme.system.customFontName, "the system face, whatever the user set")
    }

    func testPickingAThemePersistsItAndRepaintsImmediately() {
        withStoredThemeRestored {
            Preferences.themeID = nil
            let store = ThemeStore(theme: .system)
            XCTAssertEqual(Palette.current.id, "system")

            store.theme = .paper
            XCTAssertEqual(Preferences.themeID, "paper", "the choice survives a relaunch")
            XCTAssertEqual(Palette.current.id, "paper", "and the tokens views read change with it")
            XCTAssertEqual(Palette.base, SiftTheme.paper.base)
        }
    }

    func testAStoredThemeIsRestoredOnLaunch() {
        withStoredThemeRestored {
            Preferences.themeID = "ocean"
            XCTAssertEqual(ThemeStore().theme.id, "ocean")
        }
    }

    /// Runs `body` with the stored theme preference and live palette put back afterwards, so
    /// a test cannot leave the developer's own choice changed.
    private func withStoredThemeRestored(_ body: () -> Void) {
        let storedTheme = Preferences.themeID
        let livePalette = Palette.current
        defer {
            Preferences.themeID = storedTheme
            Palette.current = livePalette
        }
        body()
    }
}
