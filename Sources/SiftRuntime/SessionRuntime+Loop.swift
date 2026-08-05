import Foundation

/// One line of a loop's live log, shown in the row while it runs. Ephemeral (not persisted);
/// the durable per-attempt record is `ProofRecord`. `kind` drives colour in the UI.
public struct LoopLogLine: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let text: String
    public let kind: Kind
    public enum Kind: Sendable, Equatable { case phase, maker, checker, pass, fail }
    public init(text: String, kind: Kind) { self.text = text; self.kind = kind }
}

/// The loop engine: trigger → maker → SEPARATE checker → proof → repeat until done or exit.
/// Built on `runQuickTask` (the maker, and the agent checker) so it reuses the same headless
/// `claude -p` path. Each cycle writes a proof row; on pass it optionally feeds the brain, so
/// completed work compounds into the project digest the next run sees.
extension SessionRuntime {
    // MARK: - CRUD

    func loadLoopTasks() {
        guard let loopStore else { return }
        var tasks = (try? loopStore.allTasks()) ?? []
        // Crash recovery: a task left mid-run on last launch is no longer running.
        for i in tasks.indices where tasks[i].state == .running || tasks[i].state == .checking {
            tasks[i].state = .idle
            try? loopStore.upsert(tasks[i])
        }
        loopTasks = tasks
    }

    @discardableResult
    public func addLoopTask(title: String, prompt: String, cwd: String, doneWhen: String,
                            checkKind: CheckKind, maxPasses: Int, rememberOnPass: Bool) -> LoopTask {
        let now = Date()
        let task = LoopTask(title: title, prompt: prompt, cwd: cwd, doneWhen: doneWhen,
                            checkKind: checkKind, maxPasses: max(1, maxPasses),
                            rememberOnPass: rememberOnPass, createdAt: now, updatedAt: now)
        loopTasks.insert(task, at: 0)
        try? loopStore?.upsert(task)
        return task
    }

    public func removeLoopTask(_ id: UUID) {
        stopLoop(id)
        loopTasks.removeAll { $0.id == id }
        try? loopStore?.deleteTask(id: id)
    }

    public func proofs(for taskId: UUID) -> [ProofRecord] {
        (try? loopStore?.proofs(taskId: taskId)) ?? []
    }

    public var runningLoopIds: Set<UUID> { Set(loopRunners.keys) }

    private func mutateTask(_ id: UUID, _ change: (inout LoopTask) -> Void) {
        guard let i = loopTasks.firstIndex(where: { $0.id == id }) else { return }
        change(&loopTasks[i])
        loopTasks[i].updatedAt = Date()
        try? loopStore?.upsert(loopTasks[i])
    }

    /// Append a line to a task's live log (reassigns the array so the @Observable change fires).
    /// Capped so a long run can't grow the buffer without bound.
    func appendLog(_ id: UUID, _ text: String, _ kind: LoopLogLine.Kind) {
        var arr = loopLog[id] ?? []
        arr.append(LoopLogLine(text: text, kind: kind))
        if arr.count > 300 { arr.removeFirst(arr.count - 300) }
        loopLog[id] = arr
    }

    // MARK: - Run / stop

    public func runLoop(_ id: UUID) {
        guard loopRunners[id] == nil, let task = loopTasks.first(where: { $0.id == id }) else { return }
        try? loopStore?.clearProofs(taskId: id)   // fresh evidence each run
        loopLog[id] = []                          // and a fresh live log
        mutateTask(id) { $0.state = .running; $0.lastAttempt = 0 }
        loopRunners[id] = Task { [weak self] in
            await self?.runLoopBody(task)
            self?.loopRunners[id] = nil
        }
    }

    public func stopLoop(_ id: UUID) {
        loopRunners[id]?.cancel()
        loopRunners[id] = nil
        if let t = loopTasks.first(where: { $0.id == id }), t.state == .running || t.state == .checking {
            mutateTask(id) { $0.state = .stopped }
        }
    }

    // MARK: - Engine

