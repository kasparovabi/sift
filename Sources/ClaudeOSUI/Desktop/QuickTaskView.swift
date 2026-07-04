import SwiftUI
import AppKit
import ClaudeOSCore
import ClaudeOSIndex
import ClaudeOSRuntime

/// "Hızlı görev": run a one-off `claude` task in a chosen folder without opening a full
/// terminal session. Type a short request, run it headless, read the answer as a card.
/// No saved session, no terminal window — the lightweight "just ask/do this" surface.
struct QuickTaskView: View {
    @Environment(SessionRuntime.self) private var runtime
    @Environment(IndexCoordinator.self) private var index

    @State private var prompt = ""
    @State private var result = ""
    @State private var running = false
    @State private var cwd = NSHomeDirectory()
    @State private var ranPrompt = ""
    @State private var saved: [SavedPrompt] = SavedPromptStore.load()
    @State private var history: [QuickRun] = QuickRunStore.load()

    var body: some View {
        VStack(spacing: 0) {
            composer
            if !saved.isEmpty { savedRow }
            Divider().overlay(Wasteland.border)
            resultPane
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Wasteland.base)
    }

    /// Saved prompts as one-tap chips: tap to load into the editor, right-click to delete.
    private var savedRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(saved) { item in
                    Button { prompt = item.text } label: {
                        Label(item.title, systemImage: "bookmark.fill").lineLimit(1)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .tint(Wasteland.accent)
                    .help(item.text)
                    .contextMenu { Button("Sil", systemImage: "trash") { delete(item) } }
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 8)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill").foregroundStyle(Wasteland.acid).neonGlow(Wasteland.acid, radius: 5)
                Text("Hızlı görev").font(Wasteland.font(15, weight: .semibold)).foregroundStyle(Wasteland.textPrimary)
            }
            Text("Terminal açmadan kısa bir iş yaz; arka planda çalışıp cevabı aşağıya getirir.")
                .font(Wasteland.font(11)).foregroundStyle(Wasteland.textDim)

            // One-tap reflection: summarise today's sessions via the headless runner.
            Button { dailyDigest() } label: {
                Label("Bugün ne yaptım?", systemImage: "calendar")
            }
            .buttonStyle(.bordered).controlSize(.small)
            .tint(Wasteland.cyan)
            .disabled(running)

            TextEditor(text: $prompt)
                .font(Wasteland.font(13))
                .foregroundStyle(Wasteland.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(height: 84)
                .padding(6)
                .background(Wasteland.surfaceHi, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Wasteland.border, lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("Örn: bu klasördeki TODO'ları özetle")
                            .font(Wasteland.font(13)).foregroundStyle(Wasteland.textDim)
                            .padding(.horizontal, 11).padding(.vertical, 12).allowsHitTesting(false)
                    }
                }

