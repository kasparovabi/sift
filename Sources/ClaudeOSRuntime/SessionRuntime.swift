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
    /// Embedded terminal font size, persisted and applied to every pane.
    public private(set) var terminalFontSize: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: "claudeos.terminalFontSize")
        return stored >= 8 ? stored : 13
    }()
    /// Terminal colour preset, persisted and applied to every pane.
    public private(set) var terminalThemeId: String =
        UserDefaults.standard.string(forKey: "claudeos.terminalThemeId") ?? "wasteland"
    public var terminalTheme: TerminalTheme { TerminalTheme.preset(id: terminalThemeId) }
    /// Auto-resume restored sessions on launch (default on). When off, a restored session stays
    /// dormant and shows the "tap to resume" placeholder. The env var CLAUDEOS_AUTOSTART=1 forces
    /// it on regardless (used by demos/automation).
    public private(set) var autostartRestoredSessions: Bool =
        (UserDefaults.standard.object(forKey: "claudeos.autostartRestoredSessions") as? Bool) ?? true
    /// Recurring scheduled jobs (run while the app is open).
    public private(set) var scheduledJobs: [ScheduledJob] = ScheduledJobStore.load()
    @ObservationIgnored private var schedulerTask: Task<Void, Never>?

    /// Loop tasks: the maker→checker→proof primitive. Definitions + current state live here;
    /// the proof ledger lives in `loopStore`. Loaded from disk on launch.
    public internal(set) var loopTasks: [LoopTask] = []
    @ObservationIgnored let loopStore: LoopStore?
    @ObservationIgnored var loopRunners: [UUID: Task<Void, Never>] = [:]
    /// Live, in-memory log of a running loop (maker text, tool calls, checker verdict), keyed by
    /// task id. Reset each run, capped, and observed so the row streams it as it happens. Not
    /// persisted — the durable record is the proof ledger in `loopStore`.
    public internal(set) var loopLog: [UUID: [LoopLogLine]] = [:]
    /// Fired (main actor) when a loop passes and `rememberOnPass` is set, so the app can write
    /// a one-line outcome atom to the brain. Keeps the brain dependency out of the runtime.
    public var onLoopArtifact: (@MainActor @Sendable (_ cwd: String, _ title: String, _ summary: String, _ src: String) -> Void)?

    /// Saved folders for one-tap "start a session here" (no picker each time).
    public private(set) var folderBookmarks: [FolderBookmark] = FolderBookmarkStore.load()

    /// Focus timer ("Odak"): a plain countdown that runs while the app is open and
    /// posts a notification when the time is up. No persistence, no claude calls.
    public private(set) var focusTotalSeconds = 25 * 60
    public private(set) var focusRemaining = 25 * 60
    public private(set) var focusRunning = false
    @ObservationIgnored private var focusTask: Task<Void, Never>?

    @ObservationIgnored let environment: [String]
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
        let supportDir = base.appendingPathComponent("ClaudeOS")
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        self.loopStore = try? LoopStore(path: supportDir.appendingPathComponent("loops.sqlite").path)
        restore()
        loadLoopTasks()
        startAttentionTicker()
        startScheduler()
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
        // Key the digest on cwd: atoms are ingested with proj=cwd, and projectId is
        // usually empty/encoded, so cwd is the only key that matches on both sides.
        if let brain { brainArgs = brain.extraArgs(proj: request.cwd) }
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
        if activeSessionId == session.id { activeSessionId = sessions.last?.id }
        persist()
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

    /// Persist the auto-resume preference. Takes effect on the next launch (it governs `restore()`).
    public func setAutostartRestoredSessions(_ on: Bool) {
        guard on != autostartRestoredSessions else { return }
        autostartRestoredSessions = on
        UserDefaults.standard.set(on, forKey: "claudeos.autostartRestoredSessions")
    }

    public func setTerminalTheme(id: String) {
        guard id != terminalThemeId else { return }
        terminalThemeId = id
        UserDefaults.standard.set(id, forKey: "claudeos.terminalThemeId")
        let theme = terminalTheme
        for session in sessions { session.applyTheme(theme) }
    }

    /// Run a one-off headless `claude -p` task in `cwd` and return its text output. No
    /// terminal window, no saved session (--no-session-persistence) — powers "Hızlı görev".
    public func runQuickTask(prompt: String, cwd: String) async -> String {
        let binary = self.binary
        let envStrings = self.environment
        return await Task.detached(priority: .userInitiated) {
            // "Running inside Claude Code" signals: present only when the app itself was
            // launched from a Claude session. With them set, a nested `claude -p` connects
            // to the parent and silently produces no output. Strip *only* these — the auth
            // vars (CLAUDE_CODE_SDK_HAS_*) must stay or the run can't authenticate.
            let nestingSignals: Set<String> = [
                "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "CLAUDE_CODE_SESSION_ID",
            ]
            var envDict: [String: String] = [:]
            for entry in envStrings {
                guard let eq = entry.firstIndex(of: "=") else { continue }
                let key = String(entry[..<eq])
                if nestingSignals.contains(key) { continue }
                envDict[key] = String(entry[entry.index(after: eq)...])
            }
            let process = Process()
            process.executableURL = binary
            // Print mode emits nothing on the default (text) format when piped (no TTY), so
            // we request JSON and read `result`. NOTE: `--no-session-persistence` makes print
            // mode return an EMPTY result, so it's intentionally omitted — a quick task simply
            // persists as a normal, resumable session.
            process.arguments = ["-p", prompt, "--output-format", "json"]
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            if !envDict.isEmpty { process.environment = envDict }
            // Merge stdout+stderr into one pipe (single reader → no deadlock) so any startup
            // or auth error is visible instead of a blank result.
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let raw = String(decoding: data, as: UTF8.self)
                // The answer is a JSON envelope on its own line; scan from the end so any
                // preceding log noise is skipped.
                for line in raw.split(separator: "\n").reversed() {
                    guard let lineData = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
                    else { continue }
                    if let result = obj["result"] as? String {
                        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                        if (obj["is_error"] as? Bool) == true { return "Hata: \(trimmed)" }
                        return trimmed.isEmpty ? "(Boş cevap döndü.)" : trimmed
                    }
                }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "(Boş cevap döndü — claude çıktı vermedi.)" : trimmed
            } catch {
                return "Çalıştırılamadı: \(error.localizedDescription)"
            }
        }.value
    }

    /// The text a streamed task produced, plus the id of the resumable `claude` session it ran in
    /// (every stream event carries `session_id`). The id lets a caller reopen that exact session
    /// interactively — `claude --resume <id>` — so the work can be continued as a conversation.
    public struct StreamedTaskResult: Sendable {
        public let text: String
        public let sessionId: String?
    }

    /// Like `runQuickTask` but emits a readable line per streamed event (assistant text, tool
    /// calls) through `onLine` as they arrive, so a caller can show live progress. Returns the
    /// final result text plus the session id. Uses `stream-json` (which needs `--verbose`).
    /// The detached reader only yields to a Sendable continuation; `onLine` is invoked on the
    /// main actor by the consuming loop, so it is safe to mutate observed state from it.
    public func runQuickTaskStreaming(prompt: String, cwd: String,
                                      onLine: @MainActor (String) -> Void) async -> StreamedTaskResult {
        let binary = self.binary
        let envStrings = self.environment
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let work = Task.detached(priority: .userInitiated) { () -> StreamedTaskResult in
            let nestingSignals: Set<String> = [
                "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "CLAUDE_CODE_SESSION_ID",
            ]
            var envDict: [String: String] = [:]
            for entry in envStrings {
                guard let eq = entry.firstIndex(of: "=") else { continue }
                let key = String(entry[..<eq])
                if nestingSignals.contains(key) { continue }
                envDict[key] = String(entry[entry.index(after: eq)...])
            }
            let process = Process()
            process.executableURL = binary
            process.arguments = ["-p", prompt, "--output-format", "stream-json", "--verbose"]
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            if !envDict.isEmpty { process.environment = envDict }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            var finalResult = ""
            var sessionId: String?
            // Each event is a JSON object on its own line. Surface assistant text and tool
            // calls live; capture the terminal `result` envelope as the return value and the
            // session id (present on every event) so the run can later be resumed.
            func handle(_ lineData: Data) {
                guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let type = obj["type"] as? String else { return }
                if sessionId == nil { sessionId = obj["session_id"] as? String }
                switch type {
                case "assistant":
                    guard let msg = obj["message"] as? [String: Any],
                          let content = msg["content"] as? [[String: Any]] else { return }
                    for block in content {
                        switch block["type"] as? String {
                        case "text":
                            let t = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            if !t.isEmpty { continuation.yield(t) }
                        case "tool_use":
                            continuation.yield("· \(block["name"] as? String ?? "araç")")
                        default: break
                        }
                    }
                case "result":
                    if let r = obj["result"] as? String {
                        let trimmed = r.trimmingCharacters(in: .whitespacesAndNewlines)
                        finalResult = (obj["is_error"] as? Bool) == true ? "Hata: \(trimmed)" : trimmed
                    }
                default: break
                }
            }

            do {
                try process.run()
            } catch {
                continuation.finish()
                return StreamedTaskResult(text: "Çalıştırılamadı: \(error.localizedDescription)", sessionId: nil)
            }
            // Drain incrementally: a full JSON line ends at a newline (ASCII), so decoding each
            // completed line as UTF-8 never splits a multi-byte char (Turkish text stays intact).
            let fh = pipe.fileHandleForReading
            var buf = Data()
            while true {
                let chunk = fh.availableData
                if chunk.isEmpty { break }   // EOF
                buf.append(chunk)
                while let nl = buf.firstIndex(of: 0x0A) {
                    handle(buf.subdata(in: buf.startIndex..<nl))
                    buf.removeSubrange(buf.startIndex...nl)
                }
            }
            if !buf.isEmpty { handle(buf) }
            process.waitUntilExit()
            continuation.finish()
            return StreamedTaskResult(text: finalResult.isEmpty ? "(Boş cevap döndü.)" : finalResult,
                                      sessionId: sessionId)
        }
        for await line in stream { onLine(line) }
        return await work.value
    }

    /// Reopen a past `claude -p` run (e.g. a loop's maker) as a live, embedded interactive session
    /// in `cwd`, so its full context — the files it read, the output it produced — is right there
    /// to continue the conversation. Focuses the new terminal window on the desktop.
    public func continueSession(sessionId: String, cwd: String, title: String) {
        Task { [weak self] in
            try? await self?.launch(SessionLaunchRequest(mode: .resume(sessionId: sessionId), cwd: cwd,
                                                         projectId: "", title: title))
        }
    }

    // MARK: - Scheduled jobs (in-app, runs while the app is open)

    public func addScheduledJob(title: String, prompt: String, cwd: String, everyMinutes: Int) {
        // lastRun = now so a fresh job waits a full interval before its first auto-run
        // (no surprise immediate fire); "Şimdi çalıştır" runs it on demand.
        let job = ScheduledJob(title: title, prompt: prompt, cwd: cwd, everyMinutes: everyMinutes, lastRun: Date())
        scheduledJobs.insert(job, at: 0)
        ScheduledJobStore.save(scheduledJobs)
    }

    public func removeScheduledJob(_ id: ScheduledJob.ID) {
        scheduledJobs.removeAll { $0.id == id }
        ScheduledJobStore.save(scheduledJobs)
    }

    public func toggleScheduledJob(_ id: ScheduledJob.ID) {
        guard let i = scheduledJobs.firstIndex(where: { $0.id == id }) else { return }
        scheduledJobs[i].enabled.toggle()
        ScheduledJobStore.save(scheduledJobs)
    }

    public func runScheduledJobNow(_ id: ScheduledJob.ID) {
        guard let i = scheduledJobs.firstIndex(where: { $0.id == id }) else { return }
        Task { await runJob(scheduledJobs[i]) }
    }

    /// Runs a job through the headless runner and records its result.
    private func runJob(_ job: ScheduledJob) async {
        let result = await runQuickTask(prompt: job.prompt, cwd: job.cwd)
        guard let i = scheduledJobs.firstIndex(where: { $0.id == job.id }) else { return }
        scheduledJobs[i].lastRun = Date()
        scheduledJobs[i].lastResult = result
        ScheduledJobStore.save(scheduledJobs)
    }

    /// Once a minute, run any enabled job whose interval has elapsed.
    private func startScheduler() {
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await self?.tickScheduler()
            }
        }
    }

    private func tickScheduler() async {
        let now = Date()
        let due = scheduledJobs.filter { job in
            guard job.enabled else { return false }
            guard let last = job.lastRun else { return true }
            return now.timeIntervalSince(last) >= Double(job.everyMinutes) * 60
        }
        for job in due { await runJob(job) }
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

    // MARK: - Focus timer (Odak)

    /// Choose a duration (allowed only while stopped); resets the countdown to it.
    public func setFocusMinutes(_ minutes: Int) {
        guard !focusRunning else { return }
        let secs = max(60, minutes * 60)
        focusTotalSeconds = secs
        focusRemaining = secs
    }

    public func startFocus() {
        guard !focusRunning, focusRemaining > 0 else { return }
        focusRunning = true
        focusTask?.cancel()
        focusTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.focusRunning else { return }
                if self.focusRemaining > 0 { self.focusRemaining -= 1 }
                if self.focusRemaining <= 0 {
                    self.focusRunning = false
                    self.notifyFocusDone()
                    return
                }
            }
        }
    }

    public func pauseFocus() {
        focusRunning = false
        focusTask?.cancel()
    }

    public func resetFocus() {
        focusRunning = false
        focusTask?.cancel()
        focusRemaining = focusTotalSeconds
    }

    private func notifyFocusDone() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Odak süresi doldu"
        content.body = "\(focusTotalSeconds / 60) dakikalık odak bitti. Biraz mola ver."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Folder bookmarks (Klasörlerim)

    public func addFolderBookmark(path: String) {
        guard !folderBookmarks.contains(where: { $0.path == path }) else { return }
        folderBookmarks.append(FolderBookmark(path: path))
        FolderBookmarkStore.save(folderBookmarks)
    }

    public func removeFolderBookmark(_ id: UUID) {
        folderBookmarks.removeAll { $0.id == id }
        FolderBookmarkStore.save(folderBookmarks)
    }

    // MARK: - Persistence

    private func makeSession(spec: ClaudeLaunchSpec, title: String) -> TerminalSession {
        let session = TerminalSession(spec: spec, environment: environment, binary: binary, title: title,
                                      fontSize: terminalFontSize, theme: terminalTheme)
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
        let autostart = autostartRestoredSessions
            || ProcessInfo.processInfo.environment["CLAUDEOS_AUTOSTART"] == "1"
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
