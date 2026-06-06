import SwiftUI
import ClaudeOSCore
import ClaudeOSIndex
import ClaudeOSRuntime

/// The control-center home, shown in the workspace when no session is open. Gives
/// an at-a-glance overview: stats, active sessions, pinned, recent, quick actions.
struct DashboardView: View {
    @Environment(IndexCoordinator.self) private var index
    @Environment(SessionRuntime.self) private var runtime
    let onResume: (SessionSummary) -> Void
    let onNewFolder: () -> Void

    @State private var recent: [SessionSummary] = []
    @State private var pinned: [SessionSummary] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                statsRow
                quickActions
                if !runtime.sessions.isEmpty { activeSection }
                if !pinned.isEmpty { sessionSection("Sabitlenenler", pinned, icon: "pin.fill") }
                if !recent.isEmpty { sessionSection("Son oturumlar", recent, icon: "clock") }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: index.totalSessionCount) { await load() }
        .onChange(of: runtime.sessions.count) { _, _ in Task { await load() } }
    }

    private func load() async {
        recent = await index.recentSessions(limit: 6)
        pinned = await index.pinnedSessions()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Claude OS").font(.largeTitle).fontWeight(.bold)
            Text("\(index.totalSessionCount) oturum · \(index.projects.count) proje")
                .foregroundStyle(.secondary)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 12) {
            stat("\(index.totalSessionCount)", "Oturum", "tray.full")
            stat("\(index.projects.count)", "Proje", "folder")
            stat("\(runtime.runningCount)", "Çalışan", "bolt.fill")
        }
    }

    private func stat(_ value: String, _ label: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(value).font(.title).fontWeight(.semibold)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private var quickActions: some View {
        HStack(spacing: 10) {
            Button(action: onNewFolder) {
                Label("Yeni oturum…", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            Button { Task { await index.rescan() } } label: {
                Label("Yeniden tara", systemImage: "arrow.clockwise")
            }
            .disabled(index.isScanning)
            Spacer()
            Text("Hızlı aç: ⌥Space").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Aktif oturumlar", systemImage: "bolt.fill").font(.headline)
            ForEach(runtime.sessions) { session in
                Button { runtime.focus(session) } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(session.needsAttention ? Color.orange : (session.isRunning ? Color.green : Color.secondary))
                            .frame(width: 8, height: 8)
                        Text(session.title).fontWeight(.medium).lineLimit(1)
                        Spacer()
                        Image(systemName: "arrow.right.circle").foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func sessionSection(_ title: String, _ items: [SessionSummary], icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.headline)
            ForEach(items) { session in
                Button { onResume(session) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "terminal").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.displayTitle).fontWeight(.medium).lineLimit(1)
                            Text(session.cwd ?? "")
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                        if let date = session.lastActivity {
                            Text(date, format: .relative(presentation: .named))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
