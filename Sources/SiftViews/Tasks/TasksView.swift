import SwiftUI

/// The recurring work surface. Scheduled jobs and loops used to be two separate emulated
/// windows; they are the same idea (run a prompt without a terminal) differing only in when
/// and how many times, so they share one place and a mode switch.
///
/// One-off runs stay in "Quick task": it's the most-used surface and deserves its own room.
struct TasksView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case scheduled = "Scheduled"
        case loop = "Loop"
        var id: Self { self }
    }

    @State private var mode: Mode = .scheduled

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            switch mode {
            case .scheduled: ScheduledTasksView()
            case .loop:      LoopTasksView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Tasks")
    }
}
