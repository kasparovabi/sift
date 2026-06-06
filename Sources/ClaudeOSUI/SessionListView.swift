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

    var body: some View {
        @Bindable var index = index
        VStack(spacing: 0) {
            header
            Divider()
            List(index.sessions, selection: $index.selectedSessionId) { session in
                SessionRow(session: session, isLive: isLive(session.sessionId))
                    .contextMenu {
                        Button(session.pinned ? "Sabitlemeyi kaldır" : "Sabitle",
                               systemImage: session.pinned ? "pin.slash" : "pin") {
                            index.togglePin(session.sessionId)
                        }
                        Button(session.archived ? "Arşivden çıkar" : "Arşivle",
                               systemImage: session.archived ? "tray.and.arrow.up" : "archivebox") {
                            index.toggleArchive(session.sessionId)
                        }
                        Button("Düzenle (ad / etiket)…", systemImage: "pencil") { editingSession = session }
                        Divider()
                        Button("Resume komutunu kopyala", systemImage: "doc.on.doc") {
                            copyResumeCommand(session)
                        }
                        Button("Oturum id'sini kopyala", systemImage: "number") {
                            copyToPasteboard(session.sessionId)
                        }
                        if let cwd = session.cwd {
                            Button("Dizini Finder'da aç", systemImage: "folder") { openInFinder(cwd) }
                        }
                        Button("Transkript dosyasını göster", systemImage: "doc.text.magnifyingglass") {
                            revealInFinder(session.filePath)
                        }
                    }
            }
            .overlay {
                if index.sessions.isEmpty && !index.isScanning {
                    ContentUnavailableView.search
                }
            }
        }
        .sheet(item: $editingSession) { session in
            SessionEditSheet(session: session).environment(index)
        }
        .onChange(of: index.searchText) { _, _ in
            Task { await index.runSearch() }
        }
    }

    /// In-window header (title, count, search, filter, new). Kept INSIDE this window
    /// so it never leaks into the host window's toolbar and jitters when the emulated
    /// window is dragged.
    @ViewBuilder private var header: some View {
        @Bindable var index = index
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(navTitle).font(.headline).lineLimit(1)
                Text("\(index.sessions.count) oturum").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                TextField("Ara…", text: $index.searchText).textFieldStyle(.plain).frame(minWidth: 70, maxWidth: 130)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            filterMenu
            newMenu
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder private var filterMenu: some View {
        @Bindable var index = index
        Menu {
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
        } label: {
            Image(systemName: "plus")
        } primaryAction: {
            newSession()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Yeni oturum: seçili projede ya da seçtiğin klasörde (⌘N)")
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

struct SessionRow: View {
    let session: SessionSummary
    let isLive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(isLive ? Color.green : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if session.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if session.archived {
                        Image(systemName: "archivebox")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(session.displayTitle)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .foregroundStyle(session.archived ? .secondary : .primary)
                }
                if let snippet = session.snippet, !snippet.isEmpty {
                    Text(SessionRow.highlight(snippet))
                        .font(.caption)
                        .lineLimit(2)
                } else if let message = session.firstMessage, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 10) {
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
                .foregroundStyle(.secondary)

                if !session.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(session.tags.prefix(4), id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
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
                piece.foregroundColor = .accentColor
                piece.inlinePresentationIntent = .stronglyEmphasized
            } else {
                piece.foregroundColor = .secondary
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
