import SwiftUI
import ClaudeOSCore
import ClaudeOSIndex
import ClaudeOSRuntime

/// Spotlight-style finder: type to search all sessions, arrow keys to move,
/// Return to resume, Esc to close.
struct QuickOpenView: View {
    let index: IndexCoordinator
    let runtime: SessionRuntime
    let onResume: () -> Void
    let onClose: () -> Void

    @State private var query = ""
    @State private var results: [SessionSummary] = []
    @State private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Wasteland.accent)
                TextField("Tüm oturumlarda ara…", text: $query)
                    .textFieldStyle(.plain)
                    .font(Wasteland.font(20))
                    .foregroundStyle(Wasteland.textPrimary)
                    .tint(Wasteland.acid)
                    .focused($focused)
                    .onSubmit { resumeSelected() }
            }
            .padding(14)
            Divider().overlay(Wasteland.border)
            if !filteredCommands.isEmpty {
                VStack(spacing: 2) {
                    ForEach(filteredCommands) { command in
                        Button(action: command.run) {
                            HStack(spacing: 10) {
                                Image(systemName: command.icon).foregroundStyle(Wasteland.cyan).frame(width: 18)
                                Text(command.title)
                                    .font(Wasteland.font(13))
                                    .foregroundStyle(Wasteland.textPrimary)
                                Spacer()
                                Text("Eylem").font(Wasteland.font(10)).foregroundStyle(Wasteland.textDim)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
                Divider().overlay(Wasteland.border)
            }
            resultList
            Divider().overlay(Wasteland.border)
            // Visible controls so a keyboard-shy user knows how to drive the panel.
            HStack(spacing: 14) {
                hint("↑↓", "gez")
                hint("↵", "aç")
                hint("esc", "kapat")
                Spacer()
                if !results.isEmpty {
                    Text("\(results.count) oturum").font(Wasteland.font(10)).foregroundStyle(Wasteland.textDim)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .frame(width: 660, height: 440)
        .wastelandPanel(glow: true)
        .onAppear {
            focused = true
            Task { await reload() }
        }
        .onChange(of: query) { _, _ in selection = 0; Task { await reload() } }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.escape) { onClose(); return .handled }
    }

    @ViewBuilder private var resultList: some View {
        if results.isEmpty {
            VStack {
                Spacer()
                Text(query.isEmpty ? "Yazmaya başla" : "Sonuç yok")
                    .font(Wasteland.font(13))
                    .foregroundStyle(Wasteland.textDim)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { idx, session in
                            QuickOpenRow(session: session, isSelected: idx == selection)
                                .id(idx)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selection = idx
                                    resumeSelected()
                                }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selection) { _, newValue in
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(newValue, anchor: .center) }
                }
            }
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(Wasteland.font(10))
                .foregroundStyle(Wasteland.acid)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Wasteland.surfaceHi, in: RoundedRectangle(cornerRadius: 4))
            Text(label).font(Wasteland.font(10)).foregroundStyle(Wasteland.textDim)
        }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = max(0, min(results.count - 1, selection + delta))
    }

    private func reload() async {
        results = await index.quickSearch(query)
        selection = results.isEmpty ? 0 : min(selection, results.count - 1)
    }

    private func resumeSelected() {
        guard results.indices.contains(selection) else { return }
        let session = results[selection]
        Task {
            try? await runtime.launch(SessionLaunchRequest(
                mode: .resume(sessionId: session.sessionId),
                cwd: session.cwd ?? NSHomeDirectory(),
                projectId: session.projectId,
                gitBranch: session.gitBranch,
                title: session.displayTitle
            ))
        }
        onResume()
    }

    // MARK: - Command palette

    private struct PaletteCommand: Identifiable {
        let id = UUID()
        let title: String
        let icon: String
        let run: () -> Void
    }

    private var commands: [PaletteCommand] {
        [
            PaletteCommand(title: "Yeni oturum (klasör seç)", icon: "folder.badge.plus") {
                if let url = chooseClaudeDirectory() {
                    let request = SessionLaunchRequest(mode: .fresh, cwd: url.path, projectId: "", title: url.lastPathComponent)
                    Task { try? await runtime.launch(request) }
                }
                onResume()
            },
            PaletteCommand(title: "Tüm oturumları yeniden tara", icon: "arrow.clockwise") {
                Task { await index.rescan() }
                onResume()
            },
        ]
    }

    private var filteredCommands: [PaletteCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return commands }
        return commands.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }
}

private struct QuickOpenRow: View {
    let session: SessionSummary
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Project-tinted icon so rows read in the same colour system as the list and detail.
            Image(systemName: "terminal")
                .foregroundStyle(isSelected ? Wasteland.accent : ProjectPalette.color(for: session.cwd ?? session.projectId))
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayTitle)
                    .font(Wasteland.font(13, weight: .medium))
                    .lineLimit(1)
                Text(session.cwd ?? "")
                    .font(Wasteland.font(11))
                    .foregroundStyle(Wasteland.textDim)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            if let date = session.lastActivity {
                Text(date, format: .relative(presentation: .named))
                    .font(Wasteland.font(10))
                    .foregroundStyle(Wasteland.textDim)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .foregroundStyle(isSelected ? Wasteland.accent : Wasteland.textPrimary)
        .background(isSelected ? Wasteland.surfaceHi : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }
}
