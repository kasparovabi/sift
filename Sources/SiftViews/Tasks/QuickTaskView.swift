import SwiftUI
import AppKit
import SiftCore
import SiftIndex
import SiftRuntime

/// "Quick task": run a one-off `claude` task in a chosen folder without opening a full
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
    /// Live events from the running task, so the wait shows what claude is actually doing.
    @State private var liveLines: [String] = []
    @State private var runTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            composer
            if !saved.isEmpty { savedRow }
            Divider().overlay(Palette.border)
            resultPane
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.base)
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
                    .tint(Palette.accent)
                    .help(item.text)
                    .contextMenu { Button("Delete", systemImage: "trash") { delete(item) } }
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 8)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill").foregroundStyle(Palette.acid).siftGlow(Palette.acid, radius: 5)
                Text("Quick task").font(Palette.font(15, weight: .semibold)).foregroundStyle(Palette.textPrimary)
            }
            Text("Describe a short task without opening a terminal; it runs in the background and the answer lands below.")
                .font(Palette.font(11)).foregroundStyle(Palette.textDim)

            // One-tap reflection: summarise today's sessions via the headless runner.
            Button { dailyDigest() } label: {
                Label("What did I do today?", systemImage: "calendar")
            }
            .buttonStyle(.bordered).controlSize(.small)
            .tint(Palette.cyan)
            .disabled(running)

            TextEditor(text: $prompt)
                .font(Palette.font(13))
                .foregroundStyle(Palette.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(height: 84)
                .padding(6)
                .background(Palette.surfaceHi, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.border, lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("e.g. summarise the TODOs in this folder")
                            .font(Palette.font(13)).foregroundStyle(Palette.textDim)
                            .padding(.horizontal, 11).padding(.vertical, 12).allowsHitTesting(false)
                    }
                }

            HStack(spacing: 8) {
                Image(systemName: "folder").font(.caption).foregroundStyle(Palette.textDim)
                Text(folderLabel).font(Palette.font(11)).foregroundStyle(Palette.textDim).lineLimit(1).truncationMode(.head)
                Button("Choose folder…") { if let url = chooseClaudeDirectory() { cwd = url.path } }
                    .buttonStyle(.link).font(.caption).tint(Palette.cyan)
                Spacer()
                if !history.isEmpty {
                    Menu {
                        ForEach(history) { item in
                            Button(String(item.prompt.prefix(50))) {
                                prompt = item.prompt; result = item.result; ranPrompt = item.prompt
                            }
                        }
                        Divider()
                        Button("Clear history", systemImage: "trash") { history = []; QuickRunStore.save([]) }
                    } label: {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(Palette.cyan)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Past questions")
                }
                Button { savePrompt() } label: { Image(systemName: "bookmark") }
                    .buttonStyle(.bordered)
                    .tint(Palette.accent)
                    .help("Save this prompt")
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if running {
                    Button { stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(.borderedProminent).tint(Palette.danger)
                } else {
                    Button { run() } label: { Label("Run", systemImage: "bolt.fill") }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accent)
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(14)
    }

    @ViewBuilder private var resultPane: some View {
        ScrollViewReader { proxy in
        ScrollView {
            if running {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(Palette.accent)
                        Text("Claude is working…").foregroundStyle(Palette.textDim)
                    }
                    ForEach(Array(liveLines.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(Palette.font(11)).foregroundStyle(Palette.textDim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .id(i)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            } else if result.isEmpty {
                Text("The result will appear here.")
                    .font(Palette.font(12)).foregroundStyle(Palette.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if !ranPrompt.isEmpty {
                        Text(ranPrompt).font(Palette.font(11)).foregroundStyle(Palette.textDim)
                            .lineLimit(2)
                        Divider().overlay(Palette.border)
                    }
                    Text(result).font(Palette.font(12)).foregroundStyle(Palette.textPrimary).textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result, forType: .string)
                    } label: { Label("Copy answer", systemImage: "doc.on.doc") }
                        .buttonStyle(.borderless).font(.caption).tint(Palette.cyan).padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
        }
        .onChange(of: liveLines.count) { _, count in
            guard count > 0 else { return }
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(count - 1, anchor: .bottom) }
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
        liveLines = []
        ranPrompt = p
        // Streaming, not the one-shot runner: the same engine the loop uses, so the wait shows
        // assistant text and tool calls as they land instead of an opaque spinner.
        runTask = Task {
            let out = await runtime.runQuickTaskStreaming(prompt: p, cwd: dir) { line in
                liveLines.append(line)
                if liveLines.count > 40 { liveLines.removeFirst(liveLines.count - 40) }
            }.text
            let stopped = Task.isCancelled
            running = false
            runTask = nil
            result = stopped ? "Stopped." : out
            // Keep a short, revisitable history of successful runs.
            let failed = stopped || out.hasPrefix("Could not run") || out.hasPrefix("Hata:")
                || out.hasPrefix("(Empty")
            if !failed {
                history.insert(QuickRun(prompt: p, result: out, date: Date()), at: 0)
                history = Array(history.prefix(15))
                QuickRunStore.save(history)
            }
        }
    }

    /// Cancels the task, which terminates the `claude` process rather than just detaching from
    /// it. The run's own completion reports the outcome, so both paths agree on what happened.
    private func stop() {
        runTask?.cancel()
    }

    /// Build a "what did I do today" prompt from today's session titles and run it.
    private func dailyDigest() {
        guard !running else { return }
        Task {
            let sessions = await index.todaysSessions()
            let titles = sessions.map { "- " + $0.displayTitle }.joined(separator: "\n")
            prompt = titles.isEmpty
                ? "I have not opened a Claude session today. Reply with the single sentence \'No recorded work today.\' and nothing else."
                : "Below are the titles of the Claude sessions I worked on today. Summarise what I did in 3-5 short bullets. Stay strictly within the titles; invent nothing:\n\(titles)"
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
    private static let key = "sift.savedPrompts"
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
    private static let key = "sift.quickRuns"
    static func load() -> [QuickRun] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([QuickRun].self, from: data) else { return [] }
        return list
    }
    static func save(_ list: [QuickRun]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }
}
