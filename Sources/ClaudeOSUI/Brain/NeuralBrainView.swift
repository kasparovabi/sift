import SwiftUI
import ClaudeOSBrain

/// A neural-network-style visualization of the brain: entities are glowing nodes,
/// relations are edges. Force-directed layout (nodes sized by connectivity), a gentle
/// pulse, and drag-to-rearrange. Tap a node to surface it in the list (via onSelect).
struct NeuralBrainView: View {
    let entities: [Entity]
    /// Entity-id pairs.
    let edges: [(from: String, to: String)]
    var onSelect: (Entity) -> Void = { _ in }

    @State private var pos: [String: CGPoint] = [:]
    @State private var laidOutFor: CGSize = .zero
    @State private var dragId: String?
    @State private var dragMoved = false

    private var degree: [String: Int] {
        var d: [String: Int] = [:]
        for e in edges where e.from != e.to {
            d[e.from, default: 0] += 1
            d[e.to, default: 0] += 1
        }
        return d
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Color(red: 0.04, green: 0.05, blue: 0.10),
                                        Color(red: 0.02, green: 0.02, blue: 0.05)],
                               startPoint: .top, endPoint: .bottom)
                if entities.isEmpty {
                    ContentUnavailableView("Ağ boş", systemImage: "brain",
                        description: Text("Oturumlardan bilgi biriktikçe varlıklar ve ilişkiler burada nöral ağ olarak belirir."))
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                        Canvas { ctx, size in
                            draw(&ctx, size: size, time: tl.date.timeIntervalSinceReferenceDate)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture())
            .onAppear { ensureLayout(geo.size) }
            .onChange(of: geo.size) { _, s in ensureLayout(s) }
            .onChange(of: entities.count) { _, _ in laidOutFor = .zero; ensureLayout(geo.size) }
            .onChange(of: edges.count) { _, _ in laidOutFor = .zero; ensureLayout(geo.size) }
        }
    }

    // MARK: - Rendering

    private func nodeColor(_ kind: String) -> Color {
        switch kind {
        case "person":          return .pink
        case "project":         return .orange
        case "file":            return .teal
        case "tool", "lib":     return .green
        case "concept":         return .cyan
        default:                return .purple
        }
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let deg = degree
        // Edges first (under nodes).
        for e in edges where e.from != e.to {
            guard let a = pos[e.from], let b = pos[e.to] else { continue }
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            ctx.stroke(path, with: .color(.cyan.opacity(0.16)), lineWidth: 1)
        }
        // Nodes.
        for (i, n) in entities.enumerated() {
            guard let c = pos[n.id] else { continue }
            let d = deg[n.id] ?? 0
            let r = 5 + min(20, CGFloat(d) * 2.4)
            let pulse = 1.0 + 0.18 * sin(time * 1.6 + Double(i) * 0.7)
            let col = nodeColor(n.k)
            let halo = r * 2.6 * pulse
            ctx.fill(
                Path(ellipseIn: CGRect(x: c.x - halo, y: c.y - halo, width: halo * 2, height: halo * 2)),
                with: .radialGradient(Gradient(colors: [col.opacity(0.40), .clear]),
                                      center: c, startRadius: 0, endRadius: halo)
            )
            ctx.fill(
                Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                with: .radialGradient(Gradient(colors: [.white, col]),
                                      center: c, startRadius: 0, endRadius: r)
            )
            if d >= 2 || dragId == n.id {
                ctx.draw(Text(n.n).font(.caption2).foregroundStyle(.white.opacity(0.9)),
                         at: CGPoint(x: c.x, y: c.y - r - 7), anchor: .bottom)
            }
        }
    }

    // MARK: - Interaction

    private func dragGesture() -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if dragId == nil { dragId = nearest(to: v.startLocation); dragMoved = false }
                if abs(v.translation.width) + abs(v.translation.height) > 3 { dragMoved = true }
                if let id = dragId { pos[id] = v.location }
            }
            .onEnded { v in
                if let id = dragId, !dragMoved,
                   let e = entities.first(where: { $0.id == id }) {
                    onSelect(e)   // a tap (no drag) selects the node
                }
                dragId = nil
            }
    }

    private func nearest(to point: CGPoint) -> String? {
        var best: (id: String, dist: CGFloat)?
        for n in entities {
            guard let c = pos[n.id] else { continue }
            let dist = hypot(c.x - point.x, c.y - point.y)
            if dist < 30, best == nil || dist < best!.dist { best = (n.id, dist) }
        }
        return best?.id
    }

    // MARK: - Layout

    private func ensureLayout(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != laidOutFor, !entities.isEmpty else { return }
        laidOutFor = size
        pos = forceLayout(size: size)
    }

    /// Deterministic Fruchterman-Reingold-style force layout (circle seed + repulsion +
    /// edge attraction + center gravity). Synchronous; entities are capped upstream.
    private func forceLayout(size: CGSize) -> [String: CGPoint] {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let ids = entities.map(\.id)
        let count = ids.count
        var p: [String: CGPoint] = [:]
        let seedR = min(size.width, size.height) * 0.38
        for (i, id) in ids.enumerated() {
            let a = Double(i) / Double(max(1, count)) * 2 * .pi
            p[id] = CGPoint(x: center.x + cos(a) * seedR, y: center.y + sin(a) * seedR)
        }
        let area = Double(size.width * size.height)
        let k = max(28.0, sqrt(area / Double(max(1, count))) * 0.55)   // ideal edge length
        var temp = Double(min(size.width, size.height)) * 0.10

        for _ in 0..<240 {
            var disp: [String: CGVector] = [:]
            // Repulsion between all pairs.
            for a in 0..<count {
                for b in (a + 1)..<count {
                    let pa = p[ids[a]]!, pb = p[ids[b]]!
                    var dx = Double(pa.x - pb.x), dy = Double(pa.y - pb.y)
                    var dist = (dx * dx + dy * dy).squareRoot()
                    if dist < 0.01 { dx = Double(a - b); dy = Double((a + b) % 7) + 0.5; dist = (dx*dx+dy*dy).squareRoot() }
                    let force = (k * k) / dist
                    let ux = dx / dist, uy = dy / dist
                    var va = disp[ids[a]] ?? .zero; va.dx += ux * force; va.dy += uy * force; disp[ids[a]] = va
                    var vb = disp[ids[b]] ?? .zero; vb.dx -= ux * force; vb.dy -= uy * force; disp[ids[b]] = vb
                }
            }
            // Attraction along edges.
            for e in edges where e.from != e.to {
                guard let pa = p[e.from], let pb = p[e.to] else { continue }
                let dx = Double(pa.x - pb.x), dy = Double(pa.y - pb.y)
                let dist = max(0.01, (dx * dx + dy * dy).squareRoot())
                let force = (dist * dist) / k
                let ux = dx / dist, uy = dy / dist
                var vf = disp[e.from] ?? .zero; vf.dx -= ux * force; vf.dy -= uy * force; disp[e.from] = vf
                var vt = disp[e.to] ?? .zero; vt.dx += ux * force; vt.dy += uy * force; disp[e.to] = vt
            }
            // Apply with center gravity and cooling temperature.
            for id in ids {
                var d = disp[id] ?? .zero
                let cur = p[id]!
                d.dx += Double(center.x - cur.x) * 0.03
                d.dy += Double(center.y - cur.y) * 0.03
                let len = max(0.01, (d.dx * d.dx + d.dy * d.dy).squareRoot())
                let step = min(temp, len)
                var nx = Double(cur.x) + d.dx / len * step
                var ny = Double(cur.y) + d.dy / len * step
                nx = min(max(24, nx), Double(size.width) - 24)
                ny = min(max(24, ny), Double(size.height) - 24)
                p[id] = CGPoint(x: nx, y: ny)
            }
            temp = max(2.0, temp * 0.985)
        }
        return p
    }
}
