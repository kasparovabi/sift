import SwiftUI
import ClaudeOSRuntime

/// The Claude OS dock: launchers (Finder, Dashboard, New session, Settings) plus a
/// running-window switcher for open terminals. Icons magnify toward the cursor, the
/// classic macOS dock effect — smooth proximity falloff, growing up from a shared baseline.
struct DockView: View {
    @Environment(SessionRuntime.self) private var runtime
    @Environment(DesktopWindowManager.self) private var manager
    let onNewSession: () -> Void

    @State private var hoverX: CGFloat?

    var body: some View {
        HStack(spacing: 8) {
            dockIcon("macwindow", "Finder", running: systemWindow(.finder) != nil, dimmed: systemWindow(.finder)?.minimized ?? false) { manager.openFinder() }
            dockIcon("square.grid.2x2", "Genel Bakış", running: systemWindow(.dashboard) != nil, dimmed: systemWindow(.dashboard)?.minimized ?? false) { manager.openDashboard() }
            dockIcon("brain", "Beyin", running: systemWindow(.brain) != nil, dimmed: systemWindow(.brain)?.minimized ?? false) { manager.openBrain() }
            dockIcon("bolt.fill", "Hızlı görev", running: systemWindow(.quickTask) != nil, dimmed: systemWindow(.quickTask)?.minimized ?? false) { manager.openQuickTask() }
            dockIcon("calendar.badge.clock", "Zamanlanmış", running: systemWindow(.scheduled) != nil, dimmed: systemWindow(.scheduled)?.minimized ?? false) { manager.openScheduled() }
            dockIcon("arrow.triangle.2.circlepath", "Döngü", running: systemWindow(.loop) != nil, dimmed: systemWindow(.loop)?.minimized ?? false) { manager.openLoop() }
            dockIcon("note.text", "Not ekle", running: !manager.stickyNotes.isEmpty) { manager.addStickyNote() }
            dockIcon("timer", "Odak", running: systemWindow(.focusTimer) != nil, dimmed: systemWindow(.focusTimer)?.minimized ?? false) { manager.openFocusTimer() }
            dockIcon("folder", "Klasörlerim", running: systemWindow(.folders) != nil, dimmed: systemWindow(.folders)?.minimized ?? false) { manager.openFolders() }
            dockIcon("plus.circle.fill", "Yeni oturum", tint: Wasteland.accent, action: onNewSession)

            if !terminalWindows.isEmpty {
                Rectangle().fill(Wasteland.border).frame(width: 1, height: 34).padding(.horizontal, 2)
                ForEach(terminalWindows) { window in
                    dockIcon("terminal", window.title, dimmed: window.minimized) {
                        manager.restore(window.id)
                        manager.focus(window.id)
                    }
                }
            }

            Rectangle().fill(Wasteland.border).frame(width: 1, height: 34).padding(.horizontal, 2)
            dockIcon("gearshape", "Ayarlar", running: systemWindow(.settings) != nil, dimmed: systemWindow(.settings)?.minimized ?? false) { manager.openSettings() }
        }
        .padding(8)
        .wastelandPanel(cornerRadius: 18)
        .shadow(color: Color(hex: 0x000000).opacity(0.4), radius: 10, y: 4)
        .coordinateSpace(name: "dock")
        .onContinuousHover(coordinateSpace: .named("dock")) { phase in
            switch phase {
            case .active(let p): hoverX = p.x
            case .ended: hoverX = nil
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: hoverX)
    }

    private func systemWindow(_ kind: DesktopWindowManager.Kind) -> DesktopWindowManager.DesktopWindow? {
        manager.windows.first { $0.kind == kind }
    }

    private var terminalWindows: [DesktopWindowManager.DesktopWindow] {
        manager.windows.filter { if case .terminal = $0.kind { return true }; return false }
    }

    /// Proximity magnification: 1.0 at rest, up to 1.5× directly under the cursor, with a
    /// smooth cosine falloff over `radius` so neighbours swell gently too.
    private func magnify(_ midX: CGFloat) -> CGFloat {
        guard let hoverX else { return 1 }
        let d = abs(midX - hoverX)
        let radius: CGFloat = 95
        guard d < radius else { return 1 }
        let t = 1 - d / radius
        return 1 + 0.5 * (1 - cos(t * .pi)) / 2
    }

    private func dockIcon(_ icon: String, _ help: String, tint: Color = Wasteland.textPrimary, running: Bool = false, dimmed: Bool = false, action: @escaping () -> Void) -> some View {
        GeometryReader { geo in
            let scale = magnify(geo.frame(in: .named("dock")).midX)
            Button(action: action) {
                VStack(spacing: 3) {
                    Image(systemName: icon)
                        .font(.system(size: 21))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(tint)
                        .opacity(dimmed ? 0.5 : 1)
                        .background(Wasteland.surfaceHi, in: RoundedRectangle(cornerRadius: 11))
                        .scaleEffect(scale, anchor: .bottom)
                    Circle().fill(Wasteland.accent).frame(width: 3, height: 3).opacity(running ? 1 : 0)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
                .overlay(alignment: .top) {
                    // Floating name label for the icon directly under the cursor (scale peaks
                    // at ~1.5 there). Sits above the magnified icon like macOS's dock labels.
                    Text(help)
                        .font(Wasteland.font(10)).fixedSize()
                        .foregroundStyle(Wasteland.textPrimary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Wasteland.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Wasteland.border))
                        .offset(y: -22)
                        .opacity(scale > 1.45 ? 1 : 0)
                        .allowsHitTesting(false)
                }
            }
            .buttonStyle(.plain)
            .help(help)
        }
        .frame(width: 44, height: 52)
    }
}
