import SwiftUI
import ClaudeOSCore
import ClaudeOSIndex
import ClaudeOSRuntime

/// The control-center home, shown in the workspace when no session is open. Gives
/// an at-a-glance overview: stats, active sessions, pinned, recent, quick actions.
struct DashboardView: View {
    @Environment(IndexCoordinator.self) private var index
    @Environment(SessionRuntime.self) private var runtime
    @Environment(DesktopWindowManager.self) private var windows
    let onResume: (SessionSummary) -> Void
    let onNewFolder: () -> Void

    @State private var recent: [SessionSummary] = []
    @State private var pinned: [SessionSummary] = []
    @State private var activity: [String: Int] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                statsRow
                weekTrend
                ActivityHeatmap(counts: activity)
                quickActions
                if index.projects.count > 1 { projectBreakdown }
                if !runtime.sessions.isEmpty { activeSection }
                if !pinned.isEmpty { sessionSection("Sabitlenenler", pinned, icon: "pin.fill") }
                if !recent.isEmpty { sessionSection("Son oturumlar", recent, icon: "clock") }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: index.totalSessionCount) { await load() }
        .onChange(of: runtime.sessions.count) { _, _ in Task { await load() } }
        .onChange(of: index.metaStore.metas) { _, _ in Task { await load() } }
    }

    private func load() async {
        recent = await index.recentUserSessions(limit: 6)
        pinned = await index.pinnedSessions()
        let since = Calendar.current.date(byAdding: .day, value: -118, to: Date()) ?? Date()
        activity = await index.activityByDay(since: since)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Claude OS")
                .font(Wasteland.font(34, weight: .bold))
                .foregroundStyle(Wasteland.accent)
                .neonGlow(Wasteland.accent, radius: 8)
            Text("\(index.totalSessionCount) oturum · \(index.projects.count) proje")
                .font(Wasteland.font(13))
                .foregroundStyle(Wasteland.textDim)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 12) {
            stat("\(index.totalSessionCount)", "Oturum", "tray.full", Wasteland.cyan)
            stat("\(index.projects.count)", "Proje", "folder", Wasteland.cyan)
            stat("\(runtime.runningCount)", "Çalışan", "bolt.fill", Wasteland.accent)
            stat("\(streak)", "gün seri", "flame.fill", Wasteland.acid)
        }
    }

    /// A friendly this-week summary with a week-over-week trend — a quiet momentum nudge,
    /// computed from the (noise-filtered) daily activity.
    private var weekTrend: some View {
        let thisWeek = weekSum(0)
        let lastWeek = weekSum(1)
        let delta = thisWeek - lastWeek
        let (icon, tint, note): (String, Color, String) =
            lastWeek == 0 ? ("sparkles", Wasteland.accent, "yeni başlangıç")
            : delta > 0  ? ("arrow.up.right", Wasteland.accent, "geçen haftadan \(delta) fazla")
            : delta < 0  ? ("arrow.down.right", Wasteland.acid, "geçen haftadan \(-delta) az")
            :              ("equal", Wasteland.textDim, "geçen haftayla aynı")
        return HStack(spacing: 12) {
            Image(systemName: "calendar").font(.title3).foregroundStyle(Wasteland.cyan).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("Bu hafta \(thisWeek) oturum")
                    .font(Wasteland.font(14, weight: .semibold))
                    .foregroundStyle(Wasteland.textPrimary)
                Text(note).font(Wasteland.font(11)).foregroundStyle(Wasteland.textDim)
            }
            Spacer()
            Image(systemName: icon).font(.title3).foregroundStyle(tint)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wastelandPanel(cornerRadius: 12)
    }

    /// Total sessions in the week ending `weeksAgo*7` days back (0 = this week, 1 = last week).
    private func weekSum(_ weeksAgo: Int) -> Int {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<7).reduce(0) { acc, offset in
            let day = cal.date(byAdding: .day, value: -(weeksAgo * 7 + offset), to: today) ?? today
            return acc + (activity[fmt.string(from: day)] ?? 0)
        }
    }

    /// Consecutive days (ending today, or yesterday if today is still quiet) with at least
    /// one session — a little momentum nudge.
    private var streak: Int {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let cal = Calendar.current
        var day = cal.startOfDay(for: Date())
        if (activity[fmt.string(from: day)] ?? 0) == 0 {
            day = cal.date(byAdding: .day, value: -1, to: day) ?? day   // today not started yet
        }
        var count = 0
        while (activity[fmt.string(from: day)] ?? 0) > 0 {
            count += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return count
    }

    /// Horizontal bars of the busiest projects, each in its own palette colour. Bar widths
    /// use a square-root scale so one huge project doesn't flatten all the others to zero.
    private var projectBreakdown: some View {
        let top = index.projects.sorted { $0.sessionCount > $1.sessionCount }.prefix(8)
        let maxCount = Double(max(1, top.first?.sessionCount ?? 1))
        return VStack(alignment: .leading, spacing: 10) {
            Label("En aktif projeler", systemImage: "chart.bar.fill")
                .font(Wasteland.font(15, weight: .semibold))
                .foregroundStyle(Wasteland.accent)
            VStack(spacing: 7) {
                ForEach(Array(top), id: \.id) { project in
                    Button {
                        index.sidebarSelection = .project(project.id)
                        windows.openFinder()
                    } label: {
                        HStack(spacing: 10) {
                            Text(project.displayName)
                                .font(Wasteland.font(11)).foregroundStyle(Wasteland.textPrimary)
                                .lineLimit(1).truncationMode(.middle)
                                .frame(width: 150, alignment: .leading)
                            GeometryReader { geo in
                                let ratio = (Double(project.sessionCount) / maxCount).squareRoot()
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Wasteland.surfaceHi)
                                    Capsule()
                                        .fill(ProjectPalette.color(for: project.decodedPath))
                                        .frame(width: max(6, geo.size.width * ratio))
                                }
                            }
                            .frame(height: 13)
                            Text("\(project.sessionCount)")
                                .font(Wasteland.font(10)).foregroundStyle(Wasteland.textDim)
                                .frame(width: 44, alignment: .trailing)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(project.displayName) oturumlarını Finder'da aç")
                }
            }
            .padding(14)
            .wastelandPanel(cornerRadius: 12)
        }
    }

    private func stat(_ value: String, _ label: String, _ icon: String, _ tint: Color = Wasteland.textDim) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(value)
                .font(Wasteland.font(26, weight: .semibold))
                .foregroundStyle(Wasteland.textPrimary)
            Text(label).font(Wasteland.font(11)).foregroundStyle(Wasteland.textDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .wastelandPanel(cornerRadius: 12)
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
            Text("Hızlı aç: ⌥Space").font(Wasteland.font(11)).foregroundStyle(Wasteland.textDim)
        }
    }

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Aktif oturumlar", systemImage: "bolt.fill")
                .font(Wasteland.font(15, weight: .semibold))
                .foregroundStyle(Wasteland.accent)
            ForEach(runtime.sessions) { session in
                Button { runtime.focus(session) } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(session.needsAttention ? Wasteland.acid : (session.isRunning ? Wasteland.accent : Wasteland.textDim))
                            .frame(width: 8, height: 8)
                        Text(session.title)
                            .font(Wasteland.font(13, weight: .medium))
                            .foregroundStyle(Wasteland.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "arrow.right.circle").foregroundStyle(Wasteland.textDim)
                    }
                    .padding(10)
                    .wastelandPanel(cornerRadius: 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func sessionSection(_ title: String, _ items: [SessionSummary], icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(Wasteland.font(15, weight: .semibold))
                .foregroundStyle(Wasteland.accent)
            ForEach(items) { session in
                Button { onResume(session) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "terminal").foregroundStyle(Wasteland.cyan)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.displayTitle)
                                .font(Wasteland.font(13, weight: .medium))
                                .foregroundStyle(Wasteland.textPrimary)
                                .lineLimit(1)
                            Text(session.cwd ?? "")
                                .font(Wasteland.font(11)).foregroundStyle(Wasteland.textDim)
                                .lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                        if let date = session.lastActivity {
                            Text(date, format: .relative(presentation: .named))
                                .font(Wasteland.font(10)).foregroundStyle(Wasteland.textDim)
                        }
                    }
                    .padding(10)
                    .wastelandPanel(cornerRadius: 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
