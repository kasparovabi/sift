import SwiftUI
import AppKit
import ClaudeOSCore
import ClaudeOSIndex
import ClaudeOSRuntime

/// The Claude OS desktop: a wallpaper, a thin top bar, floating windows (Finder,
/// Dashboard, Settings, and one per terminal session), and a Dock. Terminal
/// windows stay in sync with the runtime's live sessions.
public struct DesktopView: View {
    @Environment(IndexCoordinator.self) private var index
    @Environment(SessionRuntime.self) private var runtime
    @Environment(LiveSessionMonitor.self) private var monitor
    @Environment(DesktopWindowManager.self) private var manager
    @State private var pinnedIcons: [SessionSummary] = []

    public init() {}

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                wallpaper
                    .contextMenu { desktopMenu }
                desktopIcons
                ZStack(alignment: .topLeading) {
                    ForEach(manager.windows.filter { !$0.minimized }) { window in
                        DesktopWindowView(window: window, manager: manager,
                                          isActive: window.z == topWindowZ,
                                          onClose: { close(window) }) {
                            content(for: window)
                        }
                    }
                }
                .padding(.top, 28)
                VStack(spacing: 0) {
                    DesktopTopBar()
                    Spacer()
                    DockView(onNewSession: newFolderSession)
                        .padding(.bottom, 10)
                }
            }
            .ignoresSafeArea()
            .background { WindowChromeHider() }
            .onAppear { manager.canvasSize = geo.size }
            .onChange(of: geo.size) { _, newValue in manager.canvasSize = newValue }
            .task {
                manager.syncTerminals(runtime.sessions)
                await index.initialLoad()
                monitor.start()
                runtime.requestNotificationAuthorization()
                if manager.windows.isEmpty { manager.openFinder() }
            }
            .task(id: index.metaStore.metas.count) {
                pinnedIcons = await index.pinnedSessions()
            }
            .onChange(of: runtime.sessions.map(\.id)) { _, _ in
                manager.syncTerminals(runtime.sessions)
            }
            .onChange(of: runtime.activeSessionId) { _, id in
                if let id, let windowId = manager.terminalWindowId(for: id) {
                    manager.restore(windowId)
                    manager.focus(windowId)
                }
            }
        }
    }

    @ViewBuilder private var desktopIcons: some View {
        if !pinnedIcons.isEmpty {
            VStack(alignment: .center, spacing: 16) {
                ForEach(pinnedIcons.prefix(8)) { session in
                    Button { resume(session) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "pin.circle.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(.orange)
                                .frame(width: 56, height: 56)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13))
                            Text(session.displayTitle)
                                .font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                                .frame(width: 82)
                                .foregroundStyle(.white)
                                .shadow(radius: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Aç: \(session.displayTitle)")
                }
            }
            .padding(.top, 46)
            .padding(.trailing, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    private var topWindowZ: Double? {
        manager.windows.filter { !$0.minimized }.map(\.z).max()
    }

    @ViewBuilder private var desktopMenu: some View {
        Button("Yeni oturum…", systemImage: "plus") { newFolderSession() }
        Button("Finder", systemImage: "macwindow") { manager.openFinder() }
        Button("Genel Bakış", systemImage: "square.grid.2x2") { manager.openDashboard() }
        Button("Pencereleri döşe", systemImage: "rectangle.split.3x3") { manager.tileWindows() }
        Divider()
        Button("Yeniden tara", systemImage: "arrow.clockwise") { Task { await index.rescan() } }
    }

    private var wallpaper: some View {
        ZStack {
            DesktopWallpaper.gradient(manager.wallpaper)
            RadialGradient(
                colors: [Color.orange.opacity(0.14), .clear],
                center: .bottomTrailing, startRadius: 40, endRadius: 700
            )
        }
        .ignoresSafeArea()
    }

    @ViewBuilder private func content(for window: DesktopWindowManager.DesktopWindow) -> some View {
        switch window.kind {
        case .finder:
            FinderView()
        case .dashboard:
            DashboardView(onResume: resume, onNewFolder: newFolderSession)
        case .settings:
            SettingsView()
        case .terminal(let id):
            if let session = runtime.sessions.first(where: { $0.id == id }) {
                TerminalEmulatorView(session: session)
            } else {
                Color.black
            }
        }
    }

    private func close(_ window: DesktopWindowManager.DesktopWindow) {
        if case .terminal(let id) = window.kind,
           let session = runtime.sessions.first(where: { $0.id == id }) {
            runtime.close(session)
        }
        manager.close(window.id)
    }

    private func resume(_ session: SessionSummary) {
        Task {
            try? await runtime.launch(SessionLaunchRequest(
                mode: .resume(sessionId: session.sessionId),
                cwd: session.cwd ?? NSHomeDirectory(),
                projectId: session.projectId,
                gitBranch: session.gitBranch,
                title: session.displayTitle
            ))
        }
    }

    private func newFolderSession() {
        guard let url = chooseClaudeDirectory() else { return }
        Task {
            try? await runtime.launch(SessionLaunchRequest(
                mode: .fresh, cwd: url.path, projectId: "", title: url.lastPathComponent
            ))
        }
    }
}

enum DesktopWallpaper {
    static let presets: [(name: String, colors: [Color])] = [
        ("Gece", [Color(red: 0.10, green: 0.12, blue: 0.20), Color(red: 0.03, green: 0.04, blue: 0.08)]),
        ("Okyanus", [Color(red: 0.05, green: 0.13, blue: 0.21), Color(red: 0.01, green: 0.05, blue: 0.11)]),
        ("Orman", [Color(red: 0.07, green: 0.14, blue: 0.11), Color(red: 0.02, green: 0.06, blue: 0.05)]),
        ("Mor", [Color(red: 0.15, green: 0.10, blue: 0.23), Color(red: 0.05, green: 0.03, blue: 0.11)]),
        ("Kömür", [Color(red: 0.13, green: 0.13, blue: 0.14), Color(red: 0.04, green: 0.04, blue: 0.05)]),
    ]

    static func gradient(_ index: Int) -> LinearGradient {
        let preset = presets[min(max(0, index), presets.count - 1)]
        return LinearGradient(colors: preset.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct DesktopTopBar: View {
    @Environment(SessionRuntime.self) private var runtime
    @Environment(LiveSessionMonitor.self) private var monitor

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal.fill")
            Text("Claude OS").fontWeight(.semibold)
            Spacer()
            if liveCount > 0 {
                Label("\(liveCount) canlı", systemImage: "bolt.fill").foregroundStyle(.green)
            }
            Text("⌘K").foregroundStyle(.secondary)
            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.weekday().hour().minute())
            }
        }
        .font(.caption)
        .padding(.leading, 78)
        .padding(.trailing, 14)
        .frame(height: 28)
        .background(.ultraThinMaterial)
    }

    private var liveCount: Int {
        monitor.liveSessionIds.union(runtime.liveSessionIds).count
    }
}

/// Hides the host macOS window's real traffic lights so the desktop is immersive
/// (each emulated window has its own controls). Quit via ⌘Q / menubar.
private final class ChromeHidingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
    }
}

private struct WindowChromeHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeHidingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
