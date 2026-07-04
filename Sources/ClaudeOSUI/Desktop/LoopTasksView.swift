import SwiftUI
import AppKit
import ClaudeOSRuntime

/// "Döngü": the maker→checker→proof surface. Define a task (what to make + a definition of
/// done + how many passes), run it, and the loop produces, a SEPARATE checker grades, and it
/// repeats until the checker passes or the pass budget runs out. Every cycle leaves a proof
/// row, and a pass can write a one-line outcome to the brain so the next run starts smarter.
struct LoopTasksView: View {
    @Environment(SessionRuntime.self) private var runtime

    var body: some View {
        VStack(spacing: 0) {
            LoopComposer()
            Divider().overlay(Wasteland.border)
            list
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Wasteland.base)
    }

    @ViewBuilder private var list: some View {
        if runtime.loopTasks.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 26)).foregroundStyle(Wasteland.textDim)
                Text("Henüz döngü yok. Yukarıdan bir tane ekle.")
                    .font(Wasteland.font(12)).foregroundStyle(Wasteland.textDim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(runtime.loopTasks) { task in
                        LoopRow(task: task)
                    }
                }
                .padding(12)
            }
        }
    }
}

// MARK: - Composer

private struct LoopComposer: View {
    @Environment(SessionRuntime.self) private var runtime

    @State private var title = ""
    @State private var prompt = ""
    @State private var doneWhen = ""
    @State private var checkKind: CheckKind = .agent
    @State private var maxPasses = 3
    @State private var rememberOnPass = true
    @State private var cwd = NSHomeDirectory()

    private var canAdd: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !prompt.trimmingCharacters(in: .whitespaces).isEmpty
            && !doneWhen.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Wasteland.acid).neonGlow(Wasteland.acid, radius: 5)
                Text("Döngü").font(Wasteland.font(15, weight: .semibold)).foregroundStyle(Wasteland.textPrimary)
            }
            Text("Üretici çalışır, ayrı bir denetçi 'tamamlandı mı' diye notlar, geçene ya da deneme hakkı bitene kadar tekrarlar.")
                .font(Wasteland.font(11)).foregroundStyle(Wasteland.textDim)

            TextField("Başlık", text: $title)
                .textFieldStyle(.plain).font(Wasteland.font(13)).foregroundStyle(Wasteland.textPrimary)
                .padding(7).background(Wasteland.surfaceHi, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Wasteland.border, lineWidth: 1))

            editor($prompt, placeholder: "Üretici ne yapsın? Örn: README'ye kurulum bölümü ekle", height: 60)

            Picker("", selection: $checkKind) {
                Text("Ajan denetçi").tag(CheckKind.agent)
                Text("Komut").tag(CheckKind.shell)
            }
            .pickerStyle(.segmented).labelsHidden()

            editor($doneWhen,
                   placeholder: checkKind == .agent
                    ? "Tamamlanma ölçütü (denetçi buna göre yargılar)"
                    : "Kabuk komutu, exit 0 = tamam. Örn: swift test",
                   height: 46)

            controls
        }
        .padding(14)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Stepper("Pass: \(maxPasses)", value: $maxPasses, in: 1...10)
                .font(Wasteland.font(11)).foregroundStyle(Wasteland.textDim).fixedSize()
            Toggle("Geçince beyne yaz", isOn: $rememberOnPass)
                .toggleStyle(.checkbox).font(Wasteland.font(11)).foregroundStyle(Wasteland.textDim).fixedSize()
            Spacer(minLength: 4)
            Button("Klasör seç…") { if let url = chooseClaudeDirectory() { cwd = url.path } }
                .buttonStyle(.link).font(.caption).tint(Wasteland.cyan)
            Button { add(run: false) } label: { Text("Ekle") }
                .buttonStyle(.bordered).tint(Wasteland.accent).disabled(!canAdd)
            Button { add(run: true) } label: { Label("Ekle + çalıştır", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent).tint(Wasteland.accent).disabled(!canAdd)
        }
    }

    private func editor(_ text: Binding<String>, placeholder: String, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(Wasteland.font(12)).foregroundStyle(Wasteland.textPrimary)
            .scrollContentBackground(.hidden).frame(height: height).padding(5)
            .background(Wasteland.surfaceHi, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Wasteland.border, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder).font(Wasteland.font(12)).foregroundStyle(Wasteland.textDim)
                        .padding(.horizontal, 9).padding(.vertical, 10).allowsHitTesting(false)
                }
            }
    }

    private func add(run: Bool) {
        let task = runtime.addLoopTask(
            title: title.trimmingCharacters(in: .whitespaces),
            prompt: prompt.trimmingCharacters(in: .whitespaces),
            cwd: cwd,
            doneWhen: doneWhen.trimmingCharacters(in: .whitespaces),
            checkKind: checkKind, maxPasses: maxPasses, rememberOnPass: rememberOnPass)
        title = ""; prompt = ""; doneWhen = ""
        if run { runtime.runLoop(task.id) }
    }
}

