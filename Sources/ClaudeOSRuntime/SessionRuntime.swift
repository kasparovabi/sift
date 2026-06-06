import Foundation
import Observation
import UserNotifications
import ClaudeOSCore
import ClaudeOSBrain

/// A persisted descriptor so open sessions survive an app restart (reattached via
/// `claude --resume <id>`).
private struct OpenSessionDescriptor: Codable, Sendable {
    var claudeSessionId: String
    var cwd: String
    var title: String
}

/// Owns the live embedded sessions, implements the `SessionLauncher` seam, runs
/// several concurrently, persists/reattaches them, and notifies when a
/// backgrounded session finishes.
@MainActor
@Observable
public final class SessionRuntime: SessionLauncher, SessionRuntimeStatusProviding {
    public private(set) var sessions: [TerminalSession] = []
    public var activeSessionId: TerminalSession.ID?
    /// Sessions pulled out of the main workspace into their own windows.
    public private(set) var detachedSessionIds: Set<TerminalSession.ID> = []
    /// Embedded terminal font size, persisted and applied to every pane.
    public private(set) var terminalFontSize: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: "claudeos.terminalFontSize")
        return stored >= 8 ? stored : 13
    }()

    @ObservationIgnored private let environment: [String]
    @ObservationIgnored private let binary: URL
    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private var attentionTask: Task<Void, Never>?

    /// Optional brain hook; when set, appends MCP-config + digest args to every launch.
    public var brain: BrainLaunchHook?

    /// Optional callback fired when a session with a claude id terminates, so the
    /// brain can extract knowledge from the finished transcript in the background.
    public var onSessionFinished: (@MainActor @Sendable (_ cwd: String, _ claudeSessionId: String) -> Void)?

    public init() {
        self.environment = EnvironmentResolver.environmentStrings()
        self.binary = ClaudeBinary.resolve()
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        self.stateURL = base.appendingPathComponent("ClaudeOS/open-sessions.json")
        restore()
        startAttentionTicker()
        launchDemoIfRequested()
    }

    /// Dev/demo hook: CLAUDEOS_DEMO_FRESH=N opens N fresh sessions on launch (off
    /// by default). Handy for trying the tiled multi-session workspace.
    private func launchDemoIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["CLAUDEOS_DEMO_FRESH"],
              let count = Int(raw), count > 0 else { return }
        for i in 0..<count {
            let spec = ClaudeLaunchSpec(
                mode: .fresh(sessionId: UUID().uuidString.lowercased()),
                workingDirectory: URL(fileURLWithPath: NSHomeDirectory())
            )
            let session = makeSession(spec: spec, title: "Demo \(i + 1)")
            sessions.append(session)
            session.start()
        }
        activeSessionId = sessions.first?.id
    }

    public var activeSession: TerminalSession? {
        sessions.first { $0.id == activeSessionId }
    }

    public func session(forClaudeId claudeId: String) -> TerminalSession? {
        sessions.first { $0.claudeSessionId == claudeId && !$0.isExited }
    }

    // MARK: - SessionLauncher

    @discardableResult
    public func launch(_ request: SessionLaunchRequest) async throws -> LaunchedSessionHandle {
        if case .resume(let id) = request.mode, let existing = session(forClaudeId: id) {
            focus(existing)
            return LaunchedSessionHandle(runtimeSessionId: existing.id.uuidString, claudeSessionId: id)
        }

        let mode: ClaudeLaunchSpec.Mode
        switch request.mode {
        case .resume(let id): mode = .resume(sessionId: id)
        case .fresh: mode = .fresh(sessionId: UUID().uuidString.lowercased())
        }
        var brainArgs: [String] = []
        if let brain { brainArgs = brain.extraArgs(proj: request.projectId) }
        let spec = ClaudeLaunchSpec(mode: mode, workingDirectory: URL(fileURLWithPath: request.cwd), extraArgs: brainArgs)
        let session = makeSession(spec: spec, title: request.title ?? "claude")
        sessions.append(session)
        session.start()
        activeSessionId = session.id
        persist()
        return LaunchedSessionHandle(runtimeSessionId: session.id.uuidString, claudeSessionId: session.claudeSessionId)
    }

    // MARK: - Lifecycle

    /// Make a session the active one, starting it if it was dormant (restored).
    public func focus(_ session: TerminalSession) {
        activeSessionId = session.id
        if session.state == .dormant { session.start(); persist() }
    }

    public func close(_ session: TerminalSession) {
        session.terminate()
        sessions.removeAll { $0.id == session.id }
        detachedSessionIds.remove(session.id)
        if activeSessionId == session.id { activeSessionId = sessions.last?.id }
        persist()
    }

    /// Pull a session out of the workspace into its own window.
    public func detach(_ session: TerminalSession) {
        detachedSessionIds.insert(session.id)
    }

    /// Return a detached session to the tiled workspace.
    public func reattach(_ id: TerminalSession.ID) {
        detachedSessionIds.remove(id)
    }

    public func terminateAll() {
        sessions.forEach { $0.terminate() }
    }

    // MARK: - Appearance

    public func setTerminalFontSize(_ size: CGFloat) {
        let clamped = min(28, max(9, size.rounded()))
        guard clamped != terminalFontSize else { return }
        terminalFontSize = clamped
        UserDefaults.standard.set(Double(clamped), forKey: "claudeos.terminalFontSize")
        for session in sessions { session.setFont(size: clamped) }
    }

    public func adjustFontSize(by delta: CGFloat) {
        setTerminalFontSize(terminalFontSize + delta)
    }

    // MARK: - Multi-pane navigation / arrangement

    public func focus(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        focus(sessions[index])
    }

    public func focusNext() {
        guard !sessions.isEmpty else { return }
        let current = sessions.firstIndex { $0.id == activeSessionId } ?? -1
        focus(sessions[(current + 1) % sessions.count])
    }

    public func focusPrevious() {
        guard !sessions.isEmpty else { return }
        let current = sessions.firstIndex { $0.id == activeSessionId } ?? 0
        focus(sessions[(current - 1 + sessions.count) % sessions.count])
    }

    /// Reorder a pane left/right in the workspace.
    public func move(_ session: TerminalSession, by delta: Int) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let target = max(0, min(sessions.count - 1, index + delta))
        guard target != index else { return }
        let item = sessions.remove(at: index)
        sessions.insert(item, at: target)
        persist()
    }

    /// Drag-and-drop reorder: move `sourceId` to where `targetId` currently sits.
    public func moveSession(_ sourceId: TerminalSession.ID, toIndexOf targetId: TerminalSession.ID) {
        guard sourceId != targetId,
              let from = sessions.firstIndex(where: { $0.id == sourceId }) else { return }
        let item = sessions.remove(at: from)
        let insertAt = sessions.firstIndex(where: { $0.id == targetId }) ?? sessions.count
        sessions.insert(item, at: insertAt)
        persist()
    }

    /// Polls each running session's terminal for activity to drive `needsAttention`.
    private func startAttentionTicker() {
        attentionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                guard let self else { return }
                let now = Date()
                for session in self.sessions {
                    session.pollActivity(now: now, idleThreshold: 1.5)
                }
            }
        }
    }

    // MARK: - Status

    public var liveSessionIds: Set<String> {
        Set(sessions.compactMap { $0.isExited ? nil : $0.claudeSessionId })
    }
    public var runningCount: Int { sessions.filter { $0.isRunning }.count }
    public var attentionCount: Int { sessions.filter { $0.needsAttention }.count }

    // MARK: - Notifications

    public func requestNotificationAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyFinished(_ session: TerminalSession, exitCode: Int32?) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Oturum bitti"
        content.body = session.title
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Persistence

    private func makeSession(spec: ClaudeLaunchSpec, title: String) -> TerminalSession {
        let session = TerminalSession(spec: spec, environment: environment, binary: binary, title: title, fontSize: terminalFontSize)
        session.onTerminate = { [weak self, weak session] code in
            guard let self, let session else { return }
            self.persist()
            if self.activeSessionId != session.id {
                self.notifyFinished(session, exitCode: code)
            }
            if let sid = session.claudeSessionId {
                self.onSessionFinished?(session.workingDirectory.path, sid)
            }
        }
        return session
    }

    private func persist() {
        let descriptors = sessions.compactMap { session -> OpenSessionDescriptor? in
            guard !session.isExited, let id = session.claudeSessionId else { return nil }
            return OpenSessionDescriptor(claudeSessionId: id, cwd: session.workingDirectory.path, title: session.title)
        }
        guard let data = try? JSONEncoder().encode(descriptors) else { return }
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: stateURL, options: .atomic)
    }

    private func restore() {
        guard let data = try? Data(contentsOf: stateURL),
              let descriptors = try? JSONDecoder().decode([OpenSessionDescriptor].self, from: data) else { return }
        let autostart = ProcessInfo.processInfo.environment["CLAUDEOS_AUTOSTART"] == "1"
        for descriptor in descriptors {
            let spec = ClaudeLaunchSpec(
                mode: .resume(sessionId: descriptor.claudeSessionId),
                workingDirectory: URL(fileURLWithPath: descriptor.cwd)
            )
            let session = makeSession(spec: spec, title: descriptor.title)
            sessions.append(session)
            // Dormant by default (started on first focus); CLAUDEOS_AUTOSTART=1
            // brings the whole workspace back live on launch.
            if autostart { session.start() }
        }
        if autostart { activeSessionId = sessions.first?.id }
    }
}
