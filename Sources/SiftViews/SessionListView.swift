import SwiftUI
import AppKit
import SiftCore
import SiftIndex
import SiftRuntime

struct SessionListView: View {
    @Environment(IndexCoordinator.self) private var index
    @Environment(SessionRuntime.self) private var runtime
    @Environment(LiveSessionMonitor.self) private var monitor
    @State private var editingSession: SessionSummary?
    @State private var hoveredId: String?
    @State private var sortOrder: SortOrder = .recency
    @State private var collapsed: Set<String> = []   // collapsed group ids (date sections you've folded)

    enum SortOrder: String, CaseIterable { case recency = "Last activity", name = "Ad", messages = "Messages" }

    var body: some View {
        @Bindable var index = index
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.border)
            // Pure-SwiftUI list (ScrollView + LazyVStack, not List/NSTableView) so it
            // tracks the emulated window's drag .offset smoothly without flicker.
            ScrollView {
                // Sticky date headers (Bugün / Dün / …) so a long list reads like a
                // calendar — you can find "what I did yesterday" without squinting at dates.
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(sessionGroups) { group in
                        Section {
                            if !collapsed.contains(group.id) {
                                ForEach(group.sessions) { session in
                                    sessionRowView(session)
                                    Divider().overlay(Palette.border).opacity(0.5)
                                }
                            }
                        } header: {
                            groupHeader(group)
                        }
                    }
                }
            }
            .overlay {
                if index.sessions.isEmpty && !index.isScanning {
                    emptyState
                }
            }
        }
        .background(Palette.base)
        .sheet(item: $editingSession) { session in
            SessionEditSheet(session: session).environment(index)
        }
        .onChange(of: index.searchText) { _, _ in
            Task { await index.runSearch() }
        }
    }

    /// A friendly, context-aware empty state: it speaks to *why* the list is empty (search
    /// missed, nothing pinned, quiet day, empty project) instead of one generic message.
    @ViewBuilder private var emptyState: some View {
        let info = emptyInfo
        ContentUnavailableView {
            Label(info.title, systemImage: info.icon)
        } description: {
            if let subtitle = info.subtitle { Text(subtitle) }
        }
    }

    private var emptyInfo: (icon: String, title: String, subtitle: String?) {
        if !index.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return ("magnifyingglass", "No results",
                    "No session matches \'\(index.searchText)\'. Try another word or a project name.")
        }
        switch index.sidebarSelection {
        case .pinned:
            return ("pin", "No pinned sessions", "Right-click a session and choose Pin to add it here.")
        case .today:
            return ("sun.max", "No sessions today", "You haven't opened a session today.")
        case .project:
            return ("folder", "No sessions in this project", nil)
        case .all:
            return ("tray", "No sessions yet", "Use + at the top right to start a new session.")
        }
    }

    /// In-window header (title, count, search, filter, new). Kept INSIDE this window
    /// so it never leaks into the host window's toolbar and jitters when the emulated
    /// window is dragged.
    @ViewBuilder private var header: some View {
        @Bindable var index = index
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(navTitle).font(Palette.font(15, weight: .bold)).foregroundStyle(Palette.textPrimary).lineLimit(1)
                Text("\(sortedSessions.count) sessions").font(Palette.font(10)).foregroundStyle(Palette.textDim)
            }
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(Palette.textDim)
                TextField("Search…", text: $index.searchText).textFieldStyle(.plain).font(Palette.font(12)).foregroundStyle(Palette.textPrimary).frame(minWidth: 70, maxWidth: 130)
                // One-tap clear, so wiping a search doesn't mean selecting + deleting by hand.
                if !index.searchText.isEmpty {
                    Button { index.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(Palette.textDim)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(Palette.surfaceHi, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.border))
            filterMenu
                .foregroundStyle(Palette.accent)
            newMenu
                .foregroundStyle(Palette.accent)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(Palette.surface)
    }

    @ViewBuilder private var filterMenu: some View {
        @Bindable var index = index
        Menu {
            Picker("Sort", selection: $sortOrder) {
                ForEach(SortOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Divider()
            Picker("Time range", selection: $index.timeRange) {
                Text("All").tag(IndexCoordinator.TimeRange.all)
                Text("Today").tag(IndexCoordinator.TimeRange.today)
                Text("Last 7 days").tag(IndexCoordinator.TimeRange.week)
                Text("Last 30 days").tag(IndexCoordinator.TimeRange.month)
            }
            if !index.branches.isEmpty {
                Picker("Dal", selection: $index.branchFilter) {
                    Text("All").tag(String?.none)
                    ForEach(index.branches, id: \.self) { branch in
                        Text(branch).tag(String?.some(branch))
                    }
                }
            }
            if !index.entrypoints.isEmpty {
                Picker("Entry point", selection: $index.entrypointFilter) {
                    Text("All").tag(String?.none)
                    ForEach(index.entrypoints, id: \.self) { entry in
                        Text(entry).tag(String?.some(entry))
                    }
                }
            }
            if !index.allTags.isEmpty {
                Picker("Etiket", selection: $index.tagFilter) {
                    Text("All").tag(String?.none)
                    ForEach(index.allTags, id: \.self) { tag in
                        Text(tag).tag(String?.some(tag))
                    }
                }
            }
            Divider()
            Toggle("Only my sessions", isOn: $index.onlyUserSessions)
            Toggle("Show archived", isOn: $index.showArchived)
            if index.hasActiveFilters {
                Button("Filtreleri temizle", systemImage: "xmark.circle") { index.clearFilters() }
            }
        } label: {
            Image(systemName: index.hasActiveFilters
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter by date, branch, or entry point")
    }

    @ViewBuilder private var newMenu: some View {
        Menu {
            Button("In selected project", systemImage: "plus", action: newSession)
            Button("Choose folder…", systemImage: "folder.badge.plus", action: newInChosenFolder)
                .keyboardShortcut("n", modifiers: .command)
            // Recent project folders as one-tap starts, so a basic user can launch Claude
            // where they usually work without digging through a file dialog.
            if !recentProjects.isEmpty {
                Divider()
                Section("Start in a recent project") {
                    ForEach(recentProjects) { project in
                        Button { newInProject(project) } label: {
                            Label(project.displayName, systemImage: "folder.fill")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
        } primaryAction: {
            newSession()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("New session: in the selected project, a recent one, or a folder you pick (⌘N)")
    }

    /// The handful of most-recent existing project folders, for the "+" quick-start menu.
    private var recentProjects: [Project] {
        Array(index.projects.filter(\.exists).prefix(5))
    }

    private func rowBackground(_ id: String) -> Color {
        if index.selectedSessionId == id { return Palette.accent.opacity(0.18) }
        if hoveredId == id { return Palette.surfaceHi }
        return .clear
    }

    /// Sessions in the chosen order, with pinned ones kept on top (stable within each group).
    /// The "only my sessions" filter runs at the SQL layer (IndexCoordinator.onlyUserSessions),
    /// so here we just sort whatever the index already handed us.
    private var sortedSessions: [SessionSummary] {
        let base: [SessionSummary]
        switch sortOrder {
        case .recency: base = index.sessions
        case .name: base = index.sessions.sorted {
            $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
        }
        case .messages: base = index.sessions.sorted { $0.messageCount > $1.messageCount }
        }
        return base.filter(\.pinned) + base.filter { !$0.pinned }
    }

    /// Sessions split into friendly sections. Pinned float into their own group on top;
    /// in recency order the rest fall into Bugün / Dün / Son 7 gün / Daha eski buckets.
    /// Other sort orders show one flat (header-less) group so date labels never lie.
    private var sessionGroups: [SessionGroup] {
        let pinned = sortedSessions.filter(\.pinned)
        let rest = sortedSessions.filter { !$0.pinned }
        var groups: [SessionGroup] = []
        if !pinned.isEmpty { groups.append(SessionGroup(id: "pinned", title: "Pinned", sessions: pinned)) }

        guard sortOrder == .recency else {
            if !rest.isEmpty { groups.append(SessionGroup(id: "all", title: "", sessions: rest)) }
            return groups
        }

        let cal = Calendar.current
        let startToday = cal.startOfDay(for: Date())
        let startYesterday = cal.date(byAdding: .day, value: -1, to: startToday) ?? startToday
        let startWeek = cal.date(byAdding: .day, value: -7, to: startToday) ?? startToday
        var today: [SessionSummary] = [], yesterday: [SessionSummary] = []
        var week: [SessionSummary] = [], older: [SessionSummary] = []
        for session in rest {
            guard let date = session.lastActivity else { older.append(session); continue }
            if date >= startToday { today.append(session) }
            else if date >= startYesterday { yesterday.append(session) }
            else if date >= startWeek { week.append(session) }
            else { older.append(session) }
        }
        func add(_ title: String, _ items: [SessionSummary]) {
            if !items.isEmpty { groups.append(SessionGroup(id: title, title: title, sessions: items)) }
        }
        add("Today", today)
        add("Yesterday", yesterday)
        add("Last 7 days", week)
        add("Older", older)
        return groups
    }

    /// A single session row with all its chrome (project stripe, hover, tap, context menu),
    /// pulled out so the grouped list body stays readable.
    @ViewBuilder
    private func sessionRowView(_ session: SessionSummary) -> some View {
        SessionRow(session: session, isLive: isLive(session.sessionId))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground(session.sessionId))
            .overlay(alignment: .leading) {
                // A stable per-project colour stripe so sessions visually group by project.
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(ProjectPalette.color(for: session.cwd ?? session.projectId))
                    .frame(width: 3)
                    .padding(.vertical, 5)
                    .opacity(session.archived ? 0.4 : 0.9)
            }
            .contentShape(Rectangle())
            .onTapGesture { index.selectedSessionId = session.sessionId }
            .contextMenu { rowContextMenu(session) }
            .overlay(alignment: .trailing) {
                if hoveredId == session.sessionId { rowHoverActions(session) }
            }
            // Hover has to be the OUTERMOST modifier, after the overlay. Modifiers wrap
            // outward, so with `.onHover` applied first the actions capsule ends up layered
            // above the hover region: moving onto a button reported hover=false, the capsule
            // vanished, the cursor fell back onto the row, and it reappeared — flickering
            // many times a second and making the buttons almost impossible to click.
            .onHover { hoveredId = $0 ? session.sessionId : (hoveredId == session.sessionId ? nil : hoveredId) }
    }

    /// Floating quick actions revealed on hover (open + pin). Right-click hides these same
    /// actions in a menu most people never find; surfacing them on hover makes the common
    /// moves visible without any jargon.
    @ViewBuilder
    private func rowHoverActions(_ session: SessionSummary) -> some View {
        HStack(spacing: 2) {
            Button { open(session) } label: { Image(systemName: "play.fill") }
                .help("Open this session")
            Button { index.togglePin(session.sessionId) } label: {
                Image(systemName: session.pinned ? "pin.slash" : "pin")
            }
            .help(session.pinned ? "Unpin" : "Pin")
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(Palette.accent)
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(Palette.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.border))
        .padding(.trailing, 10)
    }

    @ViewBuilder
    private func rowContextMenu(_ session: SessionSummary) -> some View {
        Button(session.pinned ? "Unpin" : "Pin",
               systemImage: session.pinned ? "pin.slash" : "pin") { index.togglePin(session.sessionId) }
        Button(session.archived ? "Unarchive" : "Archive",
               systemImage: session.archived ? "tray.and.arrow.up" : "archivebox") { index.toggleArchive(session.sessionId) }
        Button("Edit (name / tags)…", systemImage: "pencil") { editingSession = session }
        Divider()
        Button("Copy resume command", systemImage: "doc.on.doc") { copyResumeCommand(session) }
        Button("Copy session ID", systemImage: "number") { copyToPasteboard(session.sessionId) }
        if let cwd = session.cwd {
            Button("Reveal in Finder", systemImage: "folder") { openInFinder(cwd) }
        }
        Button("Reveal transcript file", systemImage: "doc.text.magnifyingglass") { revealInFinder(session.filePath) }
    }

    /// Sticky section header: tap to fold/unfold the group. Shows a chevron, an uppercase
    /// date label and the count, so you can collapse the old pile and focus on recent work.
    @ViewBuilder
    private func groupHeader(_ group: SessionGroup) -> some View {
        if group.title.isEmpty {
            EmptyView()
        } else {
            let isCollapsed = collapsed.contains(group.id)
            Button {
                if isCollapsed { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2).foregroundStyle(Palette.textDim)
                    if group.id == "pinned" {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Palette.acid)
                    }
                    Text(group.title).font(Palette.font(10, weight: .semibold)).foregroundStyle(Palette.textDim).textCase(.uppercase)
                    Text("\(group.sessions.count)").font(Palette.font(10)).foregroundStyle(Palette.textDim)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surface)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Expand this section" : "Collapse this section")
        }
    }

    private func isLive(_ sessionId: String) -> Bool {
        runtime.liveSessionIds.contains(sessionId) || monitor.liveSessionIds.contains(sessionId)
    }

    private var navTitle: String {
        switch index.sidebarSelection {
        case .all: return "All sessions"
        case .today: return "Today"
        case .pinned: return "Pinned"
        case .project(let id): return index.projects.first(where: { $0.id == id })?.displayName ?? "Project"
        }
    }

    @MainActor
    private func open(_ session: SessionSummary) {
        Task {
            try? await runtime.launch(SessionLaunchRequest(
                mode: .resume(sessionId: session.sessionId),
                cwd: session.cwd ?? NSHomeDirectory(),
                projectId: session.projectId,
                gitBranch: session.gitBranch,
                title: session.displayTitle))
        }
    }

    @MainActor
    private func newSession() {
        let cwd: String
        if let pid = index.selectedProjectId,
           let project = index.projects.first(where: { $0.id == pid }),
           project.exists {
            cwd = project.decodedPath
        } else {
            cwd = NSHomeDirectory()
        }
        Task {
            try? await runtime.launch(SessionLaunchRequest(
                mode: .fresh,
                cwd: cwd,
                projectId: index.selectedProjectId ?? "",
                title: "New session"
            ))
        }
    }

    @MainActor
    private func newInChosenFolder() {
        guard let url = chooseClaudeDirectory() else { return }
        Task {
            try? await runtime.launch(SessionLaunchRequest(
                mode: .fresh,
                cwd: url.path,
                projectId: "",
                title: url.lastPathComponent
            ))
        }
    }

    @MainActor
    private func newInProject(_ project: Project) {
        Task {
            try? await runtime.launch(SessionLaunchRequest(
                mode: .fresh,
                cwd: project.decodedPath,
                projectId: project.id,
                title: project.displayName
            ))
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copyResumeCommand(_ session: SessionSummary) {
        let cwd = session.cwd ?? NSHomeDirectory()
        copyToPasteboard("cd '\(cwd)' && claude --resume \(session.sessionId)")
    }

    private func openInFinder(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

/// One labelled section of the session list (a pinned group or a date bucket).
private struct SessionGroup: Identifiable {
    let id: String
    let title: String
    let sessions: [SessionSummary]
}

struct SessionRow: View {
    let session: SessionSummary
    let isLive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(isLive ? Palette.accent : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .siftGlow(Palette.accent, radius: isLive ? 5 : 0)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if session.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(Palette.acid)
                    }
                    if session.archived {
                        Image(systemName: "archivebox")
                            .font(.caption2)
                            .foregroundStyle(Palette.textDim)
                    }
                    Text(session.displayTitle)
                        .font(Palette.font(13, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(session.archived ? Palette.textDim : Palette.textPrimary)
                }
                if let snippet = session.snippet, !snippet.isEmpty {
                    Text(SessionRow.highlight(snippet))
                        .font(.caption)
                        .lineLimit(2)
                } else if let message = session.firstMessage, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Palette.textDim)
                        .lineLimit(2)
                }
                HStack(spacing: 10) {
                    if let projectName {
                        Label(projectName, systemImage: "folder.fill")
                            .foregroundStyle(ProjectPalette.color(for: session.cwd ?? ""))
                    }
                    if let branch = session.gitBranch, !branch.isEmpty, branch != "HEAD" {
                        Label(branch, systemImage: "arrow.triangle.branch")
                    }
                    if let date = session.lastActivity {
                        Text(date, format: .relative(presentation: .named))
                    }
                    if session.messageCount > 0 {
                        Label("\(session.messageCount)", systemImage: "bubble.left.and.bubble.right")
                    }
                }
                .font(.caption2)
                .foregroundStyle(Palette.textDim)

                if !session.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(session.tags.prefix(4), id: \.self) { tag in
                            Text(tag)
                                .font(Palette.font(10))
                                .foregroundStyle(Palette.cyan)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Palette.cyan.opacity(0.12), in: Capsule())
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    /// The session's project folder name (last path component of its cwd), for a quick
    /// "which project is this" tag — handy in the all-sessions list.
    private var projectName: String? {
        guard let cwd = session.cwd, !cwd.isEmpty else { return nil }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return (name.isEmpty || name == "/") ? nil : name
    }

    /// Builds an AttributedString from an FTS snippet, accenting the matched runs
    /// (delimited by char(1)…char(2)) and dimming the surrounding context.
    static func highlight(_ snippet: String) -> AttributedString {
        let normalized = snippet.replacingOccurrences(of: "\n", with: " ")
        var result = AttributedString()
        var buffer = ""
        var inMatch = false
        func flush() {
            guard !buffer.isEmpty else { return }
            var piece = AttributedString(buffer)
            if inMatch {
                piece.foregroundColor = Palette.acid
                piece.inlinePresentationIntent = .stronglyEmphasized
            } else {
                piece.foregroundColor = Palette.textDim
            }
            result.append(piece)
            buffer = ""
        }
        for character in normalized {
            switch character {
            case "\u{1}": flush(); inMatch = true
            case "\u{2}": flush(); inMatch = false
            default: buffer.append(character)
            }
        }
        flush()
        return result
    }
}

/// Stable, pleasant colour per project key (cwd/projectId). Same key → same hue across
/// the whole app, so sessions and projects read as colour-coded groups.
enum ProjectPalette {
    static func color(for key: String) -> Color {
        var hash: UInt64 = 1469598103934665603            // FNV-1a offset basis
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.92)
    }
}
