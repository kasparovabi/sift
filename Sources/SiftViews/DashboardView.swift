import SwiftUI
import SiftCore
import SiftIndex
import SiftRuntime

/// The control-center home, shown in the workspace when no session is open. Gives
/// an at-a-glance overview: stats, active sessions, pinned, recent, quick actions.
struct DashboardView: View {
    @Environment(IndexCoordinator.self) private var index
    @Environment(SessionRuntime.self) private var runtime
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
                if !pinned.isEmpty { sessionSection("Pinned", pinned, icon: "pin.fill") }
                if !recent.isEmpty { sessionSection("Recent sessions", recent, icon: "clock") }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: index.totalSessionCount) { await load() }
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
            Text("Sift")
                .font(Palette.font(34, weight: .bold))
                .foregroundStyle(Palette.accent)
                .siftGlow(Palette.accent, radius: 8)
            Text("\(index.totalSessionCount) sessions · \(index.projects.count) projects")
                .font(Palette.font(13))
                .foregroundStyle(Palette.textDim)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 12) {
            stat("\(index.totalSessionCount)", "Oturum", "tray.full", Palette.cyan)
            stat("\(index.projects.count)", "Project", "folder", Palette.cyan)
            stat("\(runtime.runningCount)", "Active", "bolt.fill", Palette.accent)
            stat("\(streak)", "day streak", "flame.fill", Palette.acid)
        }
    }

    /// A friendly this-week summary with a week-over-week trend — a quiet momentum nudge,
    /// computed from the (noise-filtered) daily activity.
    private var weekTrend: some View {
        let thisWeek = weekSum(0)
        let lastWeek = weekSum(1)
        let delta = thisWeek - lastWeek
        let (icon, tint, note): (String, Color, String) =
            lastWeek == 0 ? ("sparkles", Palette.accent, "fresh start")
            : delta > 0  ? ("arrow.up.right", Palette.accent, "\(delta) more than last week")
            : delta < 0  ? ("arrow.down.right", Palette.acid, "\(-delta) fewer than last week")
            :              ("equal", Palette.textDim, "same as last week")
        return HStack(spacing: 12) {
            Image(systemName: "calendar").font(.title3).foregroundStyle(Palette.cyan).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(thisWeek) sessions this week")
                    .font(Palette.font(14, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text(note).font(Palette.font(11)).foregroundStyle(Palette.textDim)
            }
            Spacer()
            Image(systemName: icon).font(.title3).foregroundStyle(tint)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .siftPanel(cornerRadius: 12)
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
            Label("Most active projects", systemImage: "chart.bar.fill")
                .font(Palette.font(15, weight: .semibold))
                .foregroundStyle(Palette.accent)
            VStack(spacing: 7) {
                ForEach(Array(top), id: \.id) { project in
                    Button {
                        index.sidebarSelection = .project(project.id)
                    } label: {
                        HStack(spacing: 10) {
                            Text(project.displayName)
                                .font(Palette.font(11)).foregroundStyle(Palette.textPrimary)
                                .lineLimit(1).truncationMode(.middle)
                                .frame(width: 150, alignment: .leading)
                            GeometryReader { geo in
                                let ratio = (Double(project.sessionCount) / maxCount).squareRoot()
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Palette.surfaceHi)
                                    Capsule()
                                        .fill(ProjectPalette.color(for: project.decodedPath))
                                        .frame(width: max(6, geo.size.width * ratio))
                                }
                            }
                            .frame(height: 13)
                            Text("\(project.sessionCount)")
                                .font(Palette.font(10)).foregroundStyle(Palette.textDim)
                                .frame(width: 44, alignment: .trailing)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Reveal \(project.displayName) in Finder")
                }
            }
            .padding(14)
            .siftPanel(cornerRadius: 12)
        }
    }

    private func stat(_ value: String, _ label: String, _ icon: String, _ tint: Color = Palette.textDim) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(value)
                .font(Palette.font(26, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            Text(label).font(Palette.font(11)).foregroundStyle(Palette.textDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .siftPanel(cornerRadius: 12)
    }

    private var quickActions: some View {
        HStack(spacing: 10) {
            Button(action: onNewFolder) {
                Label("New session…", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            Button { Task { await index.rescan() } } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(index.isScanning)
            Spacer()
            Text("Quick open: ⌥Space").font(Palette.font(11)).foregroundStyle(Palette.textDim)
        }
    }

    private func sessionSection(_ title: String, _ items: [SessionSummary], icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(Palette.font(15, weight: .semibold))
                .foregroundStyle(Palette.accent)
            ForEach(items) { session in
                Button { onResume(session) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "terminal").foregroundStyle(Palette.cyan)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.displayTitle)
                                .font(Palette.font(13, weight: .medium))
                                .foregroundStyle(Palette.textPrimary)
                                .lineLimit(1)
                            Text(session.cwd ?? "")
                                .font(Palette.font(11)).foregroundStyle(Palette.textDim)
                                .lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                        if let date = session.lastActivity {
                            Text(date, format: .relative(presentation: .named))
                                .font(Palette.font(10)).foregroundStyle(Palette.textDim)
                        }
                    }
                    .padding(10)
                    .siftPanel(cornerRadius: 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
