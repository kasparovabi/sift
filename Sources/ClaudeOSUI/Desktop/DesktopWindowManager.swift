import SwiftUI
import AppKit
import ClaudeOSRuntime

/// Manages the emulated desktop windows. Each window is a real borderless child
/// `NSWindow` (owned by a `WindowHostController`) so it drags/resizes/composites via the
/// WindowServer (no SwiftUI `.offset` flicker). This type holds the logical window list
/// (for the Dock + lifecycle) and routes open/close/focus/minimize/snap/tile/zoom to the
/// NSWindows. The host NSWindow + content builder are supplied by `DesktopView.attach`.
@MainActor
@Observable
public final class DesktopWindowManager {
    public enum Kind: Equatable {
        case finder
        case dashboard
        case settings
        case brain
        case terminal(TerminalSession.ID)
    }

    public struct DesktopWindow: Identifiable {
        public let id: UUID
        public var kind: Kind
        public var title: String
        public var origin: CGPoint
        public var size: CGSize
        public var z: Double
        public var minimized: Bool
        public var restoreFrame: CGRect? = nil   // set while maximized, to un-maximize
    }

    public private(set) var windows: [DesktopWindow] = []
    public var wallpaper: Int = max(0, UserDefaults.standard.integer(forKey: "claudeos.wallpaper"))
    @ObservationIgnored public var canvasSize: CGSize = .zero
    @ObservationIgnored private var topZ: Double = 0
    @ObservationIgnored private var cascade: Int = 0

    @ObservationIgnored private var controllers: [UUID: WindowHostController] = [:]
    @ObservationIgnored private weak var parentWindow: NSWindow?
    @ObservationIgnored private var makeContent: ((DesktopWindow) -> NSView)?

    public init() {}

    public func setWallpaper(_ index: Int) {
        wallpaper = index
        UserDefaults.standard.set(index, forKey: "claudeos.wallpaper")
    }

    // MARK: - Attach (called once by DesktopView when the host NSWindow exists)

    /// `makeContent` builds the SwiftUI content (with environment) wrapped in an
    /// NSHostingView for a logical window.
    public func attach(parentWindow: NSWindow, makeContent: @escaping (DesktopWindow) -> NSView) {
        self.parentWindow = parentWindow
        self.makeContent = makeContent
        for window in windows where controllers[window.id] == nil { materialize(window) }
    }

    private func materialize(_ window: DesktopWindow) {
        guard let parent = parentWindow, let make = makeContent, controllers[window.id] == nil else { return }
        let cs = parent.convertToScreen(parent.contentLayoutRect)
        let frame = WindowGeometry.screenFrame(canvasOrigin: window.origin, size: window.size, contentScreenFrame: cs)
        controllers[window.id] = WindowHostController(id: window.id, parent: parent,
                                                      hosting: make(window), frame: frame, manager: self)
    }

    // MARK: - Opening

    public func openFinder() { openSystem(.finder, "Finder", CGSize(width: 880, height: 560)) }
    public func openDashboard() { openSystem(.dashboard, "Genel Bakış", CGSize(width: 700, height: 540)) }
    public func openSettings() { openSystem(.settings, "Ayarlar", CGSize(width: 520, height: 360)) }
    public func openBrain() { openSystem(.brain, "Beyin", CGSize(width: 820, height: 560)) }

    private func openSystem(_ kind: Kind, _ title: String, _ size: CGSize) {
        if let existing = windows.first(where: { $0.kind == kind }) {
            restore(existing.id)
            focus(existing.id)
            return
        }
        let window = DesktopWindow(id: UUID(), kind: kind, title: title,
                                   origin: nextOrigin(), size: size, z: nextZ(), minimized: false)
        windows.append(window)
        materialize(window)
    }

    // MARK: - Terminal sync

    public func syncTerminals(_ sessions: [TerminalSession]) {
        let liveIds = Set(sessions.map(\.id))
        // Drop windows whose session ended (and their NSWindow).
        for window in windows where window.isTerminal && !liveIds.contains(window.terminalId!) {
            controllers[window.id]?.close()
            controllers[window.id] = nil
        }
        windows.removeAll { $0.isTerminal && !liveIds.contains($0.terminalId!) }
        // Open windows for new sessions.
        for session in sessions where !hasWindow(for: session.id) {
            let window = DesktopWindow(id: UUID(), kind: .terminal(session.id), title: session.title,
                                       origin: nextOrigin(), size: CGSize(width: 760, height: 460),
                                       z: nextZ(), minimized: false)
            windows.append(window)
            materialize(window)
        }
        // Refresh titles.
        for index in windows.indices {
            if case .terminal(let id) = windows[index].kind,
               let session = sessions.first(where: { $0.id == id }) {
                windows[index].title = session.title
            }
        }
    }

    private func hasWindow(for sessionId: TerminalSession.ID) -> Bool {
        windows.contains { $0.kind == .terminal(sessionId) }
    }

