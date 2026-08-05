import SwiftUI

/// The recurring work surface. Scheduled jobs and loops are the same idea (run a prompt
/// without a terminal) differing only in when and how many times, so they share one screen
/// and a mode switch. Each has its own sidebar entry: a loop buried as the second segment
/// of something called "Tasks" is a loop nobody finds.
///
/// One-off runs stay in "Quick task": it's the most-used surface and deserves its own room.
struct TasksView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case scheduled = "Scheduled"
        case loop = "Loop"
        var id: Self { self }
    }

    @State private var mode: Mode

    init(mode: Mode = .scheduled) {
        _mode = State(initialValue: mode)
    }

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
        .navigationTitle(mode == .loop ? "Loops" : "Scheduled tasks")
    }
}
