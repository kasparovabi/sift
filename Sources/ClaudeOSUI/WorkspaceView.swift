import SwiftUI
import ClaudeOSCore
import ClaudeOSIndex
import ClaudeOSRuntime

/// The detail pane as a tiled workspace: several embedded `claude` terminals live
/// at once. İkili = resizable HSplitView, Izgara = resizable 2-D split grid,
/// Tek = single. Panes can be zoomed, reordered (drag/buttons/⌘⌥←→), detached to
/// their own window, split into a sibling, focused, or closed.
struct WorkspaceView: View {
    @Environment(IndexCoordinator.self) private var index
    @Environment(SessionRuntime.self) private var runtime
    @Environment(\.openWindow) private var openWindow

    enum Layout: String, CaseIterable, Identifiable {
        case focus, split, grid
        var id: String { rawValue }
        var label: String {
            switch self {
            case .focus: "Tek"
            case .split: "İkili"
            case .grid: "Izgara"
            }
        }
        var icon: String {
            switch self {
            case .focus: "rectangle"
            case .split: "rectangle.split.2x1"
            case .grid: "square.grid.2x2"
            }
        }
    }

    @State private var layout: Layout = .split
    @State private var showPreview = false
    @State private var zoomed: TerminalSession.ID?

    /// Sessions shown in the tiled workspace (detached ones live in their own windows).
    private var workspaceSessions: [TerminalSession] {
        runtime.sessions.filter { !runtime.detachedSessionIds.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            workspaceBar
            Divider()
            content
        }
        .onChange(of: runtime.activeSessionId) { _, newValue in
            if newValue != nil { showPreview = false }
        }
        .onChange(of: index.selectedSessionId) { _, sid in
            guard let sid else { return }
            if let live = runtime.session(forClaudeId: sid) {
                runtime.focus(live)
                showPreview = false
            } else {
                showPreview = true
            }
        }
    }

    private var workspaceBar: some View {
        HStack(spacing: 10) {
            Picker("Düzen", selection: $layout) {
                ForEach(Layout.allCases) { option in
                    Label(option.label, systemImage: option.icon).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)
            .disabled(showPreview || workspaceSessions.isEmpty || zoomed != nil)

            if !runtime.sessions.isEmpty {
                Text("\(runtime.runningCount) çalışıyor")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !runtime.sessions.isEmpty {
                Toggle(isOn: $showPreview) {
                    Label("Önizleme", systemImage: "doc.text.magnifyingglass")
                }
                .toggleStyle(.button)
                .controlSize(.small)
            }
        }
        .padding(8)
    }

    @ViewBuilder private var content: some View {
        if showPreview || workspaceSessions.isEmpty {
            previewContent
        } else {
            terminalArea
        }
    }

    @ViewBuilder private var previewContent: some View {
        if let session = index.selectedSession() {
            SessionPreview(session: session, isLive: runtime.session(forClaudeId: session.sessionId) != nil) {
                resume(session)
            }
        } else {
            DashboardView(onResume: { resume($0) }, onNewFolder: newFolder)
        }
    }

    @MainActor private func newFolder() {
        guard let url = chooseClaudeDirectory() else { return }
        Task {
            try? await runtime.launch(SessionLaunchRequest(
                mode: .fresh, cwd: url.path, projectId: "", title: url.lastPathComponent
            ))
        }
    }

    @ViewBuilder private var terminalArea: some View {
        if let zoomed, let session = workspaceSessions.first(where: { $0.id == zoomed }) {
            pane(session).padding(8)
        } else {
            switch layout {
            case .focus:
                if let active = workspaceSessions.first(where: { $0.id == runtime.activeSessionId }) ?? workspaceSessions.first {
                    pane(active).padding(8)
                }
            case .split:
                HSplitView {
                    ForEach(workspaceSessions) { session in
                        pane(session).frame(minWidth: 300)
                    }
                }
                .padding(8)
            case .grid:
                VSplitView {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HSplitView {
                            ForEach(row) { session in
                                pane(session).frame(minWidth: 280, minHeight: 180)
                            }
                        }
                        .frame(minHeight: 200)
                    }
                }
                .padding(8)
            }
        }
    }

    private var rows: [[TerminalSession]] {
        let items = workspaceSessions
        return stride(from: 0, to: items.count, by: 2).map {
            Array(items[$0..<min($0 + 2, items.count)])
        }
    }

    private func pane(_ session: TerminalSession) -> some View {
        TerminalPane(
            session: session,
            isActive: session.id == runtime.activeSessionId,
            isZoomed: zoomed == session.id,
            onFocus: { runtime.focus(session) },
            onZoom: { zoomed = (zoomed == session.id) ? nil : session.id },
            onNew: { newSession(inDirectoryOf: session) },
            onDetach: {
                if zoomed == session.id { zoomed = nil }
                openWindow(id: "terminal", value: session.id)
                runtime.detach(session)
            },
            onMoveLeft: { runtime.move(session, by: -1) },
            onMoveRight: { runtime.move(session, by: 1) },
            onClose: {
                if zoomed == session.id { zoomed = nil }
                runtime.close(session)
            },
            onDropReorder: { droppedId in runtime.moveSession(droppedId, toIndexOf: session.id) }
        )
    }

    @MainActor private func newSession(inDirectoryOf session: TerminalSession) {
        let cwd = session.workingDirectory.path
        Task {
            try? await runtime.launch(SessionLaunchRequest(
                mode: .fresh, cwd: cwd, projectId: "", title: "Yeni oturum"
            ))
        }
    }

    @MainActor private func resume(_ session: SessionSummary) {
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

private struct TerminalPane: View {
    let session: TerminalSession
    let isActive: Bool
    let isZoomed: Bool
    let onFocus: () -> Void
    let onZoom: () -> Void
    let onNew: () -> Void
    let onDetach: () -> Void
    let onMoveLeft: () -> Void
    let onMoveRight: () -> Void
    let onClose: () -> Void
    let onDropReorder: (TerminalSession.ID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(session.title).font(.caption).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 4)
                paneButton(isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                           isZoomed ? "Küçült" : "Büyüt", onZoom)
                Menu {
                    Button("Bu dizinde yeni oturum", systemImage: "plus", action: onNew)
                    Button("Ayrı pencereye taşı", systemImage: "macwindow", action: onDetach)
                    Divider()
                    Button("Sola taşı", systemImage: "chevron.left", action: onMoveLeft)
                    Button("Sağa taşı", systemImage: "chevron.right", action: onMoveRight)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 9, weight: .bold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                paneButton("xmark", "Kapat", onClose)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary)
            .contentShape(Rectangle())
            .onTapGesture(perform: onFocus)
            .draggable(session.id.uuidString)

            TerminalEmulatorView(session: session)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isActive ? Color.accentColor : Color.gray.opacity(0.25),
                              lineWidth: isActive ? 2 : 1)
        )
        .dropDestination(for: String.self) { items, _ in
            guard let first = items.first, let uid = UUID(uuidString: first) else { return false }
            onDropReorder(uid)
            return true
        }
    }

