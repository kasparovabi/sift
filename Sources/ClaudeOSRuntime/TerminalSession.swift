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

    public init(spec: ClaudeLaunchSpec, environment: [String], binary: URL, title: String,
                fontSize: CGFloat = 13, theme: TerminalTheme = TerminalTheme.presets[0]) {
        self.spec = spec
        self.environment = environment
        self.binary = binary
        self.title = title
        // ThrottledTerminalView coalesces SwiftTerm's fixed-60fps repaints and
        // suppresses them while occluded — the terminal draw was the app's top CPU stack.
        self.terminalView = ThrottledTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        terminalView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        // Tag so the host window can find and focus this view (first responder), ensuring
        // keystrokes — arrow keys included — reach the PTY as soon as the window activates.
        terminalView.identifier = NSUserInterfaceItemIdentifier("claudeos.terminal")
        applyTheme(theme)
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
        let vector = Self.launchVector(executable: executable, args: args, environment: environment)
        terminalView.startProcess(
            executable: vector.executable,
            args: vector.args,
            environment: environment,
            execName: vector.execName,
            currentDirectory: spec.workingDirectory.path
        )
        state = .running
        lastChangeAt = Date()
    }

    /// "Wasteland shell" (default on): boot the user's interactive login shell first — so the
    /// fastfetch banner, starship prompt and their tools come up exactly like the Ghostty
    /// wasteland terminal — then `exec claude`. Because the shell *execs* claude, claude still
    /// becomes the PTY's process, so exit detection and session ids are unchanged. Set the
    /// UserDefaults flag `claudeos.wastelandShell = false` to launch claude bare instead.
    nonisolated static func launchVector(executable: String, args: [String], environment: [String])
        -> (executable: String, args: [String], execName: String) {
        let enabled = (UserDefaults.standard.object(forKey: "claudeos.wastelandShell") as? Bool) ?? true
        guard enabled else { return (executable, args, "claude") }
        let shell = environment.first(where: { $0.hasPrefix("SHELL=") })
            .map { String($0.dropFirst("SHELL=".count)) } ?? "/bin/zsh"
        let command = "exec " + ([executable] + args).map(Self.shQuote).joined(separator: " ")
        return (shell, ["-l", "-i", "-c", command], (shell as NSString).lastPathComponent)
    }

    /// POSIX single-quote one argv token so it survives the shell's `-c` parsing intact.
    nonisolated static func shQuote(_ token: String) -> String {
        "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public func terminate() {
        terminalView.terminate()
    }

    public func setFont(size: CGFloat) {
        terminalView.font = .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Apply a colour preset to the live terminal view: foreground/background always, plus
    /// cursor, selection and the 16-colour ANSI palette when the preset defines them (the
    /// wasteland preset does). SwiftTerm's public Color init takes 16-bit channels.
    public func applyTheme(_ theme: TerminalTheme) {
        terminalView.nativeForegroundColor = theme.foreground
        terminalView.nativeBackgroundColor = theme.background
        if let cursor = theme.cursorColor { terminalView.caretColor = cursor }
        if let selection = theme.selectionColor { terminalView.selectedTextBackgroundColor = selection }
        if let ansi = theme.ansi, ansi.count == 16 {
            terminalView.installColors(ansi.map { c in
                SwiftTerm.Color(red: UInt16(c[0] * 65535),
                                green: UInt16(c[1] * 65535),
                                blue: UInt16(c[2] * 65535))
            })
        }
        terminalView.needsDisplay = true
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
