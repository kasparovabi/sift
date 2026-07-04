import CoreGraphics

/// Pure force-directed graph simulation, the way Obsidian's graph behaves: repulsion
/// pushes nodes apart, link springs pull connected nodes together, a centering force keeps
/// the whole thing in view, and collision keeps node circles from overlapping. One `relax`
/// call advances the sim one step and returns how far things moved, so the view can keep
/// ticking until it settles. A pinned (dragged) node is held in place and everything else
/// flows around it. No AppKit/SwiftUI here — so it is unit-testable.
struct GraphLayoutEngine {
    let ids: [String]
    let edges: [(from: String, to: String)]
    let radii: [String: CGFloat]
    let k: Double            // ideal link length
    let repCap: Double       // repulsion is local: ignore pairs farther than this
    let attraction: Double   // link spring strength
    let centering: Double    // pull toward the view centre
    let collisionPad: CGFloat

    init(ids: [String],
         edges: [(from: String, to: String)],
         radii: [String: CGFloat],
         k: Double = 46,
         attraction: Double = 1.4,
         centering: Double = 0.018,
         collisionPad: CGFloat = 6) {
        self.ids = ids
        self.edges = edges
        self.radii = radii
        self.k = k
        self.repCap = k * 3.6
        self.attraction = attraction
        self.centering = centering
        self.collisionPad = collisionPad
    }

    /// Phyllotaxis (sunflower) seed — a filled disk centred in the view. A filled start
    /// avoids the hollow-ring failure a single-circle seed settles into.
    func seed(size: CGSize) -> [String: CGPoint] {
        let golden = Double.pi * (3 - 5.0.squareRoot())
        let spacing = Double(min(size.width, size.height)) * 0.30 / Double(max(1, ids.count)).squareRoot()
        let cx = Double(size.width) / 2, cy = Double(size.height) / 2
        var p: [String: CGPoint] = [:]
        for (i, id) in ids.enumerated() {
            let r = (Double(i) + 0.5).squareRoot() * spacing
            let a = Double(i) * golden
            p[id] = CGPoint(x: cx + cos(a) * r, y: cy + sin(a) * r)
        }
        return p
    }

    /// Damping per step (d3's velocityDecay): velocity keeps a fraction each frame so
    /// oscillations decay and the graph settles instead of vibrating forever.
    private let velocityKeep = 0.6

