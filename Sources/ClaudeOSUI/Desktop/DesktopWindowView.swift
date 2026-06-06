import SwiftUI

/// A single floating desktop window: traffic-light chrome, a draggable title bar,
/// a resize grip, and arbitrary content. Drag/resize are applied as a *local*
/// offset/size delta and only committed to the manager on release, so moving one
/// window doesn't re-render (and re-layout the terminals of) every other window.
struct DesktopWindowView<Content: View>: View {
    let window: DesktopWindowManager.DesktopWindow
    let manager: DesktopWindowManager
    let isActive: Bool
    let onClose: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var dragTranslation: CGSize = .zero
    @State private var resizeDelta: CGSize = .zero
    @State private var isDragging = false
    @State private var isResizing = false

    private var liveSize: CGSize {
        CGSize(width: max(320, window.size.width + resizeDelta.width),
               height: max(220, window.size.height + resizeDelta.height))
    }
    private var liveOrigin: CGPoint {
        CGPoint(x: window.origin.x + dragTranslation.width,
                y: max(0, window.origin.y + dragTranslation.height))
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: liveSize.width, height: liveSize.height)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(isActive ? Color.accentColor.opacity(0.7) : .white.opacity(0.12),
                              lineWidth: isActive ? 1.5 : 1)
        )
        .overlay(alignment: .bottomTrailing) { resizeGrip }
        .shadow(color: .black.opacity(isActive ? 0.45 : 0.3), radius: isActive ? 22 : 12, x: 0, y: 8)
        .offset(x: liveOrigin.x, y: liveOrigin.y)
        .zIndex(window.z + (isDragging || isResizing ? 10_000 : 0))
        .simultaneousGesture(TapGesture().onEnded { manager.focus(window.id) })
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                trafficLight(.red, symbol: "xmark") { onClose() }
                trafficLight(.yellow, symbol: "minus") { manager.minimize(window.id) }
                trafficLight(.green, symbol: "arrow.up.left.and.arrow.down.right") { manager.zoom(window.id) }
            }
            .onHover { hoveringControls = $0 }
            Spacer(minLength: 8)
            Text(window.title).font(.caption).fontWeight(.medium).lineLimit(1)
            Spacer(minLength: 8)
            Color.clear.frame(width: 54, height: 1)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.ultraThinMaterial)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if !isDragging { isDragging = true; manager.focus(window.id) }
                    dragTranslation = value.translation
                }
                .onEnded { value in
                    isDragging = false
                    let final = CGPoint(x: window.origin.x + value.translation.width,
                                        y: max(0, window.origin.y + value.translation.height))
                    dragTranslation = .zero
                    let canvas = manager.canvasSize
                    // Only snap on a deliberate drag toward an edge. A small nudge on a
                    // window that already sits near the edge should just move it, so the
                    // user can park a window flush at the top/left corner.
                    let moved = hypot(value.translation.width, value.translation.height)
                    // Use the unclamped predicted y for the top test, otherwise the
                    // max(0, …) clamp above would make the top zone impossible to avoid.
                    let rawY = window.origin.y + value.translation.height
                    if moved > 24, rawY <= 4 {
                        manager.snap(window.id, .top)
                    } else if moved > 24, final.x <= 4 {
                        manager.snap(window.id, .left)
                    } else if moved > 24, canvas.width > 0, final.x + window.size.width >= canvas.width - 4 {
                        manager.snap(window.id, .right)
                    } else {
                        manager.move(window.id, to: final)
                    }
                }
        )
        .onTapGesture(count: 2) { manager.zoom(window.id) }
    }

    @State private var hoveringControls = false

    private func trafficLight(_ color: Color, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle().fill(color).frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.black.opacity(hoveringControls ? 0.55 : 0))
                )
        }
        .buttonStyle(.plain)
    }

    private var resizeGrip: some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(6)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if !isResizing { isResizing = true; manager.focus(window.id) }
                        resizeDelta = value.translation
                    }
                    .onEnded { value in
                        isResizing = false
                        manager.resize(window.id, to: CGSize(width: window.size.width + value.translation.width,
                                                             height: window.size.height + value.translation.height))
                        resizeDelta = .zero
                    }
            )
    }
}
