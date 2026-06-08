import SwiftUI
import AppKit

/// Owns one real borderless child NSWindow for an emulated desktop window. Hosts SwiftUI
/// content, drags natively (via TitleBarDragView → performDrag), and clamps to the work
/// area on move so it never covers the Dock / top bar.
@MainActor
final class WindowHostController: NSObject, NSWindowDelegate {
    let id: UUID
    let window: NSWindow
    private weak var parent: NSWindow?
    private weak var manager: DesktopWindowManager?
    private let topInset: CGFloat = 28
    private let bottomInset: CGFloat = 80

    init(id: UUID, parent: NSWindow, hosting: NSView, frame: CGRect, manager: DesktopWindowManager) {
        self.id = id
        self.parent = parent
        self.manager = manager
        window = NSWindow(contentRect: frame, styleMask: [.borderless, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 320, height: 220)
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 11
        hosting.layer?.masksToBounds = true
        window.contentView = hosting
        window.delegate = self
        window.setFrame(frame, display: true)
        parent.addChildWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }

    /// Place using a canvas-space origin/size (top-left, relative to the content area).
    func setCanvasFrame(origin: CGPoint, size: CGSize) {
        guard let cs = contentScreenFrame() else { return }
        window.setFrame(WindowGeometry.screenFrame(canvasOrigin: origin, size: size, contentScreenFrame: cs),
                        display: true)
    }

    func orderFront() {
        if let parent, window.parent == nil { parent.addChildWindow(window, ordered: .above) }
        window.makeKeyAndOrderFront(nil)
        window.order(.above, relativeTo: 0)
    }
    func hide() { window.orderOut(nil) }
    func close() { window.delegate = nil; window.close() }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        clampIntoWorkArea()
        reportCanvasFrame()
    }
    func windowDidResize(_ notification: Notification) { reportCanvasFrame() }
    func windowDidBecomeKey(_ notification: Notification) { manager?.markFocused(id) }

    // MARK: - Helpers

    private func contentScreenFrame() -> CGRect? {
        guard let parent else { return nil }
        return parent.convertToScreen(parent.contentLayoutRect)
    }

    private func clampIntoWorkArea() {
        guard let cs = contentScreenFrame() else { return }
        let canvas = WindowGeometry.canvasOrigin(screenFrame: window.frame, contentScreenFrame: cs)
        let clamped = WindowGeometry.clampToWorkArea(canvasOrigin: canvas, size: window.frame.size,
                                                     contentSize: cs.size, topInset: topInset, bottomInset: bottomInset)
        if abs(clamped.x - canvas.x) > 0.5 || abs(clamped.y - canvas.y) > 0.5 {
            window.setFrame(WindowGeometry.screenFrame(canvasOrigin: clamped, size: window.frame.size,
                                                       contentScreenFrame: cs), display: true)
        }
    }

    private func reportCanvasFrame() {
        guard let cs = contentScreenFrame() else { return }
        let canvas = WindowGeometry.canvasOrigin(screenFrame: window.frame, contentScreenFrame: cs)
        manager?.updateFrame(id, origin: canvas, size: window.frame.size)
    }
}
