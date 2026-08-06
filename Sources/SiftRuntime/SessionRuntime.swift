import Foundation
import Observation
import UserNotifications
import SiftCore
import SiftBrain

/// Carries the child `Process` out of a detached reader so a cancelled task can kill it.
/// Cancelling used to only stop listening: `claude` kept running, and kept spending tokens,
/// until it finished on its own, so "Stop" was a lie on every surface that offered it.
final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    /// Take ownership of a process about to be launched. False means cancellation already won
    /// the race, so the caller must not start it: nothing would be left holding the handle.
    func adopt(_ process: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        return true
    }

    func terminate() {
        lock.lock()
        let running = process
        cancelled = true
        lock.unlock()
        running?.terminate()
    }
}

/// Runs the headless work — quick tasks, scheduled jobs, loops — and hands interactive
/// sessions to the user's own terminal.
///
/// Interactive sessions used to live here as embedded terminal emulators, one PTY and one
/// full `claude` process per open window, alive whether or not anyone was looking. They now
/// open in the real terminal (`TerminalLauncher`), so an idle session costs nothing and this
/// type is only responsible for work the app itself performs.
@MainActor
@Observable
public final class SessionRuntime: SessionLauncher, SessionRuntimeStatusProviding {

    /// Recurring scheduled jobs (run while the app is open).
    public private(set) var scheduledJobs: [ScheduledJob] = ScheduledJobStore.load()
    /// Jobs with a run in flight. A headless run takes anywhere up to minutes, so without this
    /// "Run now" looked like it did nothing at all.
    public private(set) var runningJobIds: Set<ScheduledJob.ID> = []
    @ObservationIgnored private var schedulerTask: Task<Void, Never>?

    /// Loop tasks: the maker→checker→proof primitive. Definitions + current state live here;
    /// the proof ledger lives in `loopStore`. Loaded from disk on launch.
    public internal(set) var loopTasks: [LoopTask] = []
    @ObservationIgnored let loopStore: LoopStore?
    @ObservationIgnored var loopRunners: [UUID: Task<Void, Never>] = [:]
    /// Live, in-memory log of a running loop, keyed by task id. Reset each run, capped, and
    /// observed so the row streams it as it happens. Not persisted — the durable record is
    /// the proof ledger in `loopStore`.
    public internal(set) var loopLog: [UUID: [LoopLogLine]] = [:]
    /// Fired (main actor) when a loop passes and `rememberOnPass` is set, so the app can write
    /// a one-line outcome atom to the brain. Keeps the brain dependency out of the runtime.
    public var onLoopArtifact: (@MainActor @Sendable (_ cwd: String, _ title: String, _ summary: String, _ src: String) -> Void)?

    /// Saved folders for one-tap "start a session here" (no picker each time).
    public private(set) var folderBookmarks: [FolderBookmark] = FolderBookmarkStore.load()

    @ObservationIgnored let environment: [String]
    @ObservationIgnored private let binary: URL

    /// Optional brain hook; when set, appends MCP-config + digest args to every launch.
    public var brain: BrainLaunchHook?

    public init() {
        self.environment = EnvironmentResolver.environmentStrings()
        self.binary = ClaudeBinary.resolve()
        let supportDir = AppPaths.supportDirectory
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        self.loopStore = try? LoopStore(path: supportDir.appendingPathComponent("loops.sqlite").path)
        loadLoopTasks()
        startScheduler()
    }

    // MARK: - Opening sessions (handed to the user's terminal)

    @discardableResult
    public func launch(_ request: SessionLaunchRequest) async throws -> LaunchedSessionHandle {
        let cwd = request.cwd.isEmpty ? NSHomeDirectory() : request.cwd
        // Key the digest on cwd: atoms are ingested with proj=cwd, and projectId is usually
        // empty/encoded, so cwd is the only key that matches on both sides.
        let brainArgs = brain?.extraArgs(proj: cwd) ?? []
        switch request.mode {
        case .resume(let id, let agent):
            // The knowledge digest and its MCP server are Claude Code flags. Handing them to
            // another agent would make the command fail outright.
            let extras = agent == .claudeCode ? brainArgs : []
            TerminalLauncher.resume(sessionId: id, cwd: cwd, agent: agent, extraArgs: extras)
            return LaunchedSessionHandle(runtimeSessionId: id, claudeSessionId: id)
        case .fresh:
            TerminalLauncher.fresh(cwd: cwd, extraArgs: brainArgs)
            return LaunchedSessionHandle(runtimeSessionId: UUID().uuidString, claudeSessionId: nil)
        }
    }

