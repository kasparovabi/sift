import SwiftUI
import AppKit
import ClaudeOSBrain
import ClaudeOSIndex
import ClaudeOSRuntime
import ClaudeOSUI

@main
struct ClaudeOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var index: IndexCoordinator
    @State private var runtime: SessionRuntime
    @State private var monitor: LiveSessionMonitor
    @State private var quickOpen: QuickOpenController
    @State private var windows: DesktopWindowManager
    @State private var brainVM: BrainViewModel

    init() {
        // Always open the desktop fresh; don't restore a previous "no windows" state.
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")

        let store: IndexStore
        do {
            store = try IndexStore(path: IndexStore.defaultURL())
        } catch {
            fatalError("İndeks açılamadı: \(error)")
        }
        let index = IndexCoordinator(store: store)
        let runtime = SessionRuntime()
        let monitor = LiveSessionMonitor()
        let quickOpen = QuickOpenController(index: index, runtime: runtime)
        let windows = DesktopWindowManager()

        // Brain: shared memory store + MCP hook so every launched session gets the
        // brain_* tools and a project digest injected at start. Same brain.sqlite the
        // claudeos-brain-mcp server opens, so app and MCP server share one store.
        //
        // BrainService is guaranteed: try the canonical AppSupport path first; if
        // that fails (first-launch permissions, sandboxing, etc.) fall back to a
        // temp-directory path so BrainViewModel is always non-nil and BrainView's
        // @Environment(BrainViewModel.self) never crashes at runtime.
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let brainDBPath = appSupport.appendingPathComponent("brain.sqlite").path
        let brain: BrainService
        if let primary = try? BrainService(path: brainDBPath) {
            brain = primary
        } else {
            // Fallback: temp directory so the app always has a working brain store.
            let fallbackPath = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("claudeos-brain-fallback.sqlite").path
            // If even the fallback fails, there is nothing we can do.
            brain = try! BrainService(path: fallbackPath)
        }
        // Wire MCP hook and ingester using the guaranteed brain.
        let mcpBinary = (Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("claudeos-brain-mcp").path) ?? "claudeos-brain-mcp"
        runtime.brain = BrainLaunchHook(
            binaryPath: mcpBinary,
            dbPath: brainDBPath,
            digestForProject: { proj in (try? brain.projectDigest(proj: proj, limit: 12)) ?? "" }
        )
        // Auto-extract knowledge from finished sessions in the background.
        let ingester = BrainIngester(service: brain)
        runtime.onSessionFinished = { cwd, sid in ingester.ingestFinished(cwd: cwd, claudeSessionId: sid) }

        // Periodic + on-launch Forgetter sweep (drops low-importance, aged, never-retrieved atoms).
        Task.detached(priority: .utility) { _ = try? await brain.forget() }
        Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { _ in
            Task.detached(priority: .utility) { _ = try? await brain.forget() }
        }

        // All-session capture: ingest ANY session whose transcript changes while we run
        // (not just OS-launched), debounced ~60s so a session is ingested after it goes idle.
        // Idempotency (hasAtoms(src:)) prevents re-ingesting the same session.
        let brainQueue = BrainIngestQueue(debounce: 60) { path in ingester.ingestPath(path) }
        index.onSessionsChanged = { paths in
            let now = Date().timeIntervalSince1970
            for p in paths where p.hasSuffix(".jsonl") { brainQueue.touch(p, now: now) }
        }
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            brainQueue.tick(now: Date().timeIntervalSince1970)
        }

        _index = State(initialValue: index)
        _runtime = State(initialValue: runtime)
        _monitor = State(initialValue: monitor)
        _quickOpen = State(initialValue: quickOpen)
        _windows = State(initialValue: windows)
        _brainVM = State(initialValue: BrainViewModel(service: brain))
        quickOpen.registerHotkey()
        quickOpen.openSessionWindow = {
            NSApp.activate(ignoringOtherApps: true)
            windows.openFinder()
        }
    }

    var body: some Scene {
        WindowGroup {
            DesktopView()
                .environment(index)
                .environment(runtime)
                .environment(monitor)
                .environment(quickOpen)
                .environment(windows)
                .environment(brainVM)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Finder") { windows.openFinder() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Genel Bakış") { windows.openDashboard() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Beyin") { windows.openBrain() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Yeniden tara") { Task { await index.rescan() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Komut paleti / Hızlı aç") { quickOpen.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Yazıyı büyüt") { runtime.adjustFontSize(by: 1) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Yazıyı küçült") { runtime.adjustFontSize(by: -1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Pencereleri döşe") { windows.tileWindows() }
                    .keyboardShortcut("t", modifiers: [.command, .control])
            }
            // Re-bind ⌘W away from the host WindowGroup (which would close the whole
            // emulated desktop) to closing only the frontmost emulated window. The
            // frontmost window is the highest-z non-minimized one. No emulated window
            // open => no-op, which is preferable to nuking the desktop.
            CommandGroup(replacing: .saveItem) {
                Button("Pencereyi kapat") {
                    if let front = windows.windows.filter({ !$0.minimized }).max(by: { $0.z < $1.z }) {
                        windows.close(front.id)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(after: .windowArrangement) {
                Button("Pencereyi küçült") {
                    if let front = windows.windows.filter({ !$0.minimized }).max(by: { $0.z < $1.z }) {
                        windows.minimize(front.id)
                    }
                }
                .keyboardShortcut("m", modifiers: .command)
                Button("Sonraki pencere") {
                    if let lowest = windows.windows.filter({ !$0.minimized }).min(by: { $0.z < $1.z }) {
                        windows.focus(lowest.id)
                    }
                }
                .keyboardShortcut("`", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button("Tüm oturumlar") { index.sidebarSelection = .all }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Bugün") { index.sidebarSelection = .today }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Sabitlenenler") { index.sidebarSelection = .pinned }
                    .keyboardShortcut("3", modifiers: .command)
            }
        }

        MenuBarExtra("Claude OS", systemImage: "terminal.fill") {
            MenuBarContent()
                .environment(index)
                .environment(runtime)
                .environment(monitor)
                .environment(windows)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(index)
                .environment(runtime)
                .environment(windows)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Keep the app alive in the menubar when the desktop window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
