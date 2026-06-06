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
        .frame(width: 480, height: 260)
    }

    private var general: some View {
        Form {
            Toggle("Girişte başlat", isOn: Binding(
                get: { launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))
            Stepper(value: Binding(get: { runtime.terminalFontSize },
                                   set: { runtime.setTerminalFontSize($0) }),
                    in: 9...28, step: 1) {
                Text("Terminal yazı boyutu: \(Int(runtime.terminalFontSize)) pt")
            }
            Picker("Duvar kağıdı", selection: Binding(get: { min(max(0, windows.wallpaper), DesktopWallpaper.presets.count - 1) },
                                                      set: { windows.setWallpaper($0) })) {
                ForEach(Array(DesktopWallpaper.presets.enumerated()), id: \.offset) { index, preset in
                    Text(preset.name).tag(index)
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
                .font(.caption)
                .foregroundStyle(.secondary)
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
