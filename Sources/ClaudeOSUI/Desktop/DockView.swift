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
            dockIcon("macwindow", "Finder", running: systemWindow(.finder) != nil, dimmed: systemWindow(.finder)?.minimized ?? false) { manager.openFinder() }
            dockIcon("square.grid.2x2", "Genel Bakış", running: systemWindow(.dashboard) != nil, dimmed: systemWindow(.dashboard)?.minimized ?? false) { manager.openDashboard() }
            dockIcon("brain", "Beyin", running: systemWindow(.brain) != nil, dimmed: systemWindow(.brain)?.minimized ?? false) { manager.openBrain() }
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
            dockIcon("gearshape", "Ayarlar", running: systemWindow(.settings) != nil, dimmed: systemWindow(.settings)?.minimized ?? false) { manager.openSettings() }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }

    private func systemWindow(_ kind: DesktopWindowManager.Kind) -> DesktopWindowManager.DesktopWindow? {
        manager.windows.first { $0.kind == kind }
    }

    private var terminalWindows: [DesktopWindowManager.DesktopWindow] {
        manager.windows.filter { if case .terminal = $0.kind { return true }; return false }
    }

    private func dockIcon(_ icon: String, _ help: String, tint: Color = .primary, running: Bool = false, dimmed: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 21))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(tint)
                    .opacity(dimmed ? 0.5 : 1)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
                Circle().fill(.white.opacity(0.7)).frame(width: 3, height: 3).opacity(running ? 1 : 0)
            }
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