    private func runLoopBody(_ task: LoopTask) async {
        let id = task.id
        var lastChecker = ""
        for attempt in 1...max(1, task.maxPasses) {
            if Task.isCancelled { mutateTask(id) { $0.state = .stopped }; return }
            mutateTask(id) { $0.state = .running; $0.lastAttempt = attempt }
            appendLog(id, "▸ Attempt \(attempt) · maker running", .phase)

            // Maker. After the first cycle, hand back the checker's reason so it can fix.
            let makerPrompt = attempt == 1 ? task.prompt : """
                \(task.prompt)

                A previous attempt at this task was graded "not done" for this reason:
                \(lastChecker)

                Take that feedback into account and finish the work.
                """
            let maker = await runQuickTaskStreaming(prompt: makerPrompt, cwd: task.cwd) { [weak self] line in
                self?.appendLog(id, line, .maker)
            }
            let makerOut = maker.text
            if Task.isCancelled { mutateTask(id) { $0.state = .stopped }; return }

            // Checker (separate from the maker on purpose).
            mutateTask(id) { $0.state = .checking }
            appendLog(id, "▸ Attempt \(attempt) · checker grading", .phase)
            let (passed, checkerOut) = await runCheck(task: task, makerOutput: makerOut)
            lastChecker = checkerOut
            appendLog(id, passed ? "✓ PASS" : "✗ FAIL", passed ? .pass : .fail)

            let proof = ProofRecord(taskId: id, attempt: attempt, makerOutput: makerOut,
                                    passed: passed, checkerOutput: checkerOut,
                                    makerSessionId: maker.sessionId, date: Date())
            try? loopStore?.insert(proof: proof)

            if passed {
                mutateTask(id) { $0.state = .passed }
                if task.rememberOnPass {
                    onLoopArtifact?(task.cwd, task.title, String(makerOut.prefix(500)), "loop:\(id.uuidString)")
                }
                return
            }
        }
        appendLog(id, "Out of attempts, did not pass.", .fail)
        mutateTask(id) { $0.state = .failed }
    }

    private func runCheck(task: LoopTask, makerOutput: String) async -> (Bool, String) {
        switch task.checkKind {
        case .shell:
            let (ok, out) = await Self.runShellCheck(command: task.doneWhen, cwd: task.cwd, env: environment)
            appendLog(task.id, out, .checker)
            return (ok, out)
        case .agent:
            let gradePrompt = """
                You are an independent, sceptical quality checker. Verify that the work below \
                MEETS the criterion; if it does not, catch that.

                CRITERION (definition of done):
                \(task.doneWhen)

                WORK PRODUCED:
                \(makerOutput)

                Rules: you did not do this work, and your job is to audit it rather than approve \
                it. If the criterion is not fully met, or you are unsure, answer FAIL. The FIRST \
                line of your reply must be exactly PASS or FAIL, followed by one to three \
                sentences of reasoning.
                """
            let verdict = await runQuickTaskStreaming(prompt: gradePrompt, cwd: task.cwd) { [weak self] line in
                self?.appendLog(task.id, line, .checker)
            }.text
            return (Self.verdictIsPass(verdict), verdict)
        }
    }

    /// First non-empty token decides; anything that is not a clear PASS counts as FAIL, so an
    /// ambiguous grader never lets unfinished work through.
    nonisolated static func verdictIsPass(_ verdict: String) -> Bool {
        let firstLine = verdict.split(whereSeparator: \.isNewline).first.map(String.init) ?? verdict
        return firstLine.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("PASS")
    }

    /// Run `doneWhen` as a shell command (tests, lint, a file check…). Exit 0 == done.
    nonisolated static func runShellCheck(command: String, cwd: String, env: [String]) async -> (Bool, String) {
        await Task.detached(priority: .userInitiated) {
            var envDict: [String: String] = [:]
            for entry in env {
                guard let eq = entry.firstIndex(of: "=") else { continue }
                envDict[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            if !envDict.isEmpty { process.environment = envDict }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let ok = process.terminationStatus == 0
                let label = "exit \(process.terminationStatus)"
                return (ok, out.isEmpty ? label : "\(label)\n\(out)")
            } catch {
                return (false, "Command failed: \(error.localizedDescription)")
            }
        }.value
    }
}
