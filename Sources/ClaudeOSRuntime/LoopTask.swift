import Foundation

/// A "loop task": the maker→checker→proof primitive. A trigger runs the maker (`claude -p`),
/// a SEPARATE checker grades the output against `doneWhen`, and the cycle repeats until the
/// checker passes or `maxPasses` is hit. The whole point is that the grader is not the maker:
/// a model grading its own work justifies what it did instead of catching where it failed.
public struct LoopTask: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    /// The maker instruction (what to produce/do).
    public var prompt: String
    public var cwd: String
    /// Definition of done. For `.agent` this is natural-language criteria the grader judges
    /// against; for `.shell` it's a command whose exit code 0 means done.
    public var doneWhen: String
    public var checkKind: CheckKind
    /// Exit condition, set before the loop runs: the most maker→checker cycles allowed.
    public var maxPasses: Int
    /// When the loop passes, write a one-line outcome atom to the brain so work compounds.
    public var rememberOnPass: Bool
    public var state: LoopState
    /// How many cycles the most recent run used.
    public var lastAttempt: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String, prompt: String, cwd: String, doneWhen: String,
                checkKind: CheckKind = .agent, maxPasses: Int = 3, rememberOnPass: Bool = true,
                state: LoopState = .idle, lastAttempt: Int = 0,
                createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.cwd = cwd
        self.doneWhen = doneWhen
        self.checkKind = checkKind
        self.maxPasses = maxPasses
        self.rememberOnPass = rememberOnPass
        self.state = state
        self.lastAttempt = lastAttempt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// How a loop's output is judged each cycle.
public enum CheckKind: String, Codable, Sendable, CaseIterable {
    case agent   // a second `claude -p` grades the maker's output against `doneWhen`
    case shell   // `doneWhen` runs as a shell command; exit 0 == done
}

/// Where a loop is in its lifecycle. `running`/`checking` are live (not persisted as a goal,
/// just the current phase); the terminal states (`passed`/`failed`/`stopped`) are the verdict.
public enum LoopState: String, Codable, Sendable {
    case idle
    case running
    case checking
    case passed
    case failed
    case stopped
}

/// One maker→checker cycle's evidence: the proof ledger row. This is both the audit trail and
/// the "examples of good work" the brain can later learn from.
public struct ProofRecord: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var taskId: UUID
    public var attempt: Int
    public var makerOutput: String
    public var passed: Bool
    /// The grader's verdict + reasoning (agent), or the command's combined output (shell).
    public var checkerOutput: String
    /// The resumable `claude` session the maker ran in, so this attempt can be reopened and the
    /// conversation continued from its full context. Nil for shell-only runs or older rows.
    public var makerSessionId: String?
    public var date: Date

    public init(id: UUID = UUID(), taskId: UUID, attempt: Int, makerOutput: String,
                passed: Bool, checkerOutput: String, makerSessionId: String? = nil, date: Date) {
        self.id = id
        self.taskId = taskId
        self.attempt = attempt
        self.makerOutput = makerOutput
        self.passed = passed
        self.checkerOutput = checkerOutput
        self.makerSessionId = makerSessionId
        self.date = date
    }
}
