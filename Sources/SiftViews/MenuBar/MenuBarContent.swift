import SwiftUI
import AppKit
import SiftCore
import SiftIndex
import SiftRuntime

/// The menubar popover: a quick search over every session, the ones currently live, and the
/// recent ones. Stays available when the main window is closed.
///
/// "Live" comes from `LiveSessionMonitor`, which watches the session directory on disk — so
/// sessions opened in the user's own terminal still show up here.
public struct MenuBarContent: View {
    @Environment(IndexCoordinator.self) private var index
    @Environment(SessionRuntime.self) private var runtime
    @Environment(LiveSessionMonitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow

    @State private var query = ""
    @State private var hits: [SessionSummary] = []
    @State private var recents: [SessionSummary] = []

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            TextField("Search…", text: $query)
                .textFieldStyle(.roundedBorder)
            Divider()
            if query.isEmpty { recentSection } else { resultsSection }
            Divider()
            footer
        }
        .padding(10)
        .frame(width: 340)
        .task { recents = await index.recentUserSessions() }
        .onChange(of: query) { _, _ in Task { hits = await index.quickSearch(query, limit: 8) } }
    }

    private var header: some View {
        HStack {
            Image(systemName: "terminal.fill").foregroundStyle(.tint)
            Text("Sift").font(.headline)
            Spacer()
            if !monitor.liveSessionIds.isEmpty {
                Label("\(monitor.liveSessionIds.count) live", systemImage: "circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            if runtime.runningCount > 0 {
                Label("\(runtime.runningCount) running", systemImage: "bolt.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle("Recent sessions")
            ForEach(recents.prefix(8)) { session in
                Button { resume(session) } label: { row(session) }
                    .buttonStyle(.plain)
            }
        }
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            if hits.isEmpty {
                Text("No results").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(hits) { session in
                Button { resume(session) } label: { row(session) }
                    .buttonStyle(.plain)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button { showMainWindow() } label: { Label("Library", systemImage: "macwindow") }
            Spacer()
            Button { newSession() } label: { Label("New", systemImage: "plus") }
            Spacer()
            Button { NSApp.terminate(nil) } label: { Label("Quit", systemImage: "power") }
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.caption2).foregroundStyle(.secondary).textCase(.uppercase)
    }

    private func row(_ session: SessionSummary) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(monitor.liveSessionIds.contains(session.sessionId) ? Color.green : .clear)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(session.displayTitle).lineLimit(1)
                Text(session.cwd ?? "").font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2).padding(.horizontal, 4)
        .contentShape(Rectangle())
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "library")
    }

    private func resume(_ session: SessionSummary) {
        Task {
            try? await runtime.launch(SessionLaunchRequest(
                mode: .resume(sessionId: session.sessionId, agent: session.agent),
                cwd: session.cwd ?? NSHomeDirectory(),
                projectId: session.projectId,
                gitBranch: session.gitBranch,
                title: session.displayTitle
            ))
        }
    }

    private func newSession() {
        Task {
            try? await runtime.launch(SessionLaunchRequest(
                mode: .fresh, cwd: NSHomeDirectory(), projectId: "", title: "New session"
            ))
        }
    }
}
