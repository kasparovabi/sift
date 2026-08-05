import SwiftUI
import ServiceManagement
import KeyboardShortcuts
import SiftIndex
import SiftRuntime

/// App preferences: launch-at-login, the global quick-open shortcut, and index maintenance.
///
/// Terminal appearance (font, colour preset) and the desktop wallpaper used to live here.
/// Sessions now open in the user's own terminal, which already has their fonts and colours,
/// so there is nothing left for the app to restyle.
public struct SettingsView: View {
    @Environment(IndexCoordinator.self) private var index
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @State private var extractionEnabled = Preferences.knowledgeExtractionEnabled

    public init() {}

    public var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }
            knowledge.tabItem { Label("Knowledge", systemImage: "brain") }
            shortcuts.tabItem { Label("Shortcuts", systemImage: "command") }
        }
        .frame(minWidth: 500, minHeight: 380)
    }

    private var knowledge: some View {
        Form {
            Toggle("Extract knowledge from finished sessions", isOn: Binding(
                get: { extractionEnabled },
                set: { extractionEnabled = $0; Preferences.knowledgeExtractionEnabled = $0 }
            ))
            Text("""
                This is the only part of Sift that leaves your Mac. Each finished session is \
                sent to `claude -p` under your own Claude account so durable facts can be \
                pulled out of it and drawn as the knowledge graph. It spends your tokens, and \
                transcript text goes over the network to Anthropic exactly as it would if you \
                had pasted it into Claude yourself.

                Search, resume, quick tasks, scheduled tasks and loops all work with this off. \
                Changing it takes effect on the next launch.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var general: some View {
        Form {
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))
            if let launchAtLoginError {
                Text(launchAtLoginError).font(.caption).foregroundStyle(.red)
            }
            LabeledContent("Sessions open in", value: TerminalLauncher.preferredTerminalName)
            LabeledContent("Indexed sessions", value: "\(index.totalSessionCount)")
            LabeledContent("Project", value: "\(index.projects.count)")
            Button("Rescan now") { Task { await index.rescan() } }
                .disabled(index.isScanning)
        }
        .formStyle(.grouped)
    }

    private var shortcuts: some View {
        Form {
            KeyboardShortcuts.Recorder("Quick open (global):", name: .quickOpen)
            Text("This shortcut works from anywhere, even with the window closed.")
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
            launchAtLoginError = nil
        } catch {
            // Registration needs the app to live in /Applications and be properly signed. The
            // toggle used to just snap back with no explanation, which reads as a broken switch.
            launchAtLoginError = "Could not set: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
