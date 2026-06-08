import SwiftUI
import AppKit

/// A transparent AppKit view that starts a native window drag on mouse-down. Placed
/// behind the SwiftUI title-bar content; the WindowServer then moves the NSWindow
/// (smooth, no SwiftUI .offset). Double-click forwards to `onDoubleClick` (zoom).
struct TitleBarDragView: NSViewRepresentable {
    var onDoubleClick: () -> Void = {}

    func makeNSView(context: Context) -> NSView { DragView(onDoubleClick: onDoubleClick) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? DragView)?.onDoubleClick = onDoubleClick
    }

    final class DragView: NSView {
        var onDoubleClick: () -> Void
        init(onDoubleClick: @escaping () -> Void) {
            self.onDoubleClick = onDoubleClick
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onDoubleClick()
                return
            }
            window?.performDrag(with: event)
        }
    }
}
