import SwiftUI
import AppKit
import ClaudeOSCore
import ClaudeOSRuntime

/// "Zamanlanmış görevler": recurring tasks that run a prompt on a schedule (while the app
/// is open), through the same headless runner as Hızlı görev. Create, enable/disable, run
/// now, and see each job's last result.
struct ScheduledTasksView: View {
    @Environment(SessionRuntime.self) private var runtime

    @State private var title = ""
    @State private var prompt = ""
    @State private var cwd = NSHomeDirectory()
    @State private var everyMinutes = 60

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Wasteland.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    addForm
                    if !runtime.scheduledJobs.isEmpty {
                        Divider().overlay(Wasteland.border)
                        ForEach(runtime.scheduledJobs) { job in jobRow(job) }
                    } else {
                        Text("Henüz zamanlanmış görev yok. Yukarıdan bir tane ekle.")
                            .font(Wasteland.font(13)).foregroundStyle(Wasteland.textDim).padding(.top, 4)
                    }
                }
                .padding(14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock").foregroundStyle(Wasteland.acid)
            Text("Zamanlanmış görevler").font(Wasteland.font(15, weight: .semibold)).foregroundStyle(Wasteland.textPrimary)
            Spacer()
            Text("uygulama açıkken çalışır").font(Wasteland.font(10)).foregroundStyle(Wasteland.textDim)
        }
        .padding(.horizontal, 14).frame(height: 38).background(Wasteland.surface)
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Yeni görev").font(Wasteland.font(13, weight: .semibold)).foregroundStyle(Wasteland.textPrimary)
            TextField("Başlık (ör. Günlük özet)", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $prompt)
                .font(Wasteland.font(13)).foregroundStyle(Wasteland.textPrimary).scrollContentBackground(.hidden)
                .frame(height: 60).padding(6)
                .background(Wasteland.surfaceHi, in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("Ne yapılsın? (ör. testleri çalıştır ve özetle)")
                            .font(Wasteland.font(13)).foregroundStyle(Wasteland.textDim)
                            .padding(.horizontal, 11).padding(.vertical, 12).allowsHitTesting(false)
                    }
                }
            HStack(spacing: 8) {
                Image(systemName: "folder").font(.caption).foregroundStyle(Wasteland.textDim)
                Text(URL(fileURLWithPath: cwd).lastPathComponent).font(Wasteland.font(11)).foregroundStyle(Wasteland.textDim)
                Button("Klasör seç…") { if let url = chooseClaudeDirectory() { cwd = url.path } }
                    .buttonStyle(.link).font(.caption).tint(Wasteland.cyan)
                Spacer()
                Picker("", selection: $everyMinutes) {
                    Text("Her 15 dakika").tag(15)
                    Text("Saatte bir").tag(60)
                    Text("Günde bir").tag(1440)
                }
                .labelsHidden().fixedSize()
                Button { add() } label: { Label("Ekle", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).tint(Wasteland.accent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty
                              || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func jobRow(_ job: ScheduledJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: job.enabled ? "checkmark.circle.fill" : "pause.circle")
                    .foregroundStyle(job.enabled ? Wasteland.accent : Wasteland.textDim)
                Text(job.title).font(Wasteland.font(13, weight: .medium)).foregroundStyle(Wasteland.textPrimary).lineLimit(1)
                Text("· \(job.cadenceLabel)").font(Wasteland.font(11)).foregroundStyle(Wasteland.textDim)
                Spacer()
                if let last = job.lastRun {
                    Text(last, format: .relative(presentation: .named)).font(Wasteland.font(10)).foregroundStyle(Wasteland.textDim)
                }
            }
            Text(job.prompt).font(Wasteland.font(11)).foregroundStyle(Wasteland.textDim).lineLimit(2)
            if let result = job.lastResult, !result.isEmpty {
                Text(result).font(Wasteland.font(11)).foregroundStyle(Wasteland.textPrimary).lineLimit(3)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Wasteland.surfaceHi, in: RoundedRectangle(cornerRadius: 7))
            }
            HStack(spacing: 8) {
                Button { runtime.runScheduledJobNow(job.id) } label: { Label("Şimdi çalıştır", systemImage: "play.fill") }
                    .buttonStyle(.bordered).controlSize(.small)
                Button { runtime.toggleScheduledJob(job.id) } label: {
                    Label(job.enabled ? "Duraklat" : "Sürdür", systemImage: job.enabled ? "pause" : "play")
                }
                .buttonStyle(.bordered).controlSize(.small)
                Spacer()
                Button(role: .destructive) { runtime.removeScheduledJob(job.id) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered).controlSize(.small).tint(Wasteland.danger)
            }
        }
        .padding(10)
        .wastelandPanel(cornerRadius: 10)
    }

    private func add() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !p.isEmpty else { return }
        runtime.addScheduledJob(title: t, prompt: p, cwd: cwd, everyMinutes: everyMinutes)
        title = ""; prompt = ""
    }
}