// MARK: - Row

private struct LoopRow: View {
    @Environment(SessionRuntime.self) private var runtime
    let task: LoopTask
    @State private var expanded = false
    @State private var proofs: [ProofRecord] = []
    @State private var confirmRerun = false

    private var isRunning: Bool { task.state == .running || task.state == .checking }
    private var log: [LoopLogLine] { runtime.loopLog[task.id] ?? [] }
    /// A finished run left evidence that a re-run would wipe. Guard re-running once that exists.
    private var hasResult: Bool {
        task.lastAttempt > 0 || task.state == .passed || task.state == .failed || task.state == .stopped
    }
    /// The passing attempt's resumable maker session, if this run recorded one.
    private var resumeSessionId: String? {
        proofs.last(where: { $0.passed })?.makerSessionId.flatMap { $0.isEmpty ? nil : $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if isRunning, !log.isEmpty { LoopLiveLog(lines: log) }
            if expanded { proofSection }
        }
        .padding(10)
        .background(Wasteland.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Wasteland.border, lineWidth: 1))
        .onAppear { if task.state == .passed { reload() } }   // so the header's continue button knows the session
        .confirmationDialog("Döngüyü yeniden çalıştır?", isPresented: $confirmRerun, titleVisibility: .visible) {
            Button("Kanıtları sil, yeniden çalıştır", role: .destructive) { runtime.runLoop(task.id) }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Bu döngünün mevcut kanıtları ve sonucu silinip baştan çalıştırılacak. Sonucu kaybetmemek için önce 'Claude'da devam et' ya da 'Sonucu kopyala' kullan.")
        }
        .onChange(of: task.state) { _, newState in
            // The moment a run settles, open the proof history so the result is visible without
            // a click; while it is already open, keep it in sync.
            if newState == .passed || newState == .failed || newState == .stopped {
                expanded = true
                reload()
            } else if expanded {
                reload()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).font(Wasteland.font(13, weight: .semibold)).foregroundStyle(Wasteland.textPrimary).lineLimit(1)
                HStack(spacing: 6) {
                    badge
                    Text(folderName).font(Wasteland.font(10)).foregroundStyle(Wasteland.textDim).lineLimit(1).truncationMode(.head)
                    Text(task.checkKind == .agent ? "ajan" : "komut").font(Wasteland.font(10)).foregroundStyle(Wasteland.textDim)
                }
            }
            Spacer(minLength: 4)
            Button { expanded.toggle(); if expanded { reload() } } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
            }.buttonStyle(.borderless).tint(Wasteland.cyan).help("Kanıt geçmişi")
            if isRunning {
                Button { runtime.stopLoop(task.id) } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(.bordered).tint(Wasteland.danger).help("Durdur")
            } else {
                if task.state == .passed, let sid = resumeSessionId {
                    Button { runtime.continueSession(sessionId: sid, cwd: task.cwd, title: "↩ \(task.title)") } label: {
                        Image(systemName: "bubble.left.and.bubble.right")
                    }.buttonStyle(.borderedProminent).tint(Wasteland.accent).help("Claude'da devam et")
                }
                Button {
                    if hasResult { confirmRerun = true } else { runtime.runLoop(task.id) }
                } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.bordered).tint(hasResult ? Wasteland.textDim : Wasteland.accent)
                    .help(hasResult ? "Yeniden çalıştır (mevcut sonucu siler)" : "Çalıştır")
            }
            Button { runtime.removeLoopTask(task.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).tint(Wasteland.textDim).help("Sil").disabled(isRunning)
        }
    }

    private var badge: some View {
        HStack(spacing: 4) {
            if isRunning { ProgressView().controlSize(.mini).tint(stateColor) }
            Text(stateText).font(Wasteland.font(10, weight: .semibold))
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(stateColor.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(stateColor.opacity(0.5), lineWidth: 1))
        .foregroundStyle(stateColor)
    }

    @ViewBuilder private var proofSection: some View {
        Divider().overlay(Wasteland.border)
        if proofs.isEmpty {
            Text("Henüz kanıt yok. Çalıştır.").font(Wasteland.font(10)).foregroundStyle(Wasteland.textDim)
        } else {
            ForEach(proofs) { ProofCard(proof: $0, cwd: task.cwd, title: task.title) }
        }
    }

    private func reload() { proofs = runtime.proofs(for: task.id) }

    private var folderName: String {
        let n = URL(fileURLWithPath: task.cwd).lastPathComponent
        return n.isEmpty ? task.cwd : n
    }

    private var stateColor: Color {
        switch task.state {
        case .idle: return Wasteland.textDim
        case .running: return Wasteland.accent
        case .checking: return Wasteland.cyan
        case .passed: return Wasteland.accent
        case .failed: return Wasteland.danger
        case .stopped: return Wasteland.textDim
        }
    }

    private var stateText: String {
        switch task.state {
        case .idle: return "Hazır"
        case .running: return "Üretiyor \(task.lastAttempt)/\(task.maxPasses)"
        case .checking: return "Denetleniyor \(task.lastAttempt)/\(task.maxPasses)"
        case .passed: return "Geçti · \(task.lastAttempt) pass"
        case .failed: return "Takıldı · \(task.maxPasses) pass"
        case .stopped: return "Durduruldu"
        }
    }
}

