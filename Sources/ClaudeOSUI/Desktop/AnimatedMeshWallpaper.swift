import SwiftUI

/// A slowly drifting `MeshGradient` desktop wallpaper. The palette comes from the selected
/// preset; the interior control points breathe over time so the colours flow like aurora.
/// GPU-cheap and throttled to ~20fps. Requires macOS 15+ (callers gate with #available).
@available(macOS 15.0, *)
struct AnimatedMeshWallpaper: View {
    let colors: [Color]   // 9 colors, row-major 3×3

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: false)) { ctx in
            MeshGradient(width: 3, height: 3,
                         points: Self.points(ctx.date.timeIntervalSinceReferenceDate),
                         colors: colors)
                .ignoresSafeArea()
        }
    }

    /// Corners pinned; edge midpoints slide along their edge; the centre roams — all at
    /// different slow speeds/phases so the field never visibly repeats.
    static func points(_ t: Double) -> [SIMD2<Float>] {
        func wob(_ base: Float, _ phase: Double, _ speed: Double, _ amp: Float) -> Float {
            base + Float(sin(t * speed + phase)) * amp
        }
        return [
            SIMD2(0, 0),
            SIMD2(wob(0.5, 0.0, 0.13, 0.09), 0),
            SIMD2(1, 0),
            SIMD2(0, wob(0.5, 1.3, 0.11, 0.09)),
            SIMD2(wob(0.5, 2.1, 0.17, 0.11), wob(0.5, 0.7, 0.15, 0.11)),
            SIMD2(1, wob(0.5, 3.4, 0.12, 0.09)),
            SIMD2(0, 1),
            SIMD2(wob(0.5, 4.2, 0.10, 0.09), 1),
            SIMD2(1, 1),
        ]
    }
}
