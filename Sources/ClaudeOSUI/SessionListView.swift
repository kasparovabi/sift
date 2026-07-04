import SwiftUI
import AppKit
import ClaudeOSCore
import ClaudeOSIndex
import ClaudeOSRuntime

struct SessionListView: View {
    @Environment(IndexCoordinator.self) private var index
    @Environment(SessionRuntime.self) private var runtime
    @Environment(LiveSessionMonitor.self) private var monitor
    @State private var editingSession: SessionSummary?
    @State private var hoveredId: String?
    @State private var sortOrder: SortOrder = .recency
    @State private var collapsed: Set<String> = []   // collapsed group ids (date sections you've folded)

    enum SortOrder: String, CaseIterable { case recency = "Son etkinlik", name = "Ad", messages = "Mesaj sayısı" }

    var body: some View {
        @Bindable var index = index
        VStack(spacing: 0) {
            header
            Divider().overlay(Wasteland.border)
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
                                    Divider().overlay(Wasteland.border).opacity(0.5)
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
        .background(Wasteland.base)
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
            return ("magnifyingglass", "Sonuç yok",
                    "'\(index.searchText)' için bir oturum bulamadım. Farklı bir kelime ya da proje adı dene.")
        }
        switch index.sidebarSelection {
        case .pinned:
            return ("pin", "Sabitlenmiş oturum yok", "Bir oturuma sağ tıklayıp 'Sabitle' diyerek buraya ekleyebilirsin.")
        case .today:
            return ("sun.max", "Bugün oturum yok", "Bugün henüz bir oturum açmadın.")
        case .project:
            return ("folder", "Bu projede oturum yok", nil)
        case .all:
            return ("tray", "Henüz oturum yok", "Sağ üstteki + ile yeni bir oturum başlatabilirsin.")
        }
    }

