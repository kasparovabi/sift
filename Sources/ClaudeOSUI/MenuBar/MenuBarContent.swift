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
            Divider().overlay(Wasteland.border)
            if query.isEmpty {
                if !runtime.sessions.isEmpty { activeSection }
                recentSection
            } else {
                resultsSection
            }
            Divider().overlay(Wasteland.border)
            footer
        }
        .padding(10)
        .frame(width: 340)
        .background(Wasteland.base)
        .foregroundStyle(Wasteland.textPrimary)
        .task {
            recents = await index.recentUserSessions()
        }
        .onChange(of: query) { _, _ in Task { hits = await index.quickSearch(query, limit: 8) } }
        .onChange(of: runtime.sessions.count) { _, _ in Task { recents = await index.recentUserSessions() } }
    }

    private var header: some View {
        HStack {
            Image(systemName: "terminal.fill")
                .foregroundStyle(Wasteland.accent)
            Text("Claude OS")
                .font(Wasteland.font(14, weight: .semibold))
                .foregroundStyle(Wasteland.textPrimary)
            Spacer()
            if runtime.runningCount > 0 {
                Label("\(runtime.runningCount)", systemImage: "circle.fill")
                    .foregroundStyle(Wasteland.accent).font(Wasteland.font(11))
            }
            if runtime.attentionCount > 0 {
                Label("\(runtime.attentionCount)", systemImage: "bell.fill")
                    .foregroundStyle(Wasteland.acid).font(Wasteland.font(11))
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Wasteland.textDim)
            TextField("Ara…", text: $query)
                .textFieldStyle(.plain)
                .font(Wasteland.font(12))
                .foregroundStyle(Wasteland.textPrimary)
        }
        .padding(6)
        .background(Wasteland.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Wasteland.border, lineWidth: 1))
    }

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle("Aktif")
            ForEach(runtime.sessions) { session in
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    runtime.focus(session)
                    if let windowId = windows.terminalWindowId(for: session.id) {
                        windows.restore(windowId)
                        windows.focus(windowId)
                    }
                } label: {
                    rowLabel(title: session.title, subtitle: session.workingDirectory.path,
                             dot: session.needsAttention ? Wasteland.acid : (session.isRunning ? Wasteland.accent : Wasteland.textDim))
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
                Text("Sonuç yok").font(Wasteland.font(11)).foregroundStyle(Wasteland.textDim)
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
        .font(Wasteland.font(12))
        .tint(Wasteland.accent)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(Wasteland.font(10)).foregroundStyle(Wasteland.textDim).textCase(.uppercase)
    }

    private func rowLabel(title: String?, subtitle: String, dot: Color?) -> some View {
        HStack(spacing: 6) {
            Circle().fill(dot ?? .clear).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(title ?? "Başlıksız oturum")
                    .font(Wasteland.font(12))
                    .foregroundStyle(Wasteland.textPrimary)
                    .lineLimit(1)
                Text(subtitle).font(Wasteland.font(10)).foregroundStyle(Wasteland.textDim).lineLimit(1).truncationMode(.head)
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
