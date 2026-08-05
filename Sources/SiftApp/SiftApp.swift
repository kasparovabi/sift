import SwiftUI
import AppKit
import SiftCore
import SiftBrain
import SiftIndex
import SiftRuntime
import SiftViews

@main
struct SiftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var index: IndexCoordinator
    @State private var runtime: SessionRuntime
    @State private var monitor: LiveSessionMonitor
    @State private var quickOpen: QuickOpenController
    @State private var brainVM: BrainViewModel
    @State private var toasts: ToastCenter
    @State private var themes = ThemeStore()

    init() {
        // Open fresh rather than restoring a saved frame. On a multi-display setup the
        // restored frame lands on whichever screen it was last closed on, which reads as
        // "the app started but there's no window" when that screen isn't the one you're at.
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")

        // Runs before anything opens a store: the app was renamed, and both the preferences
        // domain and the support folder are keyed on the old identity.
        LegacyMigration.run(
            applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory,
                                                         in: .userDomainMask)[0])

        // The index is a rebuildable cache over the transcripts, so an unopenable file is
        // recoverable: move it aside and start a fresh one rather than making the app
        // permanently unlaunchable for anyone who does not know where it lives.
        var startupNotice: String?
        let store: IndexStore
        do {
            let opened = try StoreRecovery.open(at: IndexStore.defaultURL()) { try IndexStore(path: $0) }
            store = opened.store
            if let moved = opened.quarantined {
                startupNotice = """
                    The search index could not be opened and was moved to \(moved.lastPathComponent). \
                    A new one is being built from your transcripts; nothing of yours was lost.
                    """
            }
        } catch {
            AppDelegate.reportFatal("""
                Sift could not open or rebuild its search index at \
                \(IndexStore.defaultURL().path).

                \(error.localizedDescription)
                """)
        }
        let index = IndexCoordinator(store: store)
        let runtime = SessionRuntime()
        let monitor = LiveSessionMonitor()
        let quickOpen = QuickOpenController(index: index, runtime: runtime)

        // Brain: shared memory store + MCP hook so every launched session gets the
        // brain_* tools and a project digest injected at start. Same brain.sqlite the
        // sift-brain-mcp server opens, so app and MCP server share one store.
        //
        // BrainService is guaranteed: try the canonical AppSupport path first; if
        // that fails (first-launch permissions, sandboxing, etc.) fall back to a
        // temp-directory path so BrainViewModel is always non-nil and BrainView's
        // @Environment(BrainViewModel.self) never crashes at runtime.
        let appSupport = AppPaths.supportDirectory
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let brainDBURL = appSupport.appendingPathComponent("brain.sqlite")
        let brainDBPath = brainDBURL.path
        // Unlike the index, the brain cannot be rebuilt from the transcripts, so a file that
        // will not open is moved aside rather than dropped: the extracted knowledge stays on
        // disk for the user to recover. Falling back to a temp file keeps the app usable.
        let brain: BrainService
        do {
            let opened = try StoreRecovery.open(at: brainDBURL) { try BrainService(path: $0.path) }
            brain = opened.store
            if let moved = opened.quarantined {
                startupNotice = """
                    The knowledge store could not be opened and was moved to \
                    \(moved.lastPathComponent). Your sessions and search are unaffected.
                    """
            }
        } catch {
            let fallback = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("sift-brain-fallback.sqlite")
            guard let temporary = try? BrainService(path: fallback.path) else {
                AppDelegate.reportFatal("""
                    Sift could not open its knowledge store at \(brainDBPath), \
                    and the temporary fallback failed too.

                    \(error.localizedDescription)
                    """)
            }
            brain = temporary
            startupNotice = "The knowledge store is unavailable; this session is using a temporary one."
        }
        // Wire MCP hook and ingester using the guaranteed brain.
        // Gated on the same switch as extraction: the hook adds an MCP server and a project
        // digest to every session it launches, and both cost context on each run. With
        // extraction off there is no knowledge to inject anyway.
        let mcpBinary = (Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("sift-brain-mcp").path) ?? "sift-brain-mcp"
        if Preferences.knowledgeExtractionEnabled {
            runtime.brain = BrainLaunchHook(
                binaryPath: mcpBinary,
                dbPath: brainDBPath,
                digestForProject: { proj in (try? brain.projectDigest(proj: proj, limit: 12)) ?? "" }
            )
        }
        // Knowledge extraction runs off the transcript files (see BrainIngestQueue below), so
        // it covers every session — including the ones running in the user's own terminal.
        let ingester = BrainIngester(service: brain)
        // A passed loop writes a one-line outcome atom so finished work compounds into the
        // project digest the next run sees. Off-main: remember() embeds + writes SQLite.
        runtime.onLoopArtifact = { cwd, title, summary, src in
            let text = "Completed loop \'\(title)\': \(summary)"
            DispatchQueue.global(qos: .utility).async {
                _ = try? brain.remember(text: text, type: .howto, importance: 5, proj: cwd, src: src)
            }
        }

        // Periodic + on-launch Forgetter sweep (drops low-importance, aged, never-retrieved atoms).
        Task.detached(priority: .utility) { _ = try? await brain.forget() }
        Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { _ in
            Task.detached(priority: .utility) { _ = try? await brain.forget() }
        }

        // All-session capture, and the only thing Sift does that leaves the machine: each
        // ingest sends a transcript to `claude -p` on the user's own account. Off unless the
        // user turns it on in Settings, paced so a backlog cannot fire all at once, and
        // debounced ~60s so a session is ingested after it goes idle. Idempotency
        // (hasAtoms(src:)) prevents re-ingesting the same session.
        let brainQueue = BrainIngestQueue(debounce: 60, maxPerTick: Preferences.extractionsPerTick) { path in
            guard Preferences.knowledgeExtractionEnabled else { return }
            ingester.ingestPath(path)
        }
        index.onSessionsChanged = { paths in
            guard Preferences.knowledgeExtractionEnabled else { return }
            let now = Date().timeIntervalSince1970
            for p in paths where p.hasSuffix(".jsonl") { brainQueue.touch(p, now: now) }
        }
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            guard Preferences.knowledgeExtractionEnabled else { brainQueue.drop(); return }
            brainQueue.tick(now: Date().timeIntervalSince1970)
        }

        _index = State(initialValue: index)
        _runtime = State(initialValue: runtime)
        _monitor = State(initialValue: monitor)
        _quickOpen = State(initialValue: quickOpen)
        _brainVM = State(initialValue: BrainViewModel(service: brain))
        _toasts = State(initialValue: ToastCenter())
        quickOpen.registerHotkey()
        quickOpen.openSessionWindow = { NSApp.activate(ignoringOtherApps: true) }
        AppDelegate.startupNotice = startupNotice
    }

    var body: some Scene {
        WindowGroup(id: "library") {
            LibraryView()
                .environment(index)
                .environment(runtime)
                .environment(monitor)
                .environment(quickOpen)
                .environment(brainVM)
                .environment(toasts)
                .environment(themes)
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Command palette / Quick open") { quickOpen.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Rescan") { Task { await index.rescan() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Button("All sessions") { index.sidebarSelection = .all }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Today") { index.sidebarSelection = .today }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Pinned") { index.sidebarSelection = .pinned }
                    .keyboardShortcut("3", modifiers: .command)
            }
        }

        MenuBarExtra("Sift", systemImage: "terminal.fill") {
            MenuBarContent()
                .environment(index)
                .environment(runtime)
                .environment(monitor)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(index)
                .environment(runtime)
                .environment(themes)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set during `SiftApp.init`, which runs before there is any window to show it in.
    nonisolated(unsafe) static var startupNotice: String?

    /// A store that will not open even after recovery. Shown as an alert instead of a crash
    /// report, so the message says what happened and where, rather than "Sift quit unexpectedly".
    /// assumeIsolated rather than @MainActor: this is called from `SiftApp.init`, which
    /// SwiftUI runs on the main thread but does not declare as main-actor isolated, so an
    /// isolated function would not be callable from there.
    nonisolated static func reportFatal(_ message: String) -> Never {
        MainActor.assumeIsolated {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Sift cannot start"
            alert.informativeText = message
            alert.addButton(withTitle: "Quit")
            alert.runModal()
        }
        exit(1)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let notice = Self.startupNotice {
            Self.startupNotice = nil
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Sift recovered from a damaged file"
            alert.informativeText = notice
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// Keep the app alive in the menubar when the library window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
