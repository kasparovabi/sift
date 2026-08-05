import SwiftUI

/// GitHub-style contribution grid: one small square per day for the last ~17 weeks,
/// tinted by how many sessions were active that day. An at-a-glance pulse of how busy
/// each day has been — quiet days stay faint, busy days glow in the accent colour.
struct ActivityHeatmap: View {
    let counts: [String: Int]      // "yyyy-MM-dd" (local) → session count
    var weeks: Int = 17

    private struct Day { let date: Date?; let count: Int }

    private static let key: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let label: DateFormatter = {
        let f = DateFormatter()
        f.locale = SiftLocale.ui
        f.dateFormat = "d MMM"
        return f
    }()
    private static let monthFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = SiftLocale.ui
        f.dateFormat = "MMM"
        return f
    }()

    private var maxCount: Int { max(1, counts.values.max() ?? 1) }

    /// Columns = weeks (Monday on top), the last column ending today.
    private var grid: [[Day]] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekday = (cal.component(.weekday, from: today) + 5) % 7   // Mon=0 … Sun=6
        let back = (weeks - 1) * 7 + weekday
        guard let start = cal.date(byAdding: .day, value: -back, to: today) else { return [] }
        return (0..<weeks).map { col in
            (0..<7).map { row -> Day in
                let date = cal.date(byAdding: .day, value: col * 7 + row, to: start)!
                if date > today { return Day(date: nil, count: 0) }
                return Day(date: date, count: counts[Self.key.string(from: date)] ?? 0)
            }
        }
    }

    private func color(for day: Day) -> Color {
        guard day.date != nil else { return .clear }
        if day.count == 0 { return Palette.border.opacity(0.35) }
        let ratio = Double(day.count) / Double(maxCount)
        let level = ratio > 0.66 ? 1.0 : (ratio > 0.33 ? 0.72 : 0.42)
        return Palette.accent.opacity(level)
    }

    private var total: Int { counts.values.reduce(0, +) }

    var body: some View {
        let g = grid
        let months = monthStarts(g)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Activity", systemImage: "flame.fill")
                    .font(Palette.font(15, weight: .bold))
                    .foregroundStyle(Palette.accent)
                Spacer()
                Text("last \(weeks) weeks · \(total) sessions")
                    .font(Palette.font(11)).foregroundStyle(Palette.textDim)
            }
            VStack(alignment: .leading, spacing: 4) {
                // Month labels above the columns, so you can tell *when* a busy patch was.
                HStack(spacing: 3) {
                    ForEach(0..<g.count, id: \.self) { col in
                        Color.clear.frame(width: 12, height: 10)
                            .overlay(alignment: .leading) {
                                if let name = months[col] {
                                    Text(name).font(Palette.font(9)).foregroundStyle(Palette.textDim).fixedSize()
                                }
                            }
                    }
                }
                HStack(alignment: .top, spacing: 3) {
                    ForEach(Array(g.enumerated()), id: \.offset) { _, col in
                        VStack(spacing: 3) {
                            ForEach(Array(col.enumerated()), id: \.offset) { _, day in
                                RoundedRectangle(cornerRadius: 2.5)
                                    .fill(color(for: day))
                                    .frame(width: 12, height: 12)
                                    .help(help(day))
                            }
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text("Low").font(Palette.font(9)).foregroundStyle(Palette.textDim)
                ForEach([0.07, 0.42, 0.72, 1.0], id: \.self) { lvl in
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(lvl == 0.07 ? Palette.border.opacity(0.35) : Palette.accent.opacity(lvl))
                        .frame(width: 12, height: 12)
                }
                Text("High").font(Palette.font(9)).foregroundStyle(Palette.textDim)
            }
        }
        .padding(14)
        .siftPanel(cornerRadius: 12)
    }

    /// Column index → month abbreviation, but only for the first column of each month
    /// (GitHub-style). Computed from a captured grid so it isn't rebuilt per column.
    private func monthStarts(_ g: [[Day]]) -> [Int: String] {
        let cal = Calendar.current
        var out: [Int: String] = [:]
        var lastMonth = -1
        for (col, week) in g.enumerated() {
            guard let date = week.first(where: { $0.date != nil })?.date else { continue }
            let month = cal.component(.month, from: date)
            if month != lastMonth {
                out[col] = Self.monthFmt.string(from: date)
                lastMonth = month
            }
        }
        return out
    }

    private func help(_ day: Day) -> String {
        guard let date = day.date else { return "" }
        return "\(Self.label.string(from: date)): \(day.count) sessions"
    }
}
