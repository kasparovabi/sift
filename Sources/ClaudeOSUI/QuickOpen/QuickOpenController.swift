import AppKit
import SwiftUI
import Observation
import KeyboardShortcuts
import ClaudeOSIndex
import ClaudeOSRuntime

/// Owns the floating Spotlight-style quick-open panel and the global hotkey that
/// summons it. The panel hosts a SwiftUI search view over all sessions.
@MainActor
@Observable
public final class QuickOpenController {
    @ObservationIgnored private let index: IndexCoordinator
    @ObservationIgnored private let runtime: SessionRuntime
    @ObservationIgnored private var panel: NSPanel?

    /// Set by the UI so the panel can bring the main session window forward after a resume.
    @ObservationIgnored public var openSessionWindow: (() -> Void)?

    public init(index: IndexCoordinator, runtime: SessionRuntime) {
        self.index = index
        self.runtime = runtime
    }

    public func registerHotkey() {
        KeyboardShortcuts.onKeyUp(for: .quickOpen) { [weak self] in
            self?.toggle()
        }
    }

    public func toggle() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
        } else {
            show()
        }
    }

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        if let screen = NSScreen.main {
            let size = panel.frame.size
            let origin = NSPoint(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.midY - size.height / 2 + 120
            )
            panel.setFrameOrigin(origin)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func dismiss() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let view = QuickOpenView(
            index: index,
            runtime: runtime,
            onResume: { [weak self] in
                self?.dismiss()
                self?.openSessionWindow?()
            },
            onClose: { [weak self] in self?.dismiss() }
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 440),
            styleMask: [.titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = NSHostingController(rootView: view)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setContentSize(NSSize(width: 660, height: 440))
        return panel
    }
}