// MARK: - Live log

/// Streams the running loop's events (maker text, tool calls, checker verdict) in a fixed-height
/// box that auto-scrolls to the newest line, so you can watch progress before it passes.
private struct LoopLiveLog: View {
    let lines: [LoopLogLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(lines) { line in
                        Text(line.text)
                            .font(Wasteland.font(10, weight: line.kind == .phase ? .semibold : .regular))
                            .foregroundStyle(color(line.kind))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .id(line.id)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 150)
            .background(Wasteland.base, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Wasteland.border.opacity(0.6), lineWidth: 1))
            .onChange(of: lines.count) { _, _ in
                guard let last = lines.last else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func color(_ kind: LoopLogLine.Kind) -> Color {
        switch kind {
        case .phase:   return Wasteland.cyan
        case .maker:   return Wasteland.textPrimary
        case .checker: return Wasteland.textDim
        case .pass:    return Wasteland.accent
        case .fail:    return Wasteland.danger
        }
    }
}

// MARK: - Proof card

/// One attempt's evidence. A passed attempt opens on its result (the maker output) with actions to
/// carry it forward; a failed one opens on the checker's reason. The maker output sits in a bounded
/// scroll so a long answer can't blow up the row; the checker note is short, so it wraps and grows.
private struct ProofCard: View {
    @Environment(SessionRuntime.self) private var runtime
    let proof: ProofRecord
    let cwd: String
    let title: String
    @State private var showMaker: Bool
    @State private var copied = false

    init(proof: ProofRecord, cwd: String, title: String) {
        self.proof = proof
        self.cwd = cwd
        self.title = title
        _showMaker = State(initialValue: proof.passed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Deneme \(proof.attempt)").font(Wasteland.font(10, weight: .semibold)).foregroundStyle(Wasteland.textDim)
                Text(proof.passed ? "PASS" : "FAIL")
                    .font(Wasteland.font(10, weight: .bold))
                    .foregroundStyle(proof.passed ? Wasteland.accent : Wasteland.danger)
                Spacer(minLength: 4)
                Button(showMaker ? "Denetçi notu" : "Üretici çıktısı") { showMaker.toggle() }
                    .buttonStyle(.borderless).font(Wasteland.font(9, weight: .medium)).tint(Wasteland.cyan)
            }
            if showMaker {
                ScrollView {
                    Text(proof.makerOutput.isEmpty ? "(çıktı yok)" : proof.makerOutput)
                        .font(Wasteland.font(10)).foregroundStyle(Wasteland.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(7)
                }
                .frame(maxHeight: 240)
                .background(Wasteland.base, in: RoundedRectangle(cornerRadius: 6))
            } else {
                Text(proof.checkerOutput.isEmpty ? "(not yok)" : proof.checkerOutput)
                    .font(Wasteland.font(10)).foregroundStyle(Wasteland.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Wasteland.surfaceHi, in: RoundedRectangle(cornerRadius: 6))
    }

    /// Carry the result forward: reopen the maker's own `claude` session live (full context, so you
    /// can just keep talking), or copy the output. The continue button needs the session id that
    /// only newer runs recorded; copy always works.
    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if let sid = proof.makerSessionId, !sid.isEmpty {
                Button { runtime.continueSession(sessionId: sid, cwd: cwd, title: "↩ \(title)") } label: {
                    Label("Claude'da devam et", systemImage: "bubble.left.and.bubble.right")
                }
                .buttonStyle(.borderedProminent).tint(Wasteland.accent).controlSize(.small)
            }
            Button { copyResult() } label: {
                Label(copied ? "Kopyalandı" : "Sonucu kopyala", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered).tint(Wasteland.cyan).controlSize(.small)
            Spacer(minLength: 0)
        }
        .font(Wasteland.font(9, weight: .medium))
    }

    private func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(proof.makerOutput, forType: .string)
        copied = true
    }
}