    public func terminalWindowId(for sessionId: TerminalSession.ID) -> UUID? {
        windows.first { $0.kind == .terminal(sessionId) }?.id
    }

    // MARK: - Window operations (routed to the NSWindow)

    public func focus(_ id: UUID) { controllers[id]?.orderFront() }

    public func close(_ id: UUID) {
        controllers[id]?.close()
        controllers[id] = nil
        windows.removeAll { $0.id == id }
    }

    public func minimize(_ id: UUID) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        windows[index].minimized = true
        controllers[id]?.hide()
    }

    public func restore(_ id: UUID) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        windows[index].minimized = false
        controllers[id]?.orderFront()
        windows[index].z = nextZ()
    }

    public func toggleMinimize(_ id: UUID) {
        guard let window = windows.first(where: { $0.id == id }) else { return }
        if window.minimized { restore(id) } else { minimize(id) }
    }

    /// Called by the host controller after a native move/resize: update logical frame.
    public func updateFrame(_ id: UUID, origin: CGPoint, size: CGSize) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        windows[index].origin = origin
        windows[index].size = size
        windows[index].restoreFrame = nil
    }

    /// Called by the host controller when its NSWindow becomes key.
    public func markFocused(_ id: UUID) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        windows[index].z = nextZ()
    }

    /// Set a window's frame (canvas coords) and move the NSWindow to match.
    private func setCanvasFrame(_ id: UUID, origin: CGPoint, size: CGSize) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        windows[index].origin = origin
        windows[index].size = size
        controllers[id]?.setCanvasFrame(origin: origin, size: size)
        windows[index].z = nextZ()
    }

    /// Toggle a window between filling the work area and its previous frame.
    public func zoom(_ id: UUID) {
        guard let index = windows.firstIndex(where: { $0.id == id }), canvasSize != .zero else { return }
        if let restore = windows[index].restoreFrame {
            windows[index].restoreFrame = nil
            setCanvasFrame(id, origin: restore.origin, size: restore.size)
        } else {
            windows[index].restoreFrame = CGRect(origin: windows[index].origin, size: windows[index].size)
            let area = workArea
            setCanvasFrame(id, origin: CGPoint(x: 12, y: area.top),
                           size: CGSize(width: max(420, canvasSize.width - 24), height: area.height))
        }
    }

    // MARK: - Snap & tile

    public enum SnapEdge { case left, right, top }

    private var workArea: (top: CGFloat, height: CGFloat) {
        (28, max(200, canvasSize.height - 28 - 80))  // below top bar (28), above dock (80)
    }

    public func snap(_ id: UUID, _ edge: SnapEdge) {
        guard let index = windows.firstIndex(where: { $0.id == id }), canvasSize != .zero else { return }
        if windows[index].restoreFrame == nil {
            windows[index].restoreFrame = CGRect(origin: windows[index].origin, size: windows[index].size)
        }
        let area = workArea
        switch edge {
        case .left:
            setCanvasFrame(id, origin: CGPoint(x: 0, y: area.top), size: CGSize(width: canvasSize.width / 2, height: area.height))
        case .right:
            setCanvasFrame(id, origin: CGPoint(x: canvasSize.width / 2, y: area.top), size: CGSize(width: canvasSize.width / 2, height: area.height))
        case .top:
            setCanvasFrame(id, origin: CGPoint(x: 12, y: area.top), size: CGSize(width: max(420, canvasSize.width - 24), height: area.height))
        }
    }

    /// Arrange all non-minimized windows in a grid.
    public func tileWindows() {
        let ids = windows.filter { !$0.minimized }.map(\.id)
        guard !ids.isEmpty, canvasSize != .zero else { return }
        let count = ids.count
        let cols = Int(ceil(Double(count).squareRoot()))
        let rows = Int(ceil(Double(count) / Double(cols)))
        let area = workArea
        let gap: CGFloat = 8
        let w = (canvasSize.width - gap * CGFloat(cols + 1)) / CGFloat(cols)
        let h = (area.height - gap * CGFloat(rows + 1)) / CGFloat(rows)
        for (slot, id) in ids.enumerated() {
            let row = slot / cols, col = slot % cols
            setCanvasFrame(id, origin: CGPoint(x: gap + CGFloat(col) * (w + gap),
                                               y: area.top + gap + CGFloat(row) * (h + gap)),
                           size: CGSize(width: w, height: h))
        }
    }

    // MARK: - Placement

    private func nextZ() -> Double { topZ += 1; return topZ }

    private func nextOrigin() -> CGPoint {
        let step = CGFloat(cascade % 6) * 34
        cascade += 1
        return CGPoint(x: 80 + step, y: 70 + step)
    }
}

private extension DesktopWindowManager.DesktopWindow {
    var isTerminal: Bool { if case .terminal = kind { return true }; return false }
    var terminalId: TerminalSession.ID? { if case .terminal(let id) = kind { return id }; return nil }
}
