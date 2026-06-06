import SwiftUI
import SwiftTerm
import ClaudeOSCore

/// Embeds the real `claude` CLI inside a SwiftTerm PTY. This is the M0 proof:
/// full TUI fidelity in-window, correct working directory, a repaired
/// environment, and `--resume` continuity.
struct TerminalEmulatorView: NSViewRepresentable {
    let spec: ClaudeLaunchSpec
    let environment: [String]
    let binary: URL

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 820, height: 460))
        let (executable, args) = spec.argv(resolvedBinary: binary)
        terminal.startProcess(
            executable: executable,
            args: args,
            environment: environment,
            execName: "claude",
            currentDirectory: spec.workingDirectory.path
        )
        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
