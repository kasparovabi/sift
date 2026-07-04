import SwiftUI
import AppKit
import CoreImage
import ClaudeOSCore
import ClaudeOSIndex
import ClaudeOSRuntime
import ClaudeOSBrain

/// Make a layer-backed NSView's bright phosphor pixels glow with a tight Core Image bloom.
/// `layerUsesCoreImageFilters` is required for AppKit to honour Core Image layer filters,
/// and needs no Metal toolchain. Applied to the desktop host and each emulated window so the
/// whole UI reads like a glowing CRT tube, not flat neon.
@MainActor func applyPhosphorBloom(to view: NSView, radius: Double = 2.4, intensity: Double = 0.85) {
    view.wantsLayer = true
    view.layerUsesCoreImageFilters = true
    guard let bloom = CIFilter(name: "CIBloom") else { return }
    bloom.setValue(radius, forKey: "inputRadius")
    bloom.setValue(intensity, forKey: "inputIntensity")
    view.layer?.filters = [bloom]
}

/// The Claude OS desktop: a wallpaper, a thin top bar, floating windows (Finder,
/// Dashboard, Settings, and one per terminal session), and a Dock. Terminal
/// windows stay in sync with the runtime's live sessions.
public struct DesktopView: View {
    @Environment(IndexCoordinator.self) private var index
    @Environment(SessionRuntime.self) private var runtime
    @Environment(LiveSessionMonitor.self) private var monitor
    @Environment(DesktopWindowManager.self) private var manager
    @Environment(BrainViewModel.self) private var brainVM
    @Environment(ToastCenter.self) private var toasts
    @State private var pinnedIcons: [SessionSummary] = []
    @State private var attached = false
    @State private var greeted = false

