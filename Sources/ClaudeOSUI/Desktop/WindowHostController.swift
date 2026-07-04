import SwiftUI
import AppKit
import ClaudeOSRuntime

/// A borderless window that still accepts key status. Plain borderless `NSWindow`s return
/// `false` from `canBecomeKey`/`canBecomeMain`, which starves embedded terminals and text
/// fields of all keyboard input (arrow keys, typing — everything). Opting back in is what
/// lets a resumed session's terminal actually receive keystrokes.
final class EmulatedWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Intercept scroll before it reaches the view tree so a terminal in the alternate screen
    /// buffer (claude, vim, less…) scrolls via translated arrow keys. SwiftTerm's `scrollWheel`
    /// is `public`, not `open`, so this window-level hook is how we add Ghostty-style alternate
    /// scroll without subclassing the terminal view. Non-terminal windows and normal-buffer
    /// terminals fall through to default handling untouched.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, WastelandScroll.handleAltScroll(event, in: self) { return }
        // Drop bare hover while a terminal app (claude prompts) is in any-event mouse tracking,
        // so passing the cursor over an option doesn't move its highlight / pick it by accident.
        if event.type == .mouseMoved, WastelandScroll.suppressesHover(event, in: self) { return }
        super.sendEvent(event)
    }
}

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
        window = EmulatedWindow(contentRect: frame, styleMask: [.borderless, .resizable],
                                backing: .buffered, defer: false)
        super.init()
        // We own the window via a strong ref and release it ourselves when the controller
        // is dropped. Without this, close() also auto-releases it (default true) → the
        // window is over-released → heap corruption → crash on the next autorelease drain.
        window.isReleasedWhenClosed = false
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
        // raiseAboveSiblings re-attaches as a child on top first, so makeKey never surfaces a
        // detached window (hide() via orderOut detaches it) as a standalone top-level.
        raiseAboveSiblings()
        window.makeKeyAndOrderFront(nil)
    }
    func hide() { window.orderOut(nil) }
    func close() { window.delegate = nil; window.close() }

    /// Physically restack this child window above its siblings. A child keeps the order it was
    /// added to its parent's `childWindows` list, and that list overrides `order(.above:)` — so
    /// the only reliable way to raise one is to detach and re-add it on top. markFocused already
    /// moved the active highlight; this is what makes a clicked/occluded window actually rise.
    private func raiseAboveSiblings() {
        guard let parent else { return }
        if window.parent != nil { parent.removeChildWindow(window) }
        parent.addChildWindow(window, ordered: .above)
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        clampIntoWorkArea()
        reportCanvasFrame()
    }
    func windowDidResize(_ notification: Notification) { reportCanvasFrame() }
    func windowDidBecomeKey(_ notification: Notification) {
        manager?.markFocused(id)
        // A plain click on a background window's body makes it key but, being a child window,
        // leaves it physically behind its siblings. Restack it so click-to-front works.
        raiseAboveSiblings()
        // Hand keyboard focus to the embedded terminal (if any) once the window is key, so
        // arrows and typing go straight to the PTY. Deferred a tick so SwiftUI has laid out
        // the hosted view. No-op for Finder/Dashboard/Brain/Settings windows.
        DispatchQueue.main.async { [weak self] in self?.focusTerminalIfPresent() }
    }

    private func focusTerminalIfPresent() {
        guard let target = Self.findTerminalView(in: window.contentView) else { return }
        window.makeFirstResponder(target)
    }

    private static func findTerminalView(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view.identifier?.rawValue == "claudeos.terminal" { return view }
        for sub in view.subviews {
            if let found = findTerminalView(in: sub) { return found }
        }
        return nil
    }

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
