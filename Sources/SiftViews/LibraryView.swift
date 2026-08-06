import SwiftUI
import SiftCore
import SiftIndex
import SiftRuntime

/// What the sidebar can point at. Sessions get the three-column browse-and-search layout;
/// the tools take over the detail column on their own.
enum LibrarySection: Hashable {
    case sessions
    case dashboard
    case quickTask
    case tasks
    case loops
    case folders
    case brain

    var isSessions: Bool { self == .sessions }
}

/// The app: one ordinary macOS window, source list on the left, searchable session list in
/// the middle, detail on the right.
///
/// This replaced an emulated desktop — a window manager, a Dock, and one child NSWindow per
/// surface — which re-implemented what macOS already does and made every extra window cost
/// a re-render of all the others. The two things this app is actually used for, finding a
/// past session and running a quick task, are a list and a form.
public struct LibraryView: View {
    @Environment(IndexCoordinator.self) private var index
    @Environment(SessionRuntime.self) private var runtime
    @Environment(LiveSessionMonitor.self) private var monitor
    @Environment(ThemeStore.self) private var themes

    @State private var section: LibrarySection = .sessions
    @State private var askingAboutExtraction = false

    public init() {}

    public var body: some View {
        split
            .siftThemed(themes.theme)
            .sheet(isPresented: $askingAboutExtraction) { ExtractionConsentSheet() }
    }

    private var split: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 225, max: 320)
        } content: {
            SessionListView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 340)
        } detail: {
            detail
        }
        .navigationTitle("Sift")
        // The middle column used to be forced shut while a tool was open, to give the tool
        // the width. NavigationSplitView kept drawing it anyway, in a state that took no
        // clicks and no hover: search results appeared and then ignored the pointer. The
        // width was not worth a column that lies about being there.
        //
        // Picking a list or a project in the sidebar is a request to browse sessions.
        .onChange(of: index.sidebarSelection) { _, _ in section = .sessions }
        // So is picking a session. Without this, clicking a result while a tool is open
        // sets the selection and changes nothing on screen, because the detail column is
        // still showing the tool: the row looks like it did not register the click.
        .onChange(of: index.selectedSessionId) { _, id in
            if id != nil { section = .sessions }
        }
        .task {
            await index.initialLoad()
            monitor.start()
            runtime.requestNotificationAuthorization()
            // Asked once, on the first launch that reaches a usable window, rather than
            // left switched off in a Settings tab nobody opens.
            if !Preferences.knowledgeExtractionAsked { askingAboutExtraction = true }
        }
    }

    // MARK: - Sidebar

    /// `ProjectSidebar` already owns the session sources (lists + the 36 projects), so it is
    /// reused whole rather than rebuilt as List rows; the tools sit under it.
    private var sidebar: some View {
        VStack(spacing: 0) {
            ProjectSidebar()
            Divider()
            tools
            statusBar
        }
    }

    private var tools: some View {
        VStack(spacing: 1) {
            toolRow("Quick task", "bolt.fill", .quickTask)
            toolRow("Scheduled", "clock.arrow.2.circlepath", .tasks)
            toolRow("Loops", "arrow.triangle.2.circlepath", .loops)
            toolRow("My folders", "folder", .folders)
            toolRow("Knowledge", "brain", .brain)
            toolRow("Overview", "chart.bar.doc.horizontal", .dashboard)
            settingsRow
        }
        .padding(.vertical, 6)
    }

    /// Themes and the extraction switch live in Settings, and ⌘, is not something people
    /// go looking for. The sidebar is where the rest of the app is reached from, so this
    /// is reached the same way.
    private var settingsRow: some View {
        let theme = themes.theme
        return SettingsLink {
            HStack(spacing: 8) {
                Image(systemName: "gearshape").frame(width: 16)
                Text("Settings")
                Spacer(minLength: 0)
                Text("⌘,").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(.clear, in: RoundedRectangle(cornerRadius: theme.cornerRadius))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }

    private func toolRow(_ title: String, _ icon: String, _ target: LibrarySection) -> some View {
        let theme = themes.theme
        return Button { section = target } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 16)
                Text(title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(section == target ? theme.selectionFill : .clear,
                        in: RoundedRectangle(cornerRadius: theme.cornerRadius))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }

    /// One quiet line: what's live and what the app itself is running. Live sessions come
    /// from the transcript directory, so sessions running in the user's terminal count too.
    private var statusBar: some View {
        HStack(spacing: 10) {
            if !monitor.liveSessionIds.isEmpty {
                Label("\(monitor.liveSessionIds.count) live", systemImage: "circle.fill")
                    .foregroundStyle(.green)
            }
            if runtime.runningCount > 0 {
                Label("\(runtime.runningCount) running", systemImage: "bolt.fill")
                    .foregroundStyle(.orange)
            }
            Spacer()
            if index.isScanning { ProgressView().controlSize(.small) }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        switch section {
        case .sessions:  SessionDetailPane()
        case .dashboard: DashboardView(onResume: resume, onNewFolder: newFolderSession)
        case .quickTask: QuickTaskView()
        case .tasks:     TasksView(mode: .scheduled)
        case .loops:     TasksView(mode: .loop)
        case .folders:   FoldersView()
        case .brain:     BrainView()
        }
    }

    private func resume(_ session: SessionSummary) {
        Task {
            try? await runtime.launch(SessionLaunchRequest(
                mode: .resume(sessionId: session.sessionId, agent: session.agent),
                cwd: session.cwd ?? NSHomeDirectory(),
                projectId: session.projectId,
                gitBranch: session.gitBranch,
                title: session.displayTitle))
        }
    }

    private func newFolderSession() {
        guard let url = chooseClaudeDirectory() else { return }
        Task {
            try? await runtime.launch(SessionLaunchRequest(
                mode: .fresh, cwd: url.path, projectId: "", title: url.lastPathComponent))
        }
    }
}
