import SwiftUI
import ClaudeOSCore

struct ContentView: View {
    @State private var cwd: String = NSHomeDirectory()
    @State private var resumeId: String = ""
    @State private var launchToken = UUID()
    @State private var activeSpec: ClaudeLaunchSpec?

    private let environment = EnvironmentResolver.environmentStrings()
    private let binary = ClaudeBinary.resolve()

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            terminalArea
        }
        .onAppear {
            // M0 proof: open an embedded claude session immediately so the window
            // demonstrates full TUI fidelity without any interaction.
            if activeSpec == nil { launch() }
        }
    }

    private var controlBar: some View {
        HStack(spacing: 8) {
            TextField("Çalışma dizini", text: $cwd)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
            TextField("Resume session id (boşsa yeni oturum)", text: $resumeId)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            Button(action: launch) {
                Label(activeSpec == nil ? "Başlat" : "Yeniden başlat", systemImage: "play.fill")
            }
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(10)
    }

    @ViewBuilder
    private var terminalArea: some View {
        if let spec = activeSpec {
            TerminalEmulatorView(spec: spec, environment: environment, binary: binary)
                .id(launchToken)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("claude'u gömülü terminalde başlatmak için Başlat'a bas")
                    .foregroundStyle(.secondary)
                Text(binary.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func launch() {
        let trimmed = resumeId.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode: ClaudeLaunchSpec.Mode = trimmed.isEmpty
            ? .fresh(sessionId: UUID().uuidString.lowercased())
            : .resume(sessionId: trimmed)
        activeSpec = ClaudeLaunchSpec(mode: mode, workingDirectory: URL(fileURLWithPath: cwd))
        launchToken = UUID()
    }
}