    /// Advance the simulation one step. Returns average movement per node (to detect
    /// settling). `pinned`/`pinTo` hold the dragged node so neighbours flow toward it.
    /// Velocity is threaded in/out so motion is damped (settles) and feels fluid.
    /// `alpha` is a global temperature (1 = hot, 0 = frozen): it scales the forces so the
    /// sim is guaranteed to settle as alpha decays — even a frustrated layout stops moving.
    /// Collision is not scaled by alpha, so circles never overlap, even at rest.
    @discardableResult
    func relax(_ pos: inout [String: CGPoint], vel: inout [String: CGVector], size: CGSize,
               pinned: String? = nil, pinTo: CGPoint? = nil, alpha: Double = 1, maxStep: Double = 24) -> Double {
        let n = ids.count
        guard n > 0 else { return 0 }
        var disp = [String: CGVector](minimumCapacity: n)

        // Repulsion (local — beyond repCap a global push would settle low-degree nodes
        // onto one radius, i.e. a ring).
        for a in 0..<n {
            let ia = ids[a]; let pa = pos[ia]!
            for b in (a + 1)..<n {
                let ib = ids[b]; let pb = pos[ib]!
                var dx = Double(pa.x - pb.x), dy = Double(pa.y - pb.y)
                var dist = (dx * dx + dy * dy).squareRoot()
                if dist < 0.01 { dx = Double(a - b); dy = Double((a + b) % 5) + 0.5; dist = (dx * dx + dy * dy).squareRoot() }
                guard dist < repCap else { continue }
                let f = (k * k) / dist
                let ux = dx / dist, uy = dy / dist
                var va = disp[ia] ?? .zero; va.dx += ux * f; va.dy += uy * f; disp[ia] = va
                var vb = disp[ib] ?? .zero; vb.dx -= ux * f; vb.dy -= uy * f; disp[ib] = vb
            }
        }

        // Link springs.
        for e in edges where e.from != e.to {
            guard let pa = pos[e.from], let pb = pos[e.to] else { continue }
            let dx = Double(pa.x - pb.x), dy = Double(pa.y - pb.y)
            let dist = max(0.01, (dx * dx + dy * dy).squareRoot())
            let f = attraction * (dist * dist) / k
            let ux = dx / dist, uy = dy / dist
            var vf = disp[e.from] ?? .zero; vf.dx -= ux * f; vf.dy -= uy * f; disp[e.from] = vf
            var vt = disp[e.to] ?? .zero; vt.dx += ux * f; vt.dy += uy * f; disp[e.to] = vt
        }

        // Centering.
        let cx = Double(size.width) / 2, cy = Double(size.height) / 2
        for id in ids {
            let p = pos[id]!
            var v = disp[id] ?? .zero
            v.dx += (cx - Double(p.x)) * centering
            v.dy += (cy - Double(p.y)) * centering
            disp[id] = v
        }

        // Integrate: force feeds velocity, velocity is damped (so it settles), speed is
        // capped, position follows velocity. Pin the dragged node.
        var moved = 0.0
        for id in ids {
            if id == pinned, let target = pinTo { pos[id] = target; vel[id] = .zero; continue }
            let d = disp[id] ?? .zero
            var v = vel[id] ?? .zero
            v.dx = (v.dx + d.dx * alpha) * velocityKeep
            v.dy = (v.dy + d.dy * alpha) * velocityKeep
            let speed = (v.dx * v.dx + v.dy * v.dy).squareRoot()
            if speed > maxStep { v.dx *= maxStep / speed; v.dy *= maxStep / speed }
            vel[id] = v
            moved += min(speed, maxStep)
            pos[id] = CGPoint(x: Double(pos[id]!.x) + v.dx, y: Double(pos[id]!.y) + v.dy)
        }

        resolveCollisions(&pos, pinned: pinned, passes: 2)
        return moved / Double(n)
    }

    /// Positional collision resolution: nudge overlapping circles apart. A couple of passes
    /// per step converges to a no-overlap layout at rest.
    private func resolveCollisions(_ pos: inout [String: CGPoint], pinned: String?, passes: Int) {
        let n = ids.count
        for _ in 0..<passes {
            for a in 0..<n {
                let ia = ids[a]
                for b in (a + 1)..<n {
                    let ib = ids[b]
                    let pa = pos[ia]!, pb = pos[ib]!
                    let minDist = (radii[ia] ?? 5) + (radii[ib] ?? 5) + collisionPad
                    var dx = pa.x - pb.x, dy = pa.y - pb.y
                    var dist = (dx * dx + dy * dy).squareRoot()
                    if dist < 0.01 { dx = CGFloat(a - b); dy = 0.7; dist = (dx * dx + dy * dy).squareRoot() }
                    guard dist < minDist else { continue }
                    let overlap = minDist - dist
                    let ux = dx / dist, uy = dy / dist
                    if ia == pinned {
                        pos[ib] = CGPoint(x: pb.x - ux * overlap, y: pb.y - uy * overlap)
                    } else if ib == pinned {
                        pos[ia] = CGPoint(x: pa.x + ux * overlap, y: pa.y + uy * overlap)
                    } else {
                        pos[ia] = CGPoint(x: pa.x + ux * overlap / 2, y: pa.y + uy * overlap / 2)
                        pos[ib] = CGPoint(x: pb.x - ux * overlap / 2, y: pb.y - uy * overlap / 2)
                    }
                }
            }
        }
    }

    /// Settle from a fresh seed to a good static layout (instant). Velocity damping makes
    /// it converge; an early high speed cap lets it spread fast, then tightens.
    func layout(size: CGSize, iterations: Int = 400) -> [String: CGPoint] {
        var pos = seed(size: size)
        var vel: [String: CGVector] = [:]
        var alpha = 1.0
        for i in 0..<iterations {
            relax(&pos, vel: &vel, size: size, alpha: alpha, maxStep: i < 60 ? 60 : 22)
            alpha = max(0, alpha * 0.985)
        }
        return pos
    }
}
