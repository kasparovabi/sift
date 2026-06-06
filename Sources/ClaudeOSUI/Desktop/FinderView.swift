import SwiftUI
import ClaudeOSCore
import ClaudeOSIndex
import ClaudeOSRuntime

/// The "Finder" desktop window: browse/search sessions and projects, then open a
/// session as a terminal window. Reuses the project sidebar and session list; the
/// detail is a read-only preview with an Open action (terminals live on the
/// desktop, not inside this window).
struct FinderView: View {
    var body: some View {
        NavigationSplitView {
            ProjectSidebar()
                .navigationSplitViewColumnWidth(min: 175, ideal: 205)
        } content: {
            SessionListView()
                .navigationSplitViewColumnWidth(min: 290, ideal: 340)
        } detail: {
            FinderDetail()
        }
    }
}

private struct FinderDetail: View {
    @Environment(IndexCoordinator.self) private var index
    @Environment(SessionRuntime.self) private var runtime

    var body: some View {
        if let session = index.selectedSession() {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(session.displayTitle).font(.title2).fontWeight(.semibold)
                        VStack(alignment: .leading, spacing: 5) {
                            if let cwd = session.cwd { LabeledContent("Dizin", value: cwd) }
                            if let branch = session.gitBranch, !branch.isEmpty { LabeledContent("Dal", value: branch) }
                            if let entry = session.entrypoint { LabeledContent("Giriş", value: entry) }
                            if let date = session.lastActivity {
                                LabeledContent("Son etkinlik") { Text(date, format: .dateTime.day().month().year().hour().minute()) }
                            }
                        }
                        .font(.callout)
                        if let message = session.firstMessage, !message.isEmpty {
                            Divider()
                            Text("İlk mesaj").font(.caption).foregroundStyle(.secondary)
                            Text(message).textSelection(.enabled)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack {
                    Text(session.cwd ?? "")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button { open(session) } label: {
                        Label("Aç", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                }
                .padding(12)
            }
        } else {
            ContentUnavailableView(
                "Bir oturum seç",
                systemImage: "sidebar.squares.left",
                description: Text("Soldan bir oturum seç, Aç ile masaüstünde terminal penceresinde başlat.")
            )
        }
    }

    private func open(_ session: SessionSummary) {
        Task {
            try? await runtime.launch(SessionLaunchRequest(
                mode: .resume(sessionId: session.sessionId),
                cwd: session.cwd ?? NSHomeDirectory(),
                projectId: session.projectId,
                gitBranch: session.gitBranch,
                title: session.displayTitle
            ))
        }
    }
}
