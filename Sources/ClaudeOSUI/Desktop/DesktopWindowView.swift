import SwiftUI

/// SwiftUI content hosted inside a real NSWindow (see WindowHostController): a draggable
/// title bar + the window's content, filling the window. The NSWindow owns frame, drag,
/// resize, shadow, and rounded corners — so there is no SwiftUI `.offset` to flicker.
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

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(red: 0.13, green: 0.14, blue: 0.17))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(isActive ? Color.accentColor.opacity(0.7) : .white.opacity(0.12),
                              lineWidth: isActive ? 1.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 11))
    }

    private var titleBar: some View {
        ZStack {
            TitleBarDragView(onDoubleClick: { manager.zoom(window.id) })   // native drag layer (behind)
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    light(.red, "xmark") { onClose() }
                    light(.yellow, "minus") { manager.minimize(window.id) }
                    light(.green, "arrow.up.left.and.arrow.down.right") { manager.zoom(window.id) }
                }
                .onHover { hovering = $0 }
                Spacer(minLength: 8)
                Text(window.title).font(.caption).fontWeight(.medium).lineLimit(1)
                    .allowsHitTesting(false)
                Spacer(minLength: 8)
                Color.clear.frame(width: 54, height: 1)
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 30)
        .background(Color(red: 0.17, green: 0.18, blue: 0.22))
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
