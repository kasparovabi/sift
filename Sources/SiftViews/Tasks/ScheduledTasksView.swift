import SwiftUI
import AppKit
import SiftCore
import SiftRuntime

/// "Scheduled tasks": recurring tasks that run a prompt on a schedule (while the app
/// is open), through the same headless runner as Hızlı görev. Create, enable/disable, run
/// now, and see each job's last result.
struct ScheduledTasksView: View {
    @Environment(SessionRuntime.self) private var runtime

    @State private var title = ""
    @State private var prompt = ""
    @State private var cwd = NSHomeDirectory()
    @State private var everyMinutes = 60
    @State private var pendingDelete: ScheduledJob?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    addForm
                    if !runtime.scheduledJobs.isEmpty {
                        Divider().overlay(Palette.border)
                        ForEach(runtime.scheduledJobs) { job in jobRow(job) }
                    } else {
                        Text("No scheduled tasks yet. Add one above.")
                            .font(Palette.font(13)).foregroundStyle(Palette.textDim).padding(.top, 4)
                    }
                }
                .padding(14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // A real binding, not `.constant`: SwiftUI dismisses by writing false, so a constant
        // one leaves Escape and click-outside doing nothing.
        .confirmationDialog("Delete task?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { job in
            Button("Delete", role: .destructive) { runtime.removeScheduledJob(job.id) }
            Button("Cancel", role: .cancel) {}
        } message: { job in
            Text("\"\(job.title)\" will be deleted. This cannot be undone.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock").foregroundStyle(Palette.acid)
            Text("Scheduled tasks").font(Palette.font(15, weight: .semibold)).foregroundStyle(Palette.textPrimary)
            Spacer()
            Text("runs while the app is open").font(Palette.font(10)).foregroundStyle(Palette.textDim)
        }
        .padding(.horizontal, 14).frame(height: 38).background(Palette.surface)
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New task").font(Palette.font(13, weight: .semibold)).foregroundStyle(Palette.textPrimary)
            TextField("Title (e.g. Daily digest)", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $prompt)
                .font(Palette.font(13)).foregroundStyle(Palette.textPrimary).scrollContentBackground(.hidden)
                .frame(height: 60).padding(6)
                .background(Palette.surfaceHi, in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("What should it do? (e.g. run the tests and summarise)")
                            .font(Palette.font(13)).foregroundStyle(Palette.textDim)
                            .padding(.horizontal, 11).padding(.vertical, 12).allowsHitTesting(false)
                    }
                }
            HStack(spacing: 8) {
                Image(systemName: "folder").font(.caption).foregroundStyle(Palette.textDim)
                Text(URL(fileURLWithPath: cwd).lastPathComponent).font(Palette.font(11)).foregroundStyle(Palette.textDim)
                Button("Choose folder…") { if let url = chooseClaudeDirectory() { cwd = url.path } }
                    .buttonStyle(.link).font(.caption).tint(Palette.cyan)
                Spacer()
                Picker("", selection: $everyMinutes) {
                    Text("Every 15 minutes").tag(15)
                    Text("Hourly").tag(60)
                    Text("Daily").tag(1440)
                }
                .labelsHidden().fixedSize()
                Button { add() } label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).tint(Palette.accent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty
                              || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func jobRow(_ job: ScheduledJob) -> some View {
        let isRunning = runtime.runningJobIds.contains(job.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: job.enabled ? "checkmark.circle.fill" : "pause.circle")
                    .foregroundStyle(job.enabled ? Palette.accent : Palette.textDim)
                Text(job.title).font(Palette.font(13, weight: .medium)).foregroundStyle(Palette.textPrimary).lineLimit(1)
                Text("· \(job.cadenceLabel)").font(Palette.font(11)).foregroundStyle(Palette.textDim)
                Spacer()
                if isRunning {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini).tint(Palette.accent)
                        Text("running").font(Palette.font(10)).foregroundStyle(Palette.accent)
                    }
                } else if let last = job.lastRun {
                    Text(last, format: .relative(presentation: .named)).font(Palette.font(10)).foregroundStyle(Palette.textDim)
                }
            }
            Text(job.prompt).font(Palette.font(11)).foregroundStyle(Palette.textDim).lineLimit(2)
            if let result = job.lastResult, !result.isEmpty {
                Text(result).font(Palette.font(11)).foregroundStyle(Palette.textPrimary).lineLimit(3)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.surfaceHi, in: RoundedRectangle(cornerRadius: 7))
            }
            HStack(spacing: 8) {
                Button { runtime.runScheduledJobNow(job.id) } label: { Label("Run now", systemImage: "play.fill") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(isRunning)
                Button { runtime.toggleScheduledJob(job.id) } label: {
                    Label(job.enabled ? "Pause" : "Resume", systemImage: job.enabled ? "pause" : "play")
                }
                .buttonStyle(.bordered).controlSize(.small)
                Spacer()
                Button(role: .destructive) { pendingDelete = job } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered).controlSize(.small).tint(Palette.danger)
            }
        }
        .padding(10)
        .siftPanel(cornerRadius: 10)
    }

    private func add() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !p.isEmpty else { return }
        runtime.addScheduledJob(title: t, prompt: p, cwd: cwd, everyMinutes: everyMinutes)
        title = ""; prompt = ""
    }
}