    /// Reopen a past `claude -p` run (e.g. a loop's maker) as a live session, so its full
    /// context is right there to continue the conversation.
    public func continueSession(sessionId: String, cwd: String, title: String) {
        TerminalLauncher.resume(sessionId: sessionId, cwd: cwd)
    }

    public func openShell(cwd: String) { TerminalLauncher.shell(cwd: cwd) }

    // MARK: - Headless runs

    /// Run a one-off headless `claude -p` task in `cwd` and return its text output. No
    /// terminal, no saved session — powers "Quick task".
    public func runQuickTask(prompt: String, cwd: String) async -> String {
        let binary = self.binary
        let envStrings = self.environment
        return await Task.detached(priority: .userInitiated) {
            let envDict = EnvironmentResolver.dictionary(from: envStrings)
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
                        return trimmed.isEmpty ? "(Empty response.)" : trimmed
                    }
                }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "(Empty response — claude produced no output.)" : trimmed
            } catch {
                return "Could not run: \(error.localizedDescription)"
            }
        }.value
    }

    /// The text a streamed task produced, plus the id of the resumable `claude` session it ran
    /// in. The id lets a caller reopen that exact session interactively.
    public struct StreamedTaskResult: Sendable {
        public let text: String
        public let sessionId: String?
    }

    /// Like `runQuickTask` but emits a readable line per streamed event (assistant text, tool
    /// calls) through `onLine` as they arrive, so a caller can show live progress.
    public func runQuickTaskStreaming(prompt: String, cwd: String,
                                      onLine: @MainActor (String) -> Void) async -> StreamedTaskResult {
        let binary = self.binary
        let envStrings = self.environment
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let processHandle = ProcessHandle()
        let work = Task.detached(priority: .userInitiated) { () -> StreamedTaskResult in
            let envDict = EnvironmentResolver.dictionary(from: envStrings)
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
                            continuation.yield("· \(block["name"] as? String ?? "tool")")
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

            guard processHandle.adopt(process) else {
                continuation.finish()
                return StreamedTaskResult(text: "Stopped.", sessionId: nil)
            }
            do {
                try process.run()
            } catch {
                continuation.finish()
                return StreamedTaskResult(text: "Could not run: \(error.localizedDescription)", sessionId: nil)
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
            return StreamedTaskResult(text: finalResult.isEmpty ? "(Empty response.)" : finalResult,
                                      sessionId: sessionId)
        }
        return await withTaskCancellationHandler {
            for await line in stream { onLine(line) }
            return await work.value
        } onCancel: {
            processHandle.terminate()
        }
    }

    // MARK: - Scheduled jobs (in-app, runs while the app is open)

    public func addScheduledJob(title: String, prompt: String, cwd: String, everyMinutes: Int) {
        // lastRun = now so a fresh job waits a full interval before its first auto-run
        // (no surprise immediate fire); "Run now" runs it on demand.
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

    /// Runs a job through the headless runner and records its result. Re-entrant calls are
    /// dropped, so a manual "Run now" and the scheduler can't run the same job twice.
    private func runJob(_ job: ScheduledJob) async {
        guard !runningJobIds.contains(job.id) else { return }
        runningJobIds.insert(job.id)
        let result = await runQuickTask(prompt: job.prompt, cwd: job.cwd)
        runningJobIds.remove(job.id)
        guard let i = scheduledJobs.firstIndex(where: { $0.id == job.id }) else { return }
        scheduledJobs[i].lastRun = Date()
        scheduledJobs[i].lastResult = result
        ScheduledJobStore.save(scheduledJobs)
        notifyJobFinished(scheduledJobs[i])
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

    // MARK: - Status

    /// Live sessions are discovered from disk by `LiveSessionMonitor` now that sessions run in
    /// the user's terminal, so the runtime reports only the work it performs itself.
    public var liveSessionIds: Set<String> { [] }
    public var runningCount: Int { runningJobIds.count + loopRunners.count }
    public var attentionCount: Int { 0 }

    // MARK: - Notifications

    public func requestNotificationAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyJobFinished(_ job: ScheduledJob) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Task finished"
        content.body = job.title
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
}