    private func paneButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private var statusColor: Color {
        if session.isExited { return .secondary }
        if session.needsAttention { return .orange }
        if session.isRunning { return .green }
        return .secondary
    }
}

private struct SessionPreview: View {
    let session: SessionSummary
    let isLive: Bool
    let onResume: () -> Void

    @State private var turns: [TranscriptTurn] = []
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(session.displayTitle)
                    .font(.title2)
                    .fontWeight(.semibold)
                metadata
                Divider()
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 24)
                } else if turns.isEmpty {
                    Text("Önizlenecek mesaj yok").foregroundStyle(.secondary)
                } else {
                    ForEach(turns) { TranscriptTurnView(turn: $0) }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(session.cwd ?? "?")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button(action: onResume) {
                    Label(isLive ? "Terminale geç" : "Gömülü terminalde resume et",
                          systemImage: isLive ? "arrow.right.circle" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
            }
            .padding(12)
            .background(.bar)
        }
        .task(id: session.sessionId) {
            isLoading = true
            turns = await TranscriptLoader.load(filePath: session.filePath, maxTurns: 100)
            isLoading = false
        }
    }

    @ViewBuilder private var metadata: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let branch = session.gitBranch, !branch.isEmpty { LabeledContent("Dal", value: branch) }
            if let entry = session.entrypoint { LabeledContent("Giriş", value: entry) }
            if let date = session.lastActivity {
                LabeledContent("Son etkinlik") { Text(date, format: .dateTime.day().month().year().hour().minute()) }
            }
        }
        .font(.callout)
    }
}

private struct TranscriptTurnView: View {
    let turn: TranscriptTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption2).fontWeight(.semibold).foregroundStyle(roleColor)
                Spacer()
                if let ts = turn.timestamp {
                    Text(ts, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Text(turn.text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(roleColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var label: String {
        switch turn.role {
        case .user: "Sen"
        case .assistant: "Claude"
        case .tool: "Araç"
        }
    }

    private var roleColor: Color {
        switch turn.role {
        case .user: .accentColor
        case .assistant: .green
        case .tool: .orange
        }
    }
}
