import AppKit
import QuartzCore
@preconcurrency import SwiftTerm

/// A `LocalProcessTerminalView` that stops burning CPU when nobody is looking.
///
/// SwiftTerm repaints at a fixed ~60fps whenever the PTY produces output
/// (`queuePendingDisplay`, internal, hardcoded `fps60`). A busy claude TUI
/// (spinner + box redraws) therefore kept every visible terminal repainting
/// flat out — the hottest sampled stacks were all `TerminalView.draw` →
/// `drawTerminalContents`.
///
/// The repaint *scheduling* is internal to SwiftTerm, but every repaint funnels
/// through `NSView.setNeedsDisplay(_:)` (open), so this subclass coalesces there:
///
///   - visible + app active   → repaint at `claudeos.terminalFps` (default 15)
///   - visible + app inactive → repaint at most 4 fps
///   - occluded / off-Space / minimized / windowless → repaint suppressed;
///     the dirty region accumulates and flushes once on re-expose.
///
/// The terminal *buffer* keeps updating at full PTY speed — only pixels are
/// deferred, so nothing is ever lost.
///
/// Deliberately overrides only the rect form of `setNeedsDisplay`, which is the
/// one SwiftTerm's hot repaint path funnels through. The occasional
/// `needsDisplay = true` (e.g. a theme change) is left to paint normally.
open class ThrottledTerminalView: LocalProcessTerminalView {
    /// UserDefaults key: visible-and-active repaint cap. 0 or negative → uncapped (60fps).
    public static let fpsDefaultsKey = "claudeos.terminalFps"

    private var pendingRect: NSRect = .null
    private var flushScheduled = false
    private var lastFlush: CFTimeInterval = 0
    private var occluded = false

    // MARK: - Repaint funnel

    open override func setNeedsDisplay(_ invalidRect: NSRect) {
        pendingRect = pendingRect.union(invalidRect)
        if occluded { return }  // accumulate silently; re-expose flushes
        scheduleFlush()
    }

    private var repaintInterval: CFTimeInterval {
        let stored = UserDefaults.standard.object(forKey: Self.fpsDefaultsKey) as? Int
        let fps = stored ?? 15
        guard fps > 0 else { return 1.0 / 60.0 }  // explicit 0 → effectively uncapped
        let active = 1.0 / CFTimeInterval(fps)
        // Backgrounded app: window may still be on screen, but 4fps is plenty.
        return NSApp.isActive ? active : max(active, 0.25)
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        let wait = max(0, (lastFlush + repaintInterval) - CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.flushNow()
        }
    }

    private func flushNow() {
        flushScheduled = false
        guard !occluded, !pendingRect.isNull else { return }
        lastFlush = CACurrentMediaTime()
        let rect = pendingRect
        pendingRect = .null
        super.setNeedsDisplay(rect)
    }

    // MARK: - Occlusion tracking

    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(occlusionChanged(_:)),
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
            applyOcclusion(window.occlusionState.contains(.visible))
        } else {
            occluded = true  // detached (tab switched away): nothing to paint
        }
    }

    @objc private func occlusionChanged(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        applyOcclusion(window.occlusionState.contains(.visible))
    }

    private func applyOcclusion(_ visible: Bool) {
        let nowOccluded = !visible
        guard nowOccluded != occluded else { return }
        occluded = nowOccluded
        if visible {  // re-exposed: repaint whatever changed while hidden, once
            pendingRect = pendingRect.union(bounds)
            scheduleFlush()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
