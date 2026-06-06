import SwiftUI
import ClaudeOSRuntime

/// Manages the floating windows on the Claude OS desktop: system windows (Finder,
/// Dashboard, Settings) plus one window per live terminal session, kept in sync
/// with the runtime. Holds each window's frame and z-order so windows can be
/// dragged, resized, layered, minimized, and focused.
@MainActor
@Observable
public final class DesktopWindowManager {
    public enum Kind: Equatable {
        case finder
        case dashboard
        case settings
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

    public init() {}

    public func setWallpaper(_ index: Int) {
        wallpaper = index
        UserDefaults.standard.set(index, forKey: "claudeos.wallpaper")
    }

    // MARK: - Opening

    public func openFinder() { openSystem(.finder, "Finder", CGSize(width: 880, height: 560)) }
    public func openDashboard() { openSystem(.dashboard, "Genel Bakış", CGSize(width: 700, height: 540)) }
    public func openSettings() { openSystem(.settings, "Ayarlar", CGSize(width: 520, height: 340)) }

    private func openSystem(_ kind: Kind, _ title: String, _ size: CGSize) {
        if let existing = windows.first(where: { $0.kind == kind }) {
            restore(existing.id)
            focus(existing.id)
            return
        }
        windows.append(DesktopWindow(id: UUID(), kind: kind, title: title,
                                     origin: nextOrigin(), size: size, z: nextZ(), minimized: false))
    }

    // MARK: - Terminal sync

    /// Ensure there is exactly one window per live runtime session.
    public func syncTerminals(_ sessions: [TerminalSession]) {
        let liveIds = Set(sessions.map(\.id))
        // Drop windows whose session ended.
        windows.removeAll { window in
            if case .terminal(let id) = window.kind { return !liveIds.contains(id) }
            return false
        }
        // Open windows for new sessions.
        for session in sessions where !hasWindow(for: session.id) {
            windows.append(DesktopWindow(
                id: UUID(), kind: .terminal(session.id), title: session.title,
                origin: nextOrigin(), size: CGSize(width: 760, height: 460), z: nextZ(), minimized: false
            ))
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

    // MARK: - Window operations

    public func focus(_ id: UUID) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        windows[index].z = nextZ()
    }

    public func close(_ id: UUID) {
        windows.removeAll { $0.id == id }
    }

    public func minimize(_ id: UUID) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        windows[index].minimized = true
    }

    public func restore(_ id: UUID) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        windows[index].minimized = false
        windows[index].z = nextZ()
    }

    public func toggleMinimize(_ id: UUID) {
        guard let window = windows.first(where: { $0.id == id }) else { return }
        if window.minimized { restore(id) } else { minimize(id) }
    }

    public func move(_ id: UUID, to origin: CGPoint) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        windows[index].origin = origin
    }

    public func resize(_ id: UUID, to size: CGSize) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        windows[index].size = CGSize(width: max(320, size.width), height: max(220, size.height))
    }

    /// Toggle a window between filling the desktop and its previous frame.
    public func zoom(_ id: UUID) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        if let restore = windows[index].restoreFrame {
            windows[index].origin = restore.origin
            windows[index].size = restore.size
            windows[index].restoreFrame = nil
        } else {
            windows[index].restoreFrame = CGRect(origin: windows[index].origin, size: windows[index].size)
            windows[index].origin = CGPoint(x: 12, y: 8)
            windows[index].size = CGSize(
                width: max(420, canvasSize.width - 24),
                height: max(300, canvasSize.height - 24 - 90)  // room for top bar + dock
            )
        }
        windows[index].z = nextZ()
    }

    // MARK: - Snap & tile

    public enum SnapEdge { case left, right, top }

    private var workArea: (top: CGFloat, height: CGFloat) {
        (30, max(200, canvasSize.height - 30 - 80))  // below top bar, above dock
    }

    public func snap(_ id: UUID, _ edge: SnapEdge) {
        guard let index = windows.firstIndex(where: { $0.id == id }), canvasSize != .zero else { return }
        let area = workArea
        windows[index].restoreFrame = nil
        switch edge {
        case .left:
            windows[index].origin = CGPoint(x: 0, y: area.top)
            windows[index].size = CGSize(width: canvasSize.width / 2, height: area.height)
        case .right:
            windows[index].origin = CGPoint(x: canvasSize.width / 2, y: area.top)
            windows[index].size = CGSize(width: canvasSize.width / 2, height: area.height)
        case .top:
            windows[index].origin = CGPoint(x: 12, y: area.top - 22)
            windows[index].size = CGSize(width: max(420, canvasSize.width - 24), height: area.height + 22)
        }
        windows[index].z = nextZ()
    }

    /// Arrange all non-minimized windows in a grid.
    public func tileWindows() {
        let indices = windows.indices.filter { !windows[$0].minimized }
        guard !indices.isEmpty, canvasSize != .zero else { return }
        let count = indices.count
        let cols = Int(ceil(Double(count).squareRoot()))
        let rows = Int(ceil(Double(count) / Double(cols)))
        let area = workArea
        let gap: CGFloat = 8
        let w = (canvasSize.width - gap * CGFloat(cols + 1)) / CGFloat(cols)
        let h = (area.height - gap * CGFloat(rows + 1)) / CGFloat(rows)
        for (slot, windowIndex) in indices.enumerated() {
            let row = slot / cols, col = slot % cols
            windows[windowIndex].origin = CGPoint(x: gap + CGFloat(col) * (w + gap),
                                                  y: area.top + gap + CGFloat(row) * (h + gap))
            windows[windowIndex].size = CGSize(width: w, height: h)
            windows[windowIndex].restoreFrame = nil
        }
    }

    // MARK: - Placement

    private func nextZ() -> Double {
        topZ += 1
        return topZ
    }

    private func nextOrigin() -> CGPoint {
        let step = CGFloat(cascade % 6) * 34
        cascade += 1
        return CGPoint(x: 80 + step, y: 70 + step)
    }
}
