import Foundation
import AppKit
import Observation
@preconcurrency import SwiftTerm
import ClaudeOSCore

/// One embedded `claude` session: owns the SwiftTerm view + PTY process and a
/// small observable state machine the UI binds to. The terminal view is retained
/// here (not by any SwiftUI view) so the PTY survives view teardown and tab
/// switches. A session can be created `dormant` (e.g. restored from a previous
/// run) and only spawned when first focused.
@MainActor
@Observable
public final class TerminalSession: Identifiable {
    public let id = UUID()
    public let spec: ClaudeLaunchSpec
    public private(set) var claudeSessionId: String?
    public private(set) var title: String

    public enum State: Equatable, Sendable {
        case dormant
        case running
        case exited(Int32?)
    }
    public private(set) var state: State = .dormant
    public var isExited: Bool { if case .exited = state { return true }; return false }
    public var isRunning: Bool { state == .running }
    public var workingDirectory: URL { spec.workingDirectory }

    /// True when a running session's terminal has been quiet long enough to look
    /// like it's waiting for input (heuristic: cursor/scroll stopped changing).
    public private(set) var needsAttention = false
    @ObservationIgnored private var lastSignature = Int.min
    @ObservationIgnored private var lastChangeAt = Date()

    /// Called (on the main actor) when the child process exits.
    @ObservationIgnored public var onTerminate: ((Int32?) -> Void)?

    @ObservationIgnored public let terminalView: LocalProcessTerminalView
    @ObservationIgnored private let environment: [String]
    @ObservationIgnored private let binary: URL
    @ObservationIgnored private lazy var proxy = Delegate(owner: self)

    public init(spec: ClaudeLaunchSpec, environment: [String], binary: URL, title: String, fontSize: CGFloat = 13) {
        self.spec = spec
        self.environment = environment
        self.binary = binary
        self.title = title
        self.terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        terminalView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        switch spec.mode {
        case .fresh(let id), .resume(let id): claudeSessionId = id
        case .continueLast: claudeSessionId = nil
        }
        terminalView.processDelegate = proxy
    }

    /// Spawn the child process. No-op if already started.
    public func start() {
        guard state == .dormant else { return }
        let (executable, args) = spec.argv(resolvedBinary: binary)
        terminalView.startProcess(
            executable: executable,
            args: args,
            environment: environment,
            execName: "claude",
            currentDirectory: spec.workingDirectory.path
        )
        state = .running
        lastChangeAt = Date()
    }

    public func terminate() {
        terminalView.terminate()
    }

    public func setFont(size: CGFloat) {
        terminalView.font = .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Sampled by the runtime on a timer; flips `needsAttention` when a running
    /// session's terminal has been visually quiet past `idleThreshold`.
    public func pollActivity(now: Date, idleThreshold: TimeInterval) {
        guard state == .running else {
            if needsAttention { needsAttention = false }
            return
        }
        let terminal = terminalView.getTerminal()
        let cursor = terminal.getCursorLocation()
        let signature = (cursor.x &* 100_003) &+ (cursor.y &* 131) &+ terminal.getTopVisibleRow()
        if signature != lastSignature {
            lastSignature = signature
            lastChangeAt = now
            if needsAttention { needsAttention = false }
        } else if !needsAttention, now.timeIntervalSince(lastChangeAt) >= idleThreshold {
            needsAttention = true
        }
    }

    fileprivate func handleTerminated(_ exitCode: Int32?) {
        state = .exited(exitCode)
        onTerminate?(exitCode)
    }
    fileprivate func handleTitle(_ newTitle: String) {
        if !newTitle.isEmpty { title = newTitle }
    }

    /// SwiftTerm always calls its process delegate on the main thread. Isolating
    /// the proxy conformance with `@preconcurrency` lets these callbacks touch
    /// main-actor session state directly.
    @MainActor
    private final class Delegate: NSObject, @preconcurrency LocalProcessTerminalViewDelegate {
        weak var owner: TerminalSession?
        init(owner: TerminalSession) { self.owner = owner }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            owner?.handleTitle(title)
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            owner?.handleTerminated(exitCode)
        }
    }
}