    public init() {}

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                wallpaper
                    .contextMenu { desktopMenu }
                desktopIcons
                desktopNotes
                VStack(spacing: 0) {
                    DesktopTopBar()
                    Spacer()
                    DockView(onNewSession: newFolderSession)
                        .padding(.bottom, 10)
                }
            }
            .ignoresSafeArea()
            .crtPhosphor()
            .background { WindowChromeHider() }
            .background { WindowAttacher { attachIfNeeded($0) } }
            .onAppear { manager.canvasSize = geo.size; manager.clampAllNotes() }
            .onChange(of: geo.size) { _, newValue in manager.canvasSize = newValue; manager.clampAllNotes() }
            .task {
                manager.syncTerminals(runtime.sessions)
                await index.initialLoad()
                monitor.start()
                runtime.requestNotificationAuthorization()
                if manager.windows.isEmpty { manager.openFinder() }
                if ProcessInfo.processInfo.environment["CLAUDEOS_OPEN_BRAIN"] == "1" { manager.openBrain() }
                if !greeted {
                    greeted = true
                    toasts.post("Hoş geldin · \(index.totalSessionCount) oturum, \(index.projects.count) proje",
                                icon: "sparkles", tint: .accentColor, duration: 6)
                }
            }
            .task(id: index.metaStore.metas.mapValues(\.pinned)) {
                pinnedIcons = await index.pinnedSessions()
            }
            .onChange(of: runtime.sessions.map { "\($0.id):\($0.title)" }) { _, _ in
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

    /// Notes float on the wallpaper, behind every window (they live in the host window's
    /// SwiftUI, which composites under the child NSWindows). `.position` places each by its
    /// stored centre; the card shifts itself with `.offset` while dragging.
    @ViewBuilder private var desktopNotes: some View {
        ForEach(manager.stickyNotes) { note in
            StickyNoteView(note: note, manager: manager)
                .position(x: note.x, y: note.y)
        }
    }

    @ViewBuilder private var desktopMenu: some View {
        Button("Not ekle", systemImage: "note.text") { manager.addStickyNote() }
        Button("Yeni oturum…", systemImage: "plus") { newFolderSession() }
        Button("Finder", systemImage: "macwindow") { manager.openFinder() }
        Button("Genel Bakış", systemImage: "square.grid.2x2") { manager.openDashboard() }
        Button("Beyin", systemImage: "brain") { manager.openBrain() }
        Button("Döngü", systemImage: "arrow.triangle.2.circlepath") { manager.openLoop() }
        Button("Pencereleri döşe", systemImage: "rectangle.split.3x3") { manager.tileWindows() }
        Divider()
        Button("Yeniden tara", systemImage: "arrow.clockwise") {
            Task {
                await index.rescan()
                toasts.post("Tarama bitti · \(index.totalSessionCount) oturum",
                            icon: "checkmark.circle.fill", tint: .green)
            }
        }
    }

    private var wallpaper: some View {
        // The desktop reads as a glowing CRT surface: a dark olive tube, radioactive light
        // pooling in the corners (the Settings preset picks the colours), a faint neon grid
        // that blooms under the desktop's Core Image filter, scanlines, and a tube vignette.
        let glows = DesktopWallpaper.glows(manager.wallpaper)
        return ZStack {
            Wasteland.base
            RadialGradient(colors: [glows[0].opacity(0.24), .clear],
                           center: .topLeading, startRadius: 30, endRadius: 800)
            RadialGradient(colors: [glows[1].opacity(0.17), .clear],
                           center: .bottomTrailing, startRadius: 30, endRadius: 900)
            RadialGradient(colors: [glows[2].opacity(0.11), .clear],
                           center: .center, startRadius: 60, endRadius: 660)
            WastelandGrid(spacing: 46).opacity(0.05)
            WastelandArt().frame(maxWidth: .infinity, maxHeight: .infinity)
            Scanlines(gap: 3, opacity: 0.18)
            RadialGradient(colors: [.clear, Color.black.opacity(0.5)],
                           center: .center, startRadius: 220, endRadius: 1160)
        }
        .ignoresSafeArea()
    }

    /// Wire the manager to the host NSWindow once it exists. Each emulated window then
    /// becomes a real child NSWindow hosting `WindowContent`.
    private func attachIfNeeded(_ window: NSWindow) {
        guard !attached else { return }
        attached = true
        // Capture environment objects now (valid during a view update); the content
        // builder may run later (when a session opens) when @Environment on `self` wouldn't be.
        let index = self.index, runtime = self.runtime, monitor = self.monitor
        let manager = self.manager, brainVM = self.brainVM
        manager.attach(parentWindow: window) { logical in
            let host = NSHostingView(rootView: WindowContent(window: logical, manager: manager, index: index,
                                                             runtime: runtime, monitor: monitor, brainVM: brainVM))
            applyPhosphorBloom(to: host)
            return host
        }
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

/// SwiftUI root hosted inside each emulated window's NSWindow. Holds explicit
/// dependencies (not @Environment) so it stays valid when the manager builds it lazily.
private struct WindowContent: View {
    let window: DesktopWindowManager.DesktopWindow
    let manager: DesktopWindowManager
    let index: IndexCoordinator
    let runtime: SessionRuntime
    let monitor: LiveSessionMonitor
    let brainVM: BrainViewModel

    var body: some View {
        windowBody
            .environment(index)
            .environment(runtime)
            .environment(monitor)
            .environment(manager)
            .environment(brainVM)
    }

    /// Non-terminal windows get the CRT scanline + vignette veneer over their chrome. Terminal
    /// windows are deliberately left without it: the SwiftUI overlay sits over the live
    /// SwiftTerm NSView and swallows its scroll-wheel events. The terminal still glows via the
    /// Core Image bloom on its window layer (which is event-transparent, so scroll keeps working).
    @ViewBuilder private var windowBody: some View {
        let chrome = DesktopWindowView(window: window, manager: manager, onClose: closeSelf) { inner }
        if case .terminal = window.kind {
            chrome
        } else {
            chrome.crtPhosphor()
        }
    }

    @ViewBuilder private var inner: some View {
        switch window.kind {
        case .finder:    FinderView()
        case .dashboard: DashboardView(onResume: resume, onNewFolder: newFolder)
        case .settings:  SettingsView()
        case .brain:     BrainView()
        case .quickTask: QuickTaskView()
        case .scheduled: ScheduledTasksView()
        case .loop: LoopTasksView()
        case .focusTimer: FocusTimerView()
        case .folders: FoldersView()
        case .terminal(let id):
            if let session = runtime.sessions.first(where: { $0.id == id }) {
                // A restored session is dormant until first focus. Show a clear "resume" prompt
                // instead of a blank PTY; tapping starts it (claude --resume) and the live view
                // swaps in as soon as state flips to .running (session is @Observable).
                if session.state == .dormant {
                    DormantTerminalView(title: session.title) { runtime.focus(session) }
                } else {
                    TerminalEmulatorView(session: session)
                }
            } else {
                Color.black
            }
        }
    }

    private func closeSelf() {
        if case .terminal(let id) = window.kind,
           let session = runtime.sessions.first(where: { $0.id == id }) {
            runtime.close(session)
        }
        manager.close(window.id)
    }

    private func resume(_ session: SessionSummary) {
        Task {
            try? await runtime.launch(SessionLaunchRequest(
                mode: .resume(sessionId: session.sessionId), cwd: session.cwd ?? NSHomeDirectory(),
                projectId: session.projectId, gitBranch: session.gitBranch, title: session.displayTitle))
        }
    }

    private func newFolder() {
        guard let url = chooseClaudeDirectory() else { return }
        Task {
            try? await runtime.launch(SessionLaunchRequest(
                mode: .fresh, cwd: url.path, projectId: "", title: url.lastPathComponent))
        }
    }
}

/// Captures the host NSWindow so the manager can parent child windows to it.
private struct WindowAttacher: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView { AttachView(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? AttachView)?.onWindow = onWindow }
    final class AttachView: NSView {
        var onWindow: (NSWindow) -> Void
        init(onWindow: @escaping (NSWindow) -> Void) { self.onWindow = onWindow; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window { onWindow(w) }
        }
    }
}

enum DesktopWallpaper {
    /// Each preset is a trio of neon glow colours that bleed in over the shared olive base.
    /// The base (Wasteland.base) always dominates so windows stay readable; the glows give
    /// each preset its radioactive tint.
    static let presets: [(name: String, colors: [Color])] = [
        ("Yeşil",     [Wasteland.accent,  Wasteland.cyan,    Wasteland.acid]),
        ("Camgöbeği", [Wasteland.cyan,    Wasteland.accent,  Wasteland.cyan]),
        ("Asit",      [Wasteland.acid,    Wasteland.accent,  Wasteland.acid]),
        ("Mor",       [Wasteland.magenta, Wasteland.cyan,    Wasteland.accent]),
        ("Reaktör",   [Wasteland.danger,  Wasteland.acid,    Wasteland.accent]),
    ]

    /// The three glow colours for a preset (always 3 entries).
    static func glows(_ index: Int) -> [Color] {
        presets[min(max(0, index), presets.count - 1)].colors
    }

    static func gradient(_ index: Int) -> LinearGradient {
        LinearGradient(colors: [Wasteland.base] + glows(index).map { $0.opacity(0.5) },
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// 9 colors (row-major 3×3) for the mesh wallpaper preview: olive base with neon nodes.
    static func meshColors(_ index: Int) -> [Color] {
        let g = glows(index)
        let base = Wasteland.base
        return [
            base,            g[0].opacity(0.6), base,
            g[1].opacity(0.6), base,            g[2].opacity(0.6),
            base,            g[0].opacity(0.6), base,
        ]
    }
}

/// The wasteland fastfetch emblem (from ~/.config/wasteland/logo.txt) rendered as the desktop
/// wallpaper centrepiece: two-tone phosphor green that blooms under the desktop's CRT filter.
private struct WastelandArt: View {
    // $1 = primary green, $2 = brighter green — the same colour markers fastfetch uses.
    private static let logoRaw = #"""
$1      .-=========-.
$1    .'  $2_       _$1  '.
$1   /   $2(o)     (o)$1   \
$1  |      $2\  ^  /$1      |
$1  |       $2'---'$1       |
$1   \   $2.-._____.-.$1   /
$1    '.$2 \ | | | / $1.'
$1      '$2-=========-$1'
$2          /_\
$2       __/ | \__
$2      '--`+++`--'
$1   .  $2.  ._|_.  .$1  .
$1  ( ) $2( ) $1(   )$2 ( )$1 ( )
$1   '   '   '-'   '   '
"""#

    private var lines: [String] {
        Self.logoRaw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    text(for: line)
                }
            }
            .font(.system(size: 17, design: .monospaced))
            Text("W A S T E L A N D")
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .tracking(6)
                .foregroundStyle(Wasteland.accent)
            Text("keep your filter clean and your aim cleaner.")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Wasteland.textDim)
        }
        .opacity(0.85)
        .allowsHitTesting(false)
    }

    /// Build one line, switching colour on the `$1` / `$2` markers.
    private func text(for line: String) -> Text {
        let bright = Color(hex: 0xd8ff5a)
        var out = Text(verbatim: "")
        var color = Wasteland.accent
        var buf = ""
        func flush() {
            if !buf.isEmpty { out = out + Text(verbatim: buf).foregroundColor(color); buf = "" }
        }
        var i = line.startIndex
        while i < line.endIndex {
            let rest = line[i...]
            if rest.hasPrefix("$1") { flush(); color = Wasteland.accent; i = line.index(i, offsetBy: 2); continue }
            if rest.hasPrefix("$2") { flush(); color = bright; i = line.index(i, offsetBy: 2); continue }
            buf.append(line[i]); i = line.index(after: i)
        }
        flush()
        return out
    }
}

private struct DesktopTopBar: View {
    @Environment(SessionRuntime.self) private var runtime
    @Environment(LiveSessionMonitor.self) private var monitor
    @Environment(DesktopWindowManager.self) private var manager

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "command.square.fill").foregroundStyle(Wasteland.accent).neonGlow()
            Text("CLAUDE OS").fontWeight(.bold).foregroundStyle(Wasteland.accent)
            if let title = activeTitle {
                Text("·").foregroundStyle(Wasteland.border)
                Text(title).foregroundStyle(Wasteland.textDim).lineLimit(1)
            }
            Spacer(minLength: 8)
            if liveCount > 0 { livePill }
            quickOpenPill
            clock.foregroundStyle(Wasteland.textDim)
        }
        .font(Wasteland.font(11))
        .padding(.leading, 78)
        .padding(.trailing, 12)
        .frame(height: 28)
        .background(Wasteland.base.opacity(0.9))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Wasteland.border).frame(height: 1)
        }
    }

    /// Green capsule with a softly pulsing dot — an ambient "things are alive" cue.
    private var livePill: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 8.0, paused: false)) { ctx in
            let pulse = 0.55 + 0.45 * sin(ctx.date.timeIntervalSinceReferenceDate * 2.4)
            HStack(spacing: 5) {
                Circle().fill(Wasteland.accent).frame(width: 6, height: 6).opacity(pulse).neonGlow()
                Text("\(liveCount) canlı")
            }
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Wasteland.accent.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(Wasteland.accent.opacity(0.5), lineWidth: 1))
            .foregroundStyle(Wasteland.accent)
        }
    }

    private var quickOpenPill: some View {
        HStack(spacing: 3) {
            Image(systemName: "magnifyingglass")
            Text("⌘K")
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Wasteland.surfaceHi, in: Capsule())
        .overlay(Capsule().strokeBorder(Wasteland.border, lineWidth: 1))
        .foregroundStyle(Wasteland.textDim)
        .help("Hızlı aç (⌥Space)")
    }

    private var clock: some View {
        TimelineView(.everyMinute) { context in
            Text(context.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        }
    }

    private var activeTitle: String? {
        manager.windows.filter { !$0.minimized }.max(by: { $0.z < $1.z })?.title
    }

    private var liveCount: Int {
        monitor.liveSessionIds.union(runtime.liveSessionIds).count
    }
}

/// Shows the host window's real close/minimize/zoom (the APP's own controls, top-left)
/// while keeping the title bar transparent so the desktop still reads as immersive.
/// The app is closed/minimized via these; emulated windows have their own controls.
private final class ChromeHidingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        // Phosphor bloom over the desktop chrome (wallpaper, dock, top bar, icons). Child
        // windows are separate NSWindows, so they get their own bloom in attachIfNeeded.
        if let content = window.contentView { applyPhosphorBloom(to: content) }
    }
}

private struct WindowChromeHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeHidingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Placeholder for a restored-but-dormant terminal window. The whole surface is tappable, so a
/// click anywhere resumes the session; a blank PTY used to sit here with no way to wake it.
private struct DormantTerminalView: View {
    let title: String
    let onResume: () -> Void

    var body: some View {
        Button(action: onResume) {
            VStack(spacing: 12) {
                Image(systemName: "play.circle")
                    .font(.system(size: 40))
                    .foregroundStyle(Wasteland.accent)
                    .neonGlow(Wasteland.accent, radius: 6)
                Text(title)
                    .font(Wasteland.font(13, weight: .semibold)).foregroundStyle(Wasteland.textPrimary)
                    .lineLimit(2).multilineTextAlignment(.center)
                Text("Oturum uykuda. Devam etmek için tıkla.")
                    .font(Wasteland.font(11)).foregroundStyle(Wasteland.textDim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Wasteland.base)
    }
}