    /// In-window header (title, count, search, filter, new). Kept INSIDE this window
    /// so it never leaks into the host window's toolbar and jitters when the emulated
    /// window is dragged.
    @ViewBuilder private var header: some View {
        @Bindable var index = index
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(navTitle).font(Wasteland.font(15, weight: .bold)).foregroundStyle(Wasteland.textPrimary).lineLimit(1)
                Text("\(sortedSessions.count) oturum").font(Wasteland.font(10)).foregroundStyle(Wasteland.textDim)
            }
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(Wasteland.textDim)
                TextField("Ara…", text: $index.searchText).textFieldStyle(.plain).font(Wasteland.font(12)).foregroundStyle(Wasteland.textPrimary).frame(minWidth: 70, maxWidth: 130)
                // One-tap clear, so wiping a search doesn't mean selecting + deleting by hand.
                if !index.searchText.isEmpty {
                    Button { index.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(Wasteland.textDim)
                    }
                    .buttonStyle(.plain)
                    .help("Aramayı temizle")
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(Wasteland.surfaceHi, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Wasteland.border))
            filterMenu
                .foregroundStyle(Wasteland.accent)
            newMenu
                .foregroundStyle(Wasteland.accent)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(Wasteland.surface)
    }

    @ViewBuilder private var filterMenu: some View {
        @Bindable var index = index
        Menu {
            Picker("Sırala", selection: $sortOrder) {
                ForEach(SortOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Divider()
            Picker("Zaman aralığı", selection: $index.timeRange) {
                Text("Tümü").tag(IndexCoordinator.TimeRange.all)
                Text("Bugün").tag(IndexCoordinator.TimeRange.today)
                Text("Son 7 gün").tag(IndexCoordinator.TimeRange.week)
                Text("Son 30 gün").tag(IndexCoordinator.TimeRange.month)
            }
            if !index.branches.isEmpty {
                Picker("Dal", selection: $index.branchFilter) {
                    Text("Tümü").tag(String?.none)
                    ForEach(index.branches, id: \.self) { branch in
                        Text(branch).tag(String?.some(branch))
                    }
                }
            }
            if !index.entrypoints.isEmpty {
                Picker("Giriş noktası", selection: $index.entrypointFilter) {
                    Text("Tümü").tag(String?.none)
                    ForEach(index.entrypoints, id: \.self) { entry in
                        Text(entry).tag(String?.some(entry))
                    }
                }
            }
            if !index.allTags.isEmpty {
                Picker("Etiket", selection: $index.tagFilter) {
                    Text("Tümü").tag(String?.none)
                    ForEach(index.allTags, id: \.self) { tag in
                        Text(tag).tag(String?.some(tag))
                    }
                }
            }
            Divider()
            Toggle("Sadece benim oturumlarım", isOn: $index.onlyUserSessions)
            Toggle("Arşivlenenleri göster", isOn: $index.showArchived)
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
        .help("Tarih, dal veya giriş noktasına göre filtrele")
    }

    @ViewBuilder private var newMenu: some View {
        Menu {
            Button("Seçili projede", systemImage: "plus", action: newSession)
            Button("Klasör seç…", systemImage: "folder.badge.plus", action: newInChosenFolder)
                .keyboardShortcut("n", modifiers: .command)
            // Recent project folders as one-tap starts, so a basic user can launch Claude
            // where they usually work without digging through a file dialog.
            if !recentProjects.isEmpty {
                Divider()
                Section("Son projelerde başlat") {
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
        .help("Yeni oturum: seçili projede, son projelerde ya da seçtiğin klasörde (⌘N)")
    }

    /// The handful of most-recent existing project folders, for the "+" quick-start menu.
    private var recentProjects: [Project] {
        Array(index.projects.filter(\.exists).prefix(5))
    }

    private func rowBackground(_ id: String) -> Color {
        if index.selectedSessionId == id { return Wasteland.accent.opacity(0.18) }
        if hoveredId == id { return Wasteland.surfaceHi }
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
        if !pinned.isEmpty { groups.append(SessionGroup(id: "pinned", title: "Sabitlenenler", sessions: pinned)) }

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
        add("Bugün", today)
        add("Dün", yesterday)
        add("Son 7 gün", week)
        add("Daha eski", older)
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
            .onHover { hoveredId = $0 ? session.sessionId : (hoveredId == session.sessionId ? nil : hoveredId) }
            .contextMenu { rowContextMenu(session) }
            .overlay(alignment: .trailing) {
                if hoveredId == session.sessionId { rowHoverActions(session) }
            }
    }

    /// Floating quick actions revealed on hover (open + pin). Right-click hides these same
    /// actions in a menu most people never find; surfacing them on hover makes the common
    /// moves visible without any jargon.
    @ViewBuilder
    private func rowHoverActions(_ session: SessionSummary) -> some View {
        HStack(spacing: 2) {
            Button { open(session) } label: { Image(systemName: "play.fill") }
                .help("Bu oturumu aç")
            Button { index.togglePin(session.sessionId) } label: {
                Image(systemName: session.pinned ? "pin.slash" : "pin")
            }
            .help(session.pinned ? "Sabitlemeyi kaldır" : "Sabitle")
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(Wasteland.accent)
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(Wasteland.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Wasteland.border))
        .padding(.trailing, 10)
    }

    @ViewBuilder
    private func rowContextMenu(_ session: SessionSummary) -> some View {
        Button(session.pinned ? "Sabitlemeyi kaldır" : "Sabitle",
               systemImage: session.pinned ? "pin.slash" : "pin") { index.togglePin(session.sessionId) }
        Button(session.archived ? "Arşivden çıkar" : "Arşivle",
               systemImage: session.archived ? "tray.and.arrow.up" : "archivebox") { index.toggleArchive(session.sessionId) }
        Button("Düzenle (ad / etiket)…", systemImage: "pencil") { editingSession = session }
        Divider()
        Button("Sürdürme komutunu kopyala", systemImage: "doc.on.doc") { copyResumeCommand(session) }
        Button("Oturum id'sini kopyala", systemImage: "number") { copyToPasteboard(session.sessionId) }
        if let cwd = session.cwd {
            Button("Dizini Finder'da aç", systemImage: "folder") { openInFinder(cwd) }
        }
        Button("Transkript dosyasını göster", systemImage: "doc.text.magnifyingglass") { revealInFinder(session.filePath) }
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
                        .font(.caption2).foregroundStyle(Wasteland.textDim)
                    if group.id == "pinned" {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Wasteland.acid)
                    }
                    Text(group.title).font(Wasteland.font(10, weight: .semibold)).foregroundStyle(Wasteland.textDim).textCase(.uppercase)
                    Text("\(group.sessions.count)").font(Wasteland.font(10)).foregroundStyle(Wasteland.textDim)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Wasteland.surface)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Bu bölümü aç" : "Bu bölümü gizle")
        }
    }

    private func isLive(_ sessionId: String) -> Bool {
        runtime.liveSessionIds.contains(sessionId) || monitor.liveSessionIds.contains(sessionId)
    }

    private var navTitle: String {
        switch index.sidebarSelection {
        case .all: return "Tüm oturumlar"
        case .today: return "Bugün"
        case .pinned: return "Sabitlenenler"
        case .project(let id): return index.projects.first(where: { $0.id == id })?.displayName ?? "Proje"
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
                title: "Yeni oturum"
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
                .fill(isLive ? Wasteland.accent : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .neonGlow(Wasteland.accent, radius: isLive ? 5 : 0)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if session.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(Wasteland.acid)
                    }
                    if session.archived {
                        Image(systemName: "archivebox")
                            .font(.caption2)
                            .foregroundStyle(Wasteland.textDim)
                    }
                    Text(session.displayTitle)
                        .font(Wasteland.font(13, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(session.archived ? Wasteland.textDim : Wasteland.textPrimary)
                }
                if let snippet = session.snippet, !snippet.isEmpty {
                    Text(SessionRow.highlight(snippet))
                        .font(.caption)
                        .lineLimit(2)
                } else if let message = session.firstMessage, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Wasteland.textDim)
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
                .foregroundStyle(Wasteland.textDim)

                if !session.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(session.tags.prefix(4), id: \.self) { tag in
                            Text(tag)
                                .font(Wasteland.font(10))
                                .foregroundStyle(Wasteland.cyan)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Wasteland.cyan.opacity(0.12), in: Capsule())
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
                piece.foregroundColor = Wasteland.acid
                piece.inlinePresentationIntent = .stronglyEmphasized
            } else {
                piece.foregroundColor = Wasteland.textDim
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
