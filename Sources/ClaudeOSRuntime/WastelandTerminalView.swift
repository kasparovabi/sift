import AppKit
@preconcurrency import SwiftTerm

/// Scroll-wheel forwarding for embedded terminals, matching Ghostty / iTerm / xterm.
///
/// SwiftTerm's own `scrollWheel` only ever moves its scrollback buffer. That's wrong for two
/// common cases that `claude` hits at once:
///   1. It enables full mouse reporting (`1000/1002/1003h` + SGR `1006h`), so it wants the wheel
///      delivered as mouse-wheel events (button 64 up / 65 down) and scrolls its own transcript
///      from those. SwiftTerm never sends them, so the wheel did nothing.
///   2. It runs in the alternate screen buffer, which has no scrollback to move anyway.
///
/// SwiftTerm declares `scrollWheel` as `public` (not `open`), so we can't subclass it; instead the
/// host `NSWindow` calls this from `sendEvent(_:)`, before the event reaches the view.
public enum WastelandScroll {
    /// Handle a scroll event for the terminal under the cursor. Returns `true` if consumed.
    /// Order matches real terminals: mouse reporting wins, then alternate-scroll (arrow keys for
    /// apps that don't report mouse), otherwise `false` to let SwiftTerm scroll its scrollback.
    @MainActor public static func handleAltScroll(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.type == .scrollWheel, event.deltaY != 0,
              let view = terminalView(at: event.locationInWindow, in: window) else { return false }
        let term = view.getTerminal()
        let up = event.deltaY > 0
        // Trackpad ticks arrive in a rapid stream, so one step each reads as smooth; a mouse
        // notch carries a bigger delta, so scale it but cap so one notch can't fling the view.
        let steps = event.hasPreciseScrollingDeltas ? 1 : min(max(1, Int(abs(event.deltaY))), 5)

        if view.allowMouseReporting && term.mouseMode != .off {
            let (col, row) = cell(of: event, in: view, cols: term.cols, rows: term.rows)
            let button = up ? 64 : 65   // xterm wheel-up / wheel-down button codes
            for _ in 0..<steps { term.sendEvent(buttonFlags: button, x: col, y: row) }
            return true
        }

        if term.isCurrentBufferAlternate {
            let seq = up
                ? (term.applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal)
                : (term.applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal)
            for _ in 0..<steps { view.send(seq) }
            return true
        }

        return false   // normal buffer, no mouse reporting → SwiftTerm scrollback is correct
    }

    /// Approximate the terminal cell under the event. The view is unflipped (origin bottom-left),
    /// so row counts from the top as `(height - y)`. Position only labels where the wheel turned;
    /// the scroll direction comes from the button code, so an off-by-one cell is harmless.
    @MainActor private static func cell(of event: NSEvent, in view: NSView, cols: Int, rows: Int) -> (Int, Int) {
        let p = view.convert(event.locationInWindow, from: nil)
        let b = view.bounds
        let col = min(max(0, Int(p.x / max(1, b.width) * CGFloat(cols))), max(0, cols - 1))
        let row = min(max(0, Int((b.height - p.y) / max(1, b.height) * CGFloat(rows))), max(0, rows - 1))
        return (col, row)
    }

    /// Claude's selection prompts switch on "any-event" mouse tracking (1003), so SwiftTerm reports
    /// every hover as motion and the TUI slides its highlight onto whatever the cursor passes over —
    /// a pick the user never clicked. Returns `true` to drop a bare hover (no Command, which still
    /// previews links) while that mode is active; clicks, the wheel, and drags are left alone.
    @MainActor public static func suppressesHover(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.type == .mouseMoved,
              !event.modifierFlags.contains(.command),
              let view = terminalView(at: event.locationInWindow, in: window) else { return false }
        return view.allowMouseReporting && view.getTerminal().mouseMode == .anyEvent
    }

    @MainActor private static func terminalView(at point: NSPoint, in window: NSWindow) -> LocalProcessTerminalView? {
        var view = window.contentView?.hitTest(point)
        while let current = view, !(current is LocalProcessTerminalView) { view = current.superview }
        return view as? LocalProcessTerminalView
    }
}
