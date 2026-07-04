import SwiftUI
import ServiceManagement
import KeyboardShortcuts
import ClaudeOSIndex
import ClaudeOSRuntime

/// App preferences: launch-at-login, terminal appearance, the global quick-open
/// shortcut, and index maintenance. Shown via the standard Settings menu (⌘,).
public struct SettingsView: View {
    @Environment(IndexCoordinator.self) private var index
    @Environment(SessionRuntime.self) private var runtime
    @Environment(DesktopWindowManager.self) private var windows
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    public init() {}

    public var body: some View {
        TabView {
            general.tabItem { Label("Genel", systemImage: "gearshape") }
            shortcuts.tabItem { Label("Kısayollar", systemImage: "command") }
        }
        .frame(width: 480, height: 330)
    }

    /// Even 3×3 mesh control points for the static wallpaper swatches.
    private static let evenPoints: [SIMD2<Float>] = [
        SIMD2(0, 0), SIMD2(0.5, 0), SIMD2(1, 0),
        SIMD2(0, 0.5), SIMD2(0.5, 0.5), SIMD2(1, 0.5),
        SIMD2(0, 1), SIMD2(0.5, 1), SIMD2(1, 1),
    ]

    @ViewBuilder private func wallpaperSwatch(_ idx: Int) -> some View {
        let selected = min(max(0, windows.wallpaper), DesktopWallpaper.presets.count - 1) == idx
        VStack(spacing: 4) {
            Group {
                if #available(macOS 15.0, *) {
                    MeshGradient(width: 3, height: 3, points: Self.evenPoints,
                                 colors: DesktopWallpaper.meshColors(idx))
                } else {
                    DesktopWallpaper.gradient(idx)
                }
            }
            .frame(width: 58, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Wasteland.accent : Wasteland.border,
                              lineWidth: selected ? 2.5 : 1))
            Text(DesktopWallpaper.presets[idx].name)
                .font(Wasteland.font(10))
                .foregroundStyle(selected ? Wasteland.textPrimary : Wasteland.textDim)
        }
        .contentShape(Rectangle())
        .onTapGesture { windows.setWallpaper(idx) }
    }

    /// A terminal colour preview swatch: shows the theme's background with a sample "Aa"
    /// in its foreground colour, and selects it on tap (applies live to open terminals).
    @ViewBuilder private func terminalThemeSwatch(_ theme: TerminalTheme) -> some View {
        let selected = runtime.terminalThemeId == theme.id
        VStack(spacing: 4) {
            Text("Aa")
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(theme.foreground))
                .frame(width: 58, height: 38)
                .background(Color(theme.background))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Wasteland.accent : Wasteland.border,
                                  lineWidth: selected ? 2.5 : 1))
            Text(theme.name)
                .font(Wasteland.font(10))
                .foregroundStyle(selected ? Wasteland.textPrimary : Wasteland.textDim)
        }
        .contentShape(Rectangle())
        .onTapGesture { runtime.setTerminalTheme(id: theme.id) }
    }

    private var general: some View {
        Form {
            Toggle("Girişte başlat", isOn: Binding(
                get: { launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))
            Toggle("Açılışta oturumları otomatik sürdür", isOn: Binding(
                get: { runtime.autostartRestoredSessions },
                set: { runtime.setAutostartRestoredSessions($0) }
            ))
            Stepper(value: Binding(get: { runtime.terminalFontSize },
                                   set: { runtime.setTerminalFontSize($0) }),
                    in: 9...28, step: 1) {
                Text("Terminal yazı boyutu: \(Int(runtime.terminalFontSize)) pt")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Terminal rengi")
                    .font(Wasteland.font(12, weight: .medium))
                    .foregroundStyle(Wasteland.textPrimary)
                HStack(spacing: 10) {
                    ForEach(TerminalTheme.presets) { theme in
                        terminalThemeSwatch(theme)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Duvar kağıdı")
                    .font(Wasteland.font(12, weight: .medium))
                    .foregroundStyle(Wasteland.textPrimary)
                HStack(spacing: 10) {
                    ForEach(DesktopWallpaper.presets.indices, id: \.self) { i in
                        wallpaperSwatch(i)
                    }
                }
            }
            LabeledContent("İndekslenen oturum", value: "\(index.totalSessionCount)")
            LabeledContent("Proje", value: "\(index.projects.count)")
            Button("Şimdi yeniden tara") { Task { await index.rescan() } }
                .disabled(index.isScanning)
        }
        .formStyle(.grouped)
    }

    private var shortcuts: some View {
        Form {
            KeyboardShortcuts.Recorder("Hızlı aç (global):", name: .quickOpen)
            Text("Bu kısayol uygulama kapalı pencereyle bile, herhangi bir yerden çalışır.")
                .font(Wasteland.font(11))
                .foregroundStyle(Wasteland.textDim)
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Registration needs the app to live in /Applications and be signed;
            // reflect whatever the real status is.
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
