import SwiftUI
import ClaudeOSRuntime

/// Hosts a single detached session in its own window (great for a second
/// monitor). Closing the window or hitting "reattach" returns the session to the
/// tiled workspace. The terminal NSView simply moves between view trees; the PTY
/// keeps running throughout.
public struct DetachedTerminalView: View {
    @Environment(SessionRuntime.self) private var runtime
    @Environment(\.dismiss) private var dismiss
    let sessionId: TerminalSession.ID?

    public init(sessionId: TerminalSession.ID?) {
        self.sessionId = sessionId
    }

    public var body: some View {
        Group {
            if let id = sessionId, let session = runtime.sessions.first(where: { $0.id == id }) {
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(session.needsAttention ? .orange : (session.isRunning ? .green : .secondary))
                            .frame(width: 7, height: 7)
                        Text(session.title).font(.headline).lineLimit(1)
                        Spacer()
                        Button { dismiss() } label: {
                            Label("Çalışma alanına geri al", systemImage: "rectangle.on.rectangle")
                        }
                        .controlSize(.small)
                    }
                    .padding(8)
                    Divider()
                    TerminalEmulatorView(session: session)
                }
                .onDisappear { runtime.reattach(id) }
            } else {
                ContentUnavailableView("Oturum kapandı", systemImage: "xmark.circle")
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}
