import SwiftUI
import ClaudeOSRuntime

/// The Claude OS dock: launchers (Finder, Dashboard, New session, Settings) plus a
/// running-window switcher for open terminals.
struct DockView: View {
    @Environment(SessionRuntime.self) private var runtime
    @Environment(DesktopWindowManager.self) private var manager
    let onNewSession: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            dockIcon("macwindow", "Finder") { manager.openFinder() }
            dockIcon("square.grid.2x2", "Genel Bakış") { manager.openDashboard() }
            dockIcon("brain", "Beyin") { manager.openBrain() }
            dockIcon("plus.circle.fill", "Yeni oturum", tint: .accentColor, action: onNewSession)

            if !terminalWindows.isEmpty {
                Divider().frame(height: 34).padding(.horizontal, 2)
                ForEach(terminalWindows) { window in
                    dockIcon("terminal", window.title, dimmed: window.minimized) {
                        manager.restore(window.id)
                        manager.focus(window.id)
                    }
                }
            }

            Divider().frame(height: 34).padding(.horizontal, 2)
            dockIcon("gearshape", "Ayarlar") { manager.openSettings() }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }

    private var terminalWindows: [DesktopWindowManager.DesktopWindow] {
        manager.windows.filter { if case .terminal = $0.kind { return true }; return false }
    }

    private func dockIcon(_ icon: String, _ help: String, tint: Color = .primary, dimmed: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 21))
                .frame(width: 44, height: 44)
                .foregroundStyle(tint)
                .opacity(dimmed ? 0.5 : 1)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
