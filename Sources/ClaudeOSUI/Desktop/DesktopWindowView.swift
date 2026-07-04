import SwiftUI

/// SwiftUI content hosted inside a real NSWindow (see WindowHostController): a draggable
/// title bar + the window's content, filling the window. The NSWindow owns frame, drag,
/// resize, shadow, and rounded corners — so there is no SwiftUI `.offset` to flicker.
///
/// Each window carries a colour identity by kind (Finder = blue, Brain = purple, …): a
/// tinted title-bar icon, a thin accent strip on top, and — when focused — an accent
/// border in that same colour. Unfocused windows dim back so the active one stands out.
struct DesktopWindowView<Content: View>: View {
    let window: DesktopWindowManager.DesktopWindow
    let manager: DesktopWindowManager
    let onClose: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    /// Active = the frontmost (highest-z) non-minimized window. Reads `manager.windows`
    /// (@Observable) so the accent border follows focus changes.
    private var isActive: Bool {
        manager.windows.filter { !$0.minimized }.max(by: { $0.z < $1.z })?.id == window.id
    }

    private var kindAccent: Color {
        switch window.kind {
        case .finder:    return Wasteland.cyan
        case .dashboard: return Wasteland.cyan
        case .brain:     return Wasteland.magenta
        case .settings:  return Wasteland.textDim
        case .quickTask: return Wasteland.acid
        case .scheduled: return Wasteland.acid
        case .loop:      return Wasteland.accent
        case .focusTimer: return Wasteland.danger
        case .folders:   return Wasteland.cyan
        case .terminal:  return Wasteland.accent
        }
    }

    private var kindIcon: String {
        switch window.kind {
        case .finder:    return "macwindow"
        case .dashboard: return "square.grid.2x2"
        case .brain:     return "brain"
        case .settings:  return "gearshape"
        case .quickTask: return "bolt.fill"
        case .scheduled: return "calendar.badge.clock"
        case .loop:      return "arrow.triangle.2.circlepath"
        case .focusTimer: return "timer"
        case .folders:   return "folder"
        case .terminal:  return "terminal"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Wasteland.base)
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(isActive ? kindAccent.opacity(0.85) : Wasteland.border,
                              lineWidth: isActive ? 1.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 11))
    }

    private var titleBar: some View {
        ZStack {
            TitleBarDragView(onDoubleClick: { manager.zoom(window.id) })   // native drag layer (behind)
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    light(Wasteland.danger, "xmark") { onClose() }
                    light(Wasteland.acid, "minus") { manager.minimize(window.id) }
                    light(Wasteland.accent, "arrow.up.left.and.arrow.down.right") { manager.zoom(window.id) }
                }
                .onHover { hovering = $0 }
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Image(systemName: kindIcon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(kindAccent.opacity(isActive ? 1 : 0.55))
                    Text(window.title).font(Wasteland.font(11, weight: .medium)).lineLimit(1)
                        .foregroundStyle(Wasteland.textPrimary.opacity(isActive ? 0.95 : 0.5))
                }
                .allowsHitTesting(false)
                Spacer(minLength: 8)
                Color.clear.frame(width: 54, height: 1)
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 30)
        .background(Wasteland.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(kindAccent.opacity(isActive ? 0.9 : 0.25))
                .frame(height: 2)
        }
    }

    private func light(_ color: Color, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle().fill(color).frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.black.opacity(hovering ? 0.55 : 0))
                )
        }
        .buttonStyle(.plain)
    }
}
