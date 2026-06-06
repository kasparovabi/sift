import SwiftUI
import SwiftTerm

/// Hosts a `TerminalSession`'s SwiftTerm view in SwiftUI. The view instance is
/// owned by the session model, so `makeNSView` just hands it back and tab
/// switching never tears down the PTY.
public struct TerminalEmulatorView: NSViewRepresentable {
    public let session: TerminalSession

    public init(session: TerminalSession) {
        self.session = session
    }

    public func makeNSView(context: Context) -> LocalProcessTerminalView {
        session.terminalView
    }

    public func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
