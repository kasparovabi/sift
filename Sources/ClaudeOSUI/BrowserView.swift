import SwiftUI
import ClaudeOSIndex
import ClaudeOSRuntime

/// The Library window: three-column browse + search + tabbed terminal workspace,
/// with a status bar across the bottom.
public struct BrowserView: View {
    @Environment(IndexCoordinator.self) private var index
    @Environment(SessionRuntime.self) private var runtime
    @Environment(LiveSessionMonitor.self) private var monitor

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                ProjectSidebar()
                    .navigationSplitViewColumnWidth(min: 210, ideal: 250)
            } content: {
                SessionListView()
                    .navigationSplitViewColumnWidth(min: 340, ideal: 430)
            } detail: {
                WorkspaceView()
            }
            Divider()
            StatusBar()
        }
        .task { await index.initialLoad() }
        .task {
            monitor.start()
            runtime.requestNotificationAuthorization()
        }
    }
}

private struct StatusBar: View {
    @Environment(IndexCoordinator.self) private var index
    @Environment(SessionRuntime.self) private var runtime
    @Environment(LiveSessionMonitor.self) private var monitor

    var body: some View {
        HStack(spacing: 12) {
            if index.isScanning {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("Taranıyor…")
            } else {
                Text("\(index.totalSessionCount) oturum · \(index.projects.count) proje")
            }
            Spacer()
            if runtime.attentionCount > 0 {
                Label("\(runtime.attentionCount)", systemImage: "bell.fill").foregroundStyle(.orange)
            }
            if liveCount > 0 {
                Label("\(liveCount) canlı", systemImage: "bolt.fill").foregroundStyle(.green)
            }
            Text("\(Int(runtime.terminalFontSize))pt")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private var liveCount: Int {
        monitor.liveSessionIds.union(runtime.liveSessionIds).count
    }
}
