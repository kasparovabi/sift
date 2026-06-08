import SwiftUI

/// A single floating desktop window: traffic-light chrome, a draggable title bar, a
/// resize grip, and arbitrary content.
///
/// The chrome (and the drag/resize state) lives in `WindowChrome`, a `ViewModifier`,
/// so the window's *content* is built once by this view and is NOT re-evaluated on
/// every drag frame. During a move only the modifier's body re-runs (applying a new
/// `.offset`); the wrapped content — e.g. Finder's 3-pane HSplitView + long list — is
/// passed through untouched, which is what keeps dragging flicker-free.
struct DesktopWindowView<Content: View>: View {
    let window: DesktopWindowManager.DesktopWindow
    let manager: DesktopWindowManager
    let isActive: Bool
    let onClose: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .modifier(WindowChrome(window: window, manager: manager, isActive: isActive, onClose: onClose))
    }
}

/// Window chrome + drag/resize behavior. Owns the high-frequency drag/resize state so
/// that state changes re-run only this modifier, never the wrapped content's body.
private struct WindowChrome: ViewModifier {
    let window: DesktopWindowManager.DesktopWindow
    let manager: DesktopWindowManager
    let isActive: Bool
    let onClose: () -> Void

    @State private var dragTranslation: CGSize = .zero
    @State private var resizeDelta: CGSize = .zero
    @State private var isDragging = false
    @State private var isResizing = false
    @State private var hoveringControls = false

    private var moving: Bool { isDragging || isResizing }

    private var liveSize: CGSize {
        CGSize(width: max(320, window.size.width + resizeDelta.width),
               height: max(220, window.size.height + resizeDelta.height))
    }
    private var liveOrigin: CGPoint {
        CGPoint(x: window.origin.x + dragTranslation.width,
                y: max(0, window.origin.y + dragTranslation.height))
    }

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: liveSize.width, height: liveSize.height)
        // While moving/resizing use an OPAQUE background and a light shadow: a
        // translucent material re-samples the backdrop and a large blurred shadow is
        // recomputed every frame as the window moves, both of which flicker. Restore
        // the material + full shadow once the window is at rest.
        .background(moving ? AnyShapeStyle(Color(red: 0.13, green: 0.14, blue: 0.17)) : AnyShapeStyle(.regularMaterial))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(isActive ? Color.accentColor.opacity(0.7) : .white.opacity(0.12),
                              lineWidth: isActive ? 1.5 : 1)
        )
        .overlay(alignment: .bottomTrailing) { resizeGrip }
        .shadow(color: .black.opacity(isActive ? 0.45 : 0.3),
                radius: moving ? 6 : (isActive ? 22 : 12), x: 0, y: moving ? 3 : 8)
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
                    // window already near the edge should just move it, so the user can
                    // park a window flush at the top/left corner.
                    let moved = hypot(value.translation.width, value.translation.height)
                    let rawY = window.origin.y + value.translation.height   // unclamped, for the top test
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
            .foregroundStyle(isResizing ? .primary : .secondary)
            .frame(width: 20, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.thinMaterial)
                    .opacity(isResizing ? 1 : 0.55)
            )
            .padding(3)
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
