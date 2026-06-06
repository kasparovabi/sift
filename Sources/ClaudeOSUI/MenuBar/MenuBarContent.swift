import SwiftUI
import AppKit
import ClaudeOSCore
import ClaudeOSIndex
import ClaudeOSRuntime

/// The menubar popover: live counts, a quick search, active + recent sessions,
/// and quick actions. Glanceable control surface that stays available even when
/// the Library window is closed.
public struct MenuBarContent: View {
    @Environment(IndexCoordinator.self) private var index
    @Environment(SessionRuntime.self) private var runtime
    @Environment(LiveSessionMonitor.self) private var monitor
    @Environment(DesktopWindowManager.self) private var windows

    @State private var query = ""
    @State private var hits: [SessionSummary] = []
    @State private var recents: [SessionSummary] = []

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            searchField
            Divider()
            if query.isEmpty {
                if !runtime.sessions.isEmpty { activeSection }
                recentSection
            } else {
                resultsSection
            }
            Divider()
            footer
        }
        .padding(10)
        .frame(width: 340)
        .task {
            recents = await index.recentSessions()
        }
        .onChange(of: query) { _, _ in Task { hits = await index.quickSearch(query, limit: 8) } }
        .onChange(of: runtime.sessions.count) { _, _ in Task { recents = await index.recentSessions() } }
    }

    private var header: some View {
        HStack {
            Image(systemName: "terminal.fill")
            Text("Claude OS").fontWeight(.semibold)
            Spacer()
            if runtime.runningCount > 0 {
                Label("\(runtime.runningCount)", systemImage: "circle.fill")
                    .foregroundStyle(.green).font(.caption)
            }
            if runtime.attentionCount > 0 {
                Label("\(runtime.attentionCount)", systemImage: "bell.fill")
                    .foregroundStyle(.orange).font(.caption)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Ara…", text: $query).textFieldStyle(.plain)
        }
        .padding(6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle("Aktif")
            ForEach(runtime.sessions) { session in
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    runtime.focus(session)
                } label: {
                    rowLabel(title: session.title, subtitle: session.workingDirectory.path,
                             dot: session.needsAttention ? .orange : (session.isRunning ? .green : .secondary))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle("Son oturumlar")
            ForEach(recents) { session in
                Button { resume(session) } label: {
                    rowLabel(title: session.displayTitle, subtitle: session.cwd ?? "", dot: nil)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            if hits.isEmpty {
                Text("Sonuç yok").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(hits) { session in
                Button { resume(session) } label: {
                    rowLabel(title: session.displayTitle, subtitle: session.cwd ?? "", dot: nil)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                windows.openFinder()
            } label: { Label("Finder", systemImage: "macwindow") }
            Spacer()
            Button { newSession() } label: { Label("Yeni", systemImage: "plus") }
            Spacer()
            Button { NSApp.terminate(nil) } label: { Label("Çıkış", systemImage: "power") }
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.caption2).foregroundStyle(.secondary).textCase(.uppercase)
    }

    private func rowLabel(title: String?, subtitle: String, dot: Color?) -> some View {
        HStack(spacing: 6) {
            Circle().fill(dot ?? .clear).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(title ?? "Başlıksız oturum").lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }

    private func resume(_ session: SessionSummary) {
        NSApp.activate(ignoringOtherApps: true)
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

    private func newSession() {
        NSApp.activate(ignoringOtherApps: true)
        Task {
            try? await runtime.launch(SessionLaunchRequest(
                mode: .fresh, cwd: NSHomeDirectory(), projectId: "", title: "Yeni oturum"
            ))
        }
    }
}
