import SwiftUI
import AppKit
import SiftCore
import SiftIndex
import SiftRuntime

/// Detail column: the selected session, or a welcome pane when nothing is selected.
struct SessionDetailPane: View {
    @Environment(IndexCoordinator.self) private var index

    var body: some View {
        if let session = index.selectedSession() {
            SelectedSessionView(session: session)
        } else {
            WelcomePane()
        }
    }
}

/// The selected-session detail: a visual header card, friendly stat pills, and a short
/// preview of the most recent conversation so you can confirm "is this the one?" before
/// opening it. Loads only the tail of the transcript, so even a huge session is instant.
private struct SelectedSessionView: View {
    let session: SessionSummary
    @Environment(SessionRuntime.self) private var runtime
    @Environment(IndexCoordinator.self) private var index
    @State private var turns: [TranscriptTurn] = []
    @State private var loaded = false
    @State private var copied = false
    @State private var editing = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    projectChip
                    Text(session.displayTitle)
                        .font(Palette.font(20, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .textSelection(.enabled)
                    // Friendly at-a-glance pills instead of a jargon label list.
                    HStack(spacing: 8) {
                        if let date = session.lastActivity {
                            statPill("clock") { Text(date, format: .relative(presentation: .named)) }
                        }
                        if session.messageCount > 0 {
                            statPill("bubble.left.and.bubble.right") { Text("\(session.messageCount) mesaj") }
                        }
                        if let branch = session.gitBranch, !branch.isEmpty, branch != "HEAD" {
                            statPill("arrow.triangle.branch") { Text(branch) }
                        }
                    }
                    if let cwd = session.cwd, !cwd.isEmpty {
                        Label(cwd, systemImage: "folder")
                            .font(.callout).foregroundStyle(Palette.textDim)
                            .lineLimit(1).truncationMode(.head).textSelection(.enabled)
                    }
                    conversationPreview
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 8) {
                // Discoverable equivalents of the right-click actions, so a basic user who
                // never opens a context menu can still pin, copy the resume command, or
                // jump to the folder.
                iconButton(session.pinned ? "pin.slash" : "pin",
                           session.pinned ? "Unpin" : "Pin") {
                    index.togglePin(session.sessionId)
                }
                iconButton("pencil", "Edit name and tags") { editing = true }
                iconButton(copied ? "checkmark" : "doc.on.doc", "Copy resume command") {
                    copyResumeCommand()
                }
                if session.cwd != nil {
                    iconButton("folder", "Reveal in Finder") { revealCwd() }
                }
                Spacer()
                Button { open() } label: {
                    Label("Open", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
            }
            .padding(12)
        }
        .task(id: session.sessionId) {
            loaded = false
            turns = await TranscriptLoader.load(filePath: session.filePath, maxTurns: 8)
            loaded = true
        }
        .sheet(isPresented: $editing) {
            SessionEditSheet(session: session).environment(index)
        }
    }

    /// Last few turns, rendered as a compact colour-coded transcript. Falls back to the
    /// first message if the file can't be read.
    @ViewBuilder private var conversationPreview: some View {
        Divider()
        Text("Last message").font(.caption).foregroundStyle(Palette.textDim)
        if !loaded {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.caption).foregroundStyle(Palette.textDim)
            }
        } else if turns.isEmpty {
            if let message = session.firstMessage, !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(Palette.textPrimary).textSelection(.enabled)
            } else {
                Text("No messages to show").font(.caption).foregroundStyle(Palette.textDim)
            }
        } else {
            ForEach(turns.suffix(6)) { turn in turnRow(turn) }
        }
    }

    private func turnRow(_ turn: TranscriptTurn) -> some View {
        let (label, color) = roleStyle(turn.role)
        return VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(color)
            Text(turn.text)
                .font(.caption)
                .lineLimit(4)
                .foregroundStyle(turn.role == .tool ? Palette.textDim : Palette.textPrimary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
    }

    private func roleStyle(_ role: TranscriptTurn.Role) -> (String, Color) {
        switch role {
        case .user: return ("Sen", Palette.cyan)
        case .assistant: return ("Claude", Palette.accent)
        case .tool: return ("Tool", Palette.acid)
        }
    }

    /// A small coloured chip naming the session's project, in the same palette hue its
    /// rows use elsewhere, so the detail pane reads as part of the same colour system.
    private var projectChip: some View {
        let folder = URL(fileURLWithPath: session.cwd ?? "").lastPathComponent
        let color = ProjectPalette.color(for: session.cwd ?? session.projectId)
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(folder.isEmpty || folder == "/" ? "Project" : folder)
                .font(.caption).fontWeight(.medium)
                .foregroundStyle(Palette.textPrimary)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(color.opacity(0.16), in: Capsule())
    }

    private func statPill<Content: View>(_ icon: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            content()
        }
        .font(.caption)
        .foregroundStyle(Palette.textDim)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Palette.surfaceHi, in: Capsule())
    }

    private func iconButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 16) }
            .buttonStyle(.bordered)
            .help(help)
    }

    private func copyResumeCommand() {
        let cwd = session.cwd ?? NSHomeDirectory()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("cd '\(cwd)' && claude --resume \(session.sessionId)", forType: .string)
        copied = true
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
    }

    private func revealCwd() {
        guard let cwd = session.cwd else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
    }

    private func open() {
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

/// Shown in the detail pane when nothing is selected: a greeting, at-a-glance stat chips,
/// a 14-day activity sparkline, and a one-click new-session button. Turns dead space into
/// a useful home screen.
private struct WelcomePane: View {
    @Environment(IndexCoordinator.self) private var index
    @Environment(SessionRuntime.self) private var runtime
    @State private var activity: [String: Int] = [:]
    @State private var recents: [SessionSummary] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting)
                    .font(Palette.font(28, weight: .bold))
                    .foregroundStyle(Palette.accent)
                Text("\(index.totalSessionCount) sessions · \(index.projects.count) projects")
                    .foregroundStyle(Palette.textDim)
            }
            VStack(spacing: 8) {
                chip("\(last14.last ?? 0)", "today", "sun.max.fill", Palette.acid)
                chip("\(runtime.runningCount)", "running", "bolt.fill", Palette.accent)
                chip("\(index.projects.count)", "projects", "folder.fill", Palette.cyan)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Last 14 days").font(.caption).foregroundStyle(Palette.textDim)
                Sparkline(values: last14).frame(height: 46)
            }
            if let last = recents.first {
                VStack(alignment: .leading, spacing: 8) {
                    Button { resume(last) } label: {
                        Label("Pick up where you left off", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    Text(last.displayTitle)
                        .font(.caption).foregroundStyle(Palette.textDim).lineLimit(1)

                    // A few more recent sessions as one-tap launchpad rows.
                    if recents.count > 1 {
                        Text("Other recent sessions").font(.caption).foregroundStyle(Palette.textDim)
                            .padding(.top, 2)
                        ForEach(recents.dropFirst().prefix(3)) { session in
                            Button { resume(session) } label: { recentRow(session) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            Button { newSession() } label: {
                Label("Start a new session", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large)
            Text("Tip: press ⌥Space to search from anywhere")
                .font(.caption).foregroundStyle(Palette.textDim)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            let since = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
            activity = await index.activityByDay(since: since)
            recents = await index.recentUserSessions(limit: 4)
        }
    }

    /// Compact one-tap recent-session row (project dot + title + relative time).
    private func recentRow(_ session: SessionSummary) -> some View {
        HStack(spacing: 8) {
            Circle().fill(ProjectPalette.color(for: session.cwd ?? session.projectId))
                .frame(width: 7, height: 7)
            Text(session.displayTitle).font(.callout).foregroundStyle(Palette.textPrimary).lineLimit(1)
            Spacer(minLength: 4)
            if let date = session.lastActivity {
                Text(date, format: .relative(presentation: .named))
                    .font(.caption2).foregroundStyle(Palette.textDim)
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }

    private func resume(_ session: SessionSummary) {
        Task {
            try? await runtime.launch(SessionLaunchRequest(
                mode: .resume(sessionId: session.sessionId),
                cwd: session.cwd ?? NSHomeDirectory(),
                projectId: session.projectId,
                gitBranch: session.gitBranch,
                title: session.displayTitle))
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12:  return "Good morning"
        case 12..<18: return "Good afternoon"
        case 18..<23: return "Good evening"
        default:      return "Good night"
        }
    }

    private var last14: [Int] {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<14).reversed().map { offset in
            let day = cal.date(byAdding: .day, value: -offset, to: today)!
            return activity[fmt.string(from: day)] ?? 0
        }
    }

    private func chip(_ value: String, _ label: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 20)
            Text(value).font(Palette.font(16, weight: .semibold)).foregroundStyle(Palette.textPrimary)
            Text(label).font(.caption).foregroundStyle(Palette.textDim).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func newSession() {
        guard let url = chooseClaudeDirectory() else { return }
        Task {
            try? await runtime.launch(SessionLaunchRequest(
                mode: .fresh, cwd: url.path, projectId: "", title: url.lastPathComponent))
        }
    }
}

/// A compact bottom-aligned bar chart (one bar per value), accent-tinted.
private struct Sparkline: View {
    let values: [Int]
    var body: some View {
        GeometryReader { geo in
            let maxV = max(1, values.max() ?? 1)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(values.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Palette.accent.opacity(values[i] == 0 ? 0.15 : 0.85))
                        .frame(height: max(3, geo.size.height * CGFloat(values[i]) / CGFloat(maxV)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }
}
