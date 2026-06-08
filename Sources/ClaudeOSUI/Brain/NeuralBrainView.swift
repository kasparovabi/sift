import SwiftUI
import ClaudeOSBrain

/// An Obsidian-style graph of the brain: entities are nodes (sized by connectivity),
/// relations are thin links. Force-directed layout settled in free space then fit to the
/// view (so nodes spread organically instead of piling on the edges). Scroll/pinch to
/// zoom, drag the background to pan, drag a node to rearrange, tap a node to open it.
struct NeuralBrainView: View {
    let entities: [Entity]
    let edges: [(from: String, to: String)]
    var onSelect: (Entity) -> Void = { _ in }

    @State private var pos: [String: CGPoint] = [:]
    @State private var laidOutFor: CGSize = .zero
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize = .zero
    @State private var dragId: String?
    @State private var dragMoved = false
    @State private var panning = false
    @State private var selectedId: String?

    private var degree: [String: Int] {
        var d: [String: Int] = [:]
        for e in edges where e.from != e.to { d[e.from, default: 0] += 1; d[e.to, default: 0] += 1 }
        return d
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(red: 0.03, green: 0.04, blue: 0.07)
                if entities.isEmpty {
                    ContentUnavailableView("Ağ boş", systemImage: "brain",
                        description: Text("Oturumlardan bilgi biriktikçe varlıklar ve ilişkiler burada graf olarak belirir."))
                } else {
                    Canvas { ctx, size in render(&ctx, size: size) }
                        .gesture(dragGesture(in: geo.size))
                        .simultaneousGesture(
                            MagnificationGesture()
                                .onChanged { zoom = min(4, max(0.3, baseZoom * $0)) }
                                .onEnded { _ in baseZoom = zoom }
                        )
                }
            }
            .contentShape(Rectangle())
            .onAppear { ensureLayout(geo.size) }
            .onChange(of: geo.size) { _, s in ensureLayout(s) }
            .onChange(of: entities.count) { _, _ in laidOutFor = .zero; ensureLayout(geo.size) }
            .onChange(of: edges.count) { _, _ in laidOutFor = .zero; ensureLayout(geo.size) }
        }
    }

    // MARK: - Rendering

    private func nodeColor(_ kind: String) -> Color {
        switch kind {
        case "person":      return Color(red: 0.93, green: 0.55, blue: 0.66)
        case "project":     return Color(red: 0.95, green: 0.66, blue: 0.36)
        case "file":        return Color(red: 0.45, green: 0.80, blue: 0.80)
        case "tool", "lib": return Color(red: 0.55, green: 0.82, blue: 0.55)
        case "concept":     return Color(red: 0.55, green: 0.72, blue: 0.96)
        default:            return Color(red: 0.74, green: 0.66, blue: 0.95)
        }
    }

    private func radius(_ deg: Int) -> CGFloat { 3 + min(10, CGFloat(deg).squareRoot() * 2.1) }

    private func render(_ ctx: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        ctx.translateBy(x: center.x + pan.width, y: center.y + pan.height)
        ctx.scaleBy(x: zoom, y: zoom)
        ctx.translateBy(x: -center.x, y: -center.y)

        let deg = degree

        // Links (thin, Obsidian-style; brighter for the selected node's edges).
        for e in edges where e.from != e.to {
            guard let a = pos[e.from], let b = pos[e.to] else { continue }
            let lit = selectedId == e.from || selectedId == e.to
            var path = Path(); path.move(to: a); path.addLine(to: b)
            ctx.stroke(path,
                       with: .color(lit ? Color(red: 0.62, green: 0.78, blue: 1).opacity(0.95)
                                        : Color(red: 0.58, green: 0.68, blue: 0.88).opacity(0.5)),
                       lineWidth: lit ? 1.8 : 1.2)
        }

        // Nodes.
        for n in entities {
            guard let c = pos[n.id] else { continue }
            let r = radius(deg[n.id] ?? 0)
            let col = nodeColor(n.k)
            let lit = selectedId == n.id
            // Flat node with a faint halo only — a big glow would bury the short links.
            if lit {
                let halo = r * 2.6
                ctx.fill(circle(c, halo),
                         with: .radialGradient(Gradient(colors: [col.opacity(0.5), .clear]),
                                               center: c, startRadius: 0, endRadius: halo))
            }
            ctx.fill(circle(c, r), with: .color(col))
            ctx.stroke(circle(c, r), with: .color(.white.opacity(0.32)), lineWidth: 0.7)
        }

        // Labels with greedy declutter: place the highest-degree first and skip any label
        // that would collide with one already placed — so dense hubs stay readable instead
        // of stacking text. Zooming in lowers the bar and reveals more.
        let threshold = zoom >= 1.8 ? 1 : (zoom >= 1.2 ? 3 : 6)
        let minGap = 34 / zoom
        var placed: [CGPoint] = []
        for n in entities.sorted(by: { (deg[$0.id] ?? 0) > (deg[$1.id] ?? 0) }) {
            guard let c = pos[n.id] else { continue }
            let isSel = selectedId == n.id
            guard isSel || (deg[n.id] ?? 0) >= threshold else { continue }
            if !isSel && placed.contains(where: { hypot($0.x - c.x, $0.y - c.y) < minGap }) { continue }
            placed.append(c)
            let r = radius(deg[n.id] ?? 0)
            ctx.draw(Text(n.n).font(.system(size: 9)).foregroundStyle(.white.opacity(0.88)),
                     at: CGPoint(x: c.x, y: c.y - r - 6), anchor: .bottom)
        }
    }

    private func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    // MARK: - Interaction

    private func layoutPoint(_ screen: CGPoint, size: CGSize) -> CGPoint {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return CGPoint(x: center.x + (screen.x - center.x - pan.width) / zoom,
                       y: center.y + (screen.y - center.y - pan.height) / zoom)
    }

    private func nearest(to point: CGPoint) -> String? {
        var best: (id: String, dist: CGFloat)?
        let threshold = max(12, 22 / zoom)
        for n in entities {
            guard let c = pos[n.id] else { continue }
            let dist = hypot(c.x - point.x, c.y - point.y)
            if dist < threshold, best == nil || dist < best!.dist { best = (n.id, dist) }
        }
        return best?.id
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if dragId == nil && !panning {
                    if let hit = nearest(to: layoutPoint(v.startLocation, size: size)) {
                        dragId = hit; selectedId = hit; dragMoved = false
                    } else {
                        panning = true; panStart = pan
                    }
                }
                if abs(v.translation.width) + abs(v.translation.height) > 3 { dragMoved = true }
                if let id = dragId {
                    pos[id] = layoutPoint(v.location, size: size)
                } else if panning {
                    pan = CGSize(width: panStart.width + v.translation.width,
                                 height: panStart.height + v.translation.height)
                }
            }
            .onEnded { _ in
                if let id = dragId, !dragMoved, let e = entities.first(where: { $0.id == id }) {
                    onSelect(e)
                }
                dragId = nil
                panning = false
            }
    }

    // MARK: - Layout

    private func ensureLayout(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != laidOutFor, !entities.isEmpty else { return }
        laidOutFor = size
        pan = .zero; zoom = 1; baseZoom = 1
        pos = forceLayout(size: size)
    }

    /// Fruchterman-Reingold in free space (no edge clamp), then fit to the view so the
    /// graph spreads organically and is centered — not piled along the window edges.
    private func forceLayout(size: CGSize) -> [String: CGPoint] {
        let ids = entities.map(\.id)
        let n = ids.count
        var p: [String: CGPoint] = [:]
        // Phyllotaxis (sunflower) seed — fills a disk so there are interior nodes from
        // the start. A single-circle seed stays symmetric and the forces settle into a
        // hollow ring (nodes pile on the view edges); a filled disk breaks that.
        let golden = Double.pi * (3 - 5.0.squareRoot())
        let spacing = 26.0
        for (i, id) in ids.enumerated() {
            let r = (Double(i) + 0.5).squareRoot() * spacing
            let a = Double(i) * golden
            p[id] = CGPoint(x: cos(a) * r, y: sin(a) * r)
        }
        let k = (1_000_000.0 / Double(max(1, n))).squareRoot()   // ideal spacing
        let repCap = k * 3.5   // repulsion is local — beyond this, no push. A global push
                               // makes every low-degree node settle at one radius (a ring).
        var temp = 220.0
        for _ in 0..<300 {
            var disp: [String: CGVector] = [:]
            for a in 0..<n {
                for b in (a + 1)..<n {
                    let pa = p[ids[a]]!, pb = p[ids[b]]!
                    var dx = Double(pa.x - pb.x), dy = Double(pa.y - pb.y)
                    var dist = (dx * dx + dy * dy).squareRoot()
                    if dist < 0.01 { dx = Double(a - b); dy = Double((a + b) % 5) + 0.5; dist = (dx*dx+dy*dy).squareRoot() }
                    guard dist < repCap else { continue }
                    let force = (k * k) / dist
                    let ux = dx / dist, uy = dy / dist
                    var va = disp[ids[a]] ?? .zero; va.dx += ux * force; va.dy += uy * force; disp[ids[a]] = va
                    var vb = disp[ids[b]] ?? .zero; vb.dx -= ux * force; vb.dy -= uy * force; disp[ids[b]] = vb
                }
            }
            for e in edges where e.from != e.to {
                guard let pa = p[e.from], let pb = p[e.to] else { continue }
                let dx = Double(pa.x - pb.x), dy = Double(pa.y - pb.y)
                let dist = max(0.01, (dx * dx + dy * dy).squareRoot())
                let force = 1.6 * (dist * dist) / k   // strong link pull → clear clusters
                let ux = dx / dist, uy = dy / dist
                var vf = disp[e.from] ?? .zero; vf.dx -= ux * force; vf.dy -= uy * force; disp[e.from] = vf
                var vt = disp[e.to] ?? .zero; vt.dx += ux * force; vt.dy += uy * force; disp[e.to] = vt
            }
            for id in ids {
                var d = disp[id] ?? .zero
                d.dx += -Double(p[id]!.x) * 0.016   // gravity pulls leaves in, fills the middle
                d.dy += -Double(p[id]!.y) * 0.016
                let len = max(0.01, (d.dx * d.dx + d.dy * d.dy).squareRoot())
                let step = min(temp, len)
                p[id] = CGPoint(x: Double(p[id]!.x) + d.dx / len * step, y: Double(p[id]!.y) + d.dy / len * step)
            }
            temp = max(2.0, temp * 0.97)
        }
        return fit(p, into: size)
    }

    /// Scale + center the settled positions to fit the view with a margin.
    private func fit(_ p: [String: CGPoint], into size: CGSize) -> [String: CGPoint] {
        guard !p.isEmpty else { return p }
        let xs = p.values.map(\.x), ys = p.values.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let bw = max(1, maxX - minX), bh = max(1, maxY - minY)
        let margin: CGFloat = 70
        let scale = min(min((size.width - 2 * margin) / bw, (size.height - 2 * margin) / bh), 2.0)
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        var out: [String: CGPoint] = [:]
        for (id, pt) in p {
            out[id] = CGPoint(x: size.width / 2 + (pt.x - cx) * scale,
                              y: size.height / 2 + (pt.y - cy) * scale)
        }
        return out
    }
}