            HStack(spacing: 8) {
                Image(systemName: "folder").font(.caption).foregroundStyle(Wasteland.textDim)
                Text(folderLabel).font(Wasteland.font(11)).foregroundStyle(Wasteland.textDim).lineLimit(1).truncationMode(.head)
                Button("Klasör seç…") { if let url = chooseClaudeDirectory() { cwd = url.path } }
                    .buttonStyle(.link).font(.caption).tint(Wasteland.cyan)
                Spacer()
                if !history.isEmpty {
                    Menu {
                        ForEach(history) { item in
                            Button(String(item.prompt.prefix(50))) {
                                prompt = item.prompt; result = item.result; ranPrompt = item.prompt
                            }
                        }
                        Divider()
                        Button("Geçmişi temizle", systemImage: "trash") { history = []; QuickRunStore.save([]) }
                    } label: {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(Wasteland.cyan)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Geçmiş sorular")
                }
                Button { savePrompt() } label: { Image(systemName: "bookmark") }
                    .buttonStyle(.bordered)
                    .tint(Wasteland.accent)
                    .help("Bu komutu kaydet")
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button { run() } label: {
                    Label(running ? "Çalışıyor…" : "Çalıştır", systemImage: "bolt.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Wasteland.accent)
                .disabled(running || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
    }

    @ViewBuilder private var resultPane: some View {
        ScrollView {
            if running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Wasteland.accent)
                    Text("Claude çalışıyor, bu biraz sürebilir…").foregroundStyle(Wasteland.textDim)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            } else if result.isEmpty {
                Text("Sonuç burada görünecek.")
                    .font(Wasteland.font(12)).foregroundStyle(Wasteland.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if !ranPrompt.isEmpty {
                        Text(ranPrompt).font(Wasteland.font(11)).foregroundStyle(Wasteland.textDim)
                            .lineLimit(2)
                        Divider().overlay(Wasteland.border)
                    }
                    Text(result).font(Wasteland.font(12)).foregroundStyle(Wasteland.textPrimary).textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result, forType: .string)
                    } label: { Label("Cevabı kopyala", systemImage: "doc.on.doc") }
                        .buttonStyle(.borderless).font(.caption).tint(Wasteland.cyan).padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
        }
    }

    private var folderLabel: String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    private func run() {
        let p = prompt
        let dir = cwd
        running = true
        result = ""
        ranPrompt = p
        Task {
            let out = await runtime.runQuickTask(prompt: p, cwd: dir)
            result = out
            running = false
            // Keep a short, revisitable history of successful runs.
            let failed = out.hasPrefix("Çalıştırılamadı") || out.hasPrefix("Hata:") || out.hasPrefix("(Boş")
            if !failed {
                history.insert(QuickRun(prompt: p, result: out, date: Date()), at: 0)
                history = Array(history.prefix(15))
                QuickRunStore.save(history)
            }
        }
    }

    /// Build a "what did I do today" prompt from today's session titles and run it.
    private func dailyDigest() {
        guard !running else { return }
        Task {
            let sessions = await index.todaysSessions()
            let titles = sessions.map { "- " + $0.displayTitle }.joined(separator: "\n")
            prompt = titles.isEmpty
                ? "Bugün henüz bir Claude oturumu açmadım. Tek cümleyle 'Bugün kayıtlı bir iş görünmüyor.' de, başka bir şey ekleme."
                : "Aşağıda bugün üzerinde çalıştığım Claude oturumlarının başlıkları var. Bugün genel olarak ne yaptığımı 3-5 kısa maddede, sade Türkçe özetle. Başlıkların dışına çıkıp uydurma ekleme:\n\(titles)"
            run()
        }
    }

    private func savePrompt() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !saved.contains(where: { $0.text == text }) else { return }
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        let title = firstLine.count > 38 ? String(firstLine.prefix(38)) + "…" : firstLine
        saved.insert(SavedPrompt(title: title, text: text), at: 0)
        SavedPromptStore.save(saved)
    }

    private func delete(_ item: SavedPrompt) {
        saved.removeAll { $0.id == item.id }
        SavedPromptStore.save(saved)
    }
}

/// A reusable prompt the user saved from the Hızlı görev composer.
struct SavedPrompt: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var text: String
}

/// UserDefaults-backed persistence for saved prompts (small JSON list).
enum SavedPromptStore {
    private static let key = "claudeos.savedPrompts"
    static func load() -> [SavedPrompt] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([SavedPrompt].self, from: data) else { return [] }
        return list
    }
    static func save(_ list: [SavedPrompt]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// A past quick-task run, kept so answers (and the daily digest) can be revisited.
struct QuickRun: Identifiable, Codable, Equatable {
    var id = UUID()
    var prompt: String
    var result: String
    var date: Date
}

enum QuickRunStore {
    private static let key = "claudeos.quickRuns"
    static func load() -> [QuickRun] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([QuickRun].self, from: data) else { return [] }
        return list
    }
    static func save(_ list: [QuickRun]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }
}
