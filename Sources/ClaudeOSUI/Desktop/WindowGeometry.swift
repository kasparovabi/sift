import CoreGraphics

/// Pure conversions between the desktop's "canvas" coordinate space (top-left origin,
/// y-down, relative to the main window's content area) and screen coordinates
/// (bottom-left origin, y-up), plus work-area clamping. Unit-tested; no AppKit.
enum WindowGeometry {
    /// Screen frame for a window whose top-left is `canvasOrigin` in the content area.
    static func screenFrame(canvasOrigin: CGPoint, size: CGSize, contentScreenFrame: CGRect) -> CGRect {
        CGRect(x: contentScreenFrame.minX + canvasOrigin.x,
               y: contentScreenFrame.maxY - canvasOrigin.y - size.height,
               width: size.width, height: size.height)
    }

    /// Inverse: canvas top-left origin for a window at `screenFrame`.
    static func canvasOrigin(screenFrame: CGRect, contentScreenFrame: CGRect) -> CGPoint {
        CGPoint(x: screenFrame.minX - contentScreenFrame.minX,
                y: contentScreenFrame.maxY - screenFrame.maxY)
    }

    /// Clamp a canvas origin so the window stays within the work area (below the top bar,
    /// above the Dock, inside the left/right edges).
    static func clampToWorkArea(canvasOrigin: CGPoint, size: CGSize, contentSize: CGSize,
                                topInset: CGFloat, bottomInset: CGFloat) -> CGPoint {
        let maxX = max(0, contentSize.width - size.width)
        let maxY = max(topInset, contentSize.height - bottomInset - size.height)
        return CGPoint(x: min(max(0, canvasOrigin.x), maxX),
                       y: min(max(topInset, canvasOrigin.y), maxY))
    }
}
