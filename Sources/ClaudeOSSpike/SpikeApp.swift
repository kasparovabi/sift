import SwiftUI
import AppKit

@main
struct ClaudeOSSpikeApp: App {
    @NSApplicationDelegateAdaptor(SpikeAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Claude OS — Spike (M0)") {
            ContentView()
                .frame(minWidth: 820, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
    }
}

/// A SwiftUI executable launched via `swift run` starts as an accessory process,
/// so its window will not come forward on its own. Promote to a regular app and
/// activate, so the spike window actually appears and can take key focus.
final class SpikeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
