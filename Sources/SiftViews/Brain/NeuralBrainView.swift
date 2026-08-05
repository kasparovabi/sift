import SwiftUI
import Combine
import SiftBrain

/// An Obsidian-style graph of the brain: entities are nodes (sized by connectivity),
/// relations are thin links. A live force simulation (GraphLayoutEngine) lays it out,
/// keeps node circles from overlapping, and — while you drag a node — flows the connected
/// nodes along with it, settling smoothly when you let go. Scroll/pinch to zoom, drag the
/// background to pan, drag a node to rearrange, tap a node to open it.
struct NeuralBrainView: View {
    let entities: [Entity]
    let edges: [(from: String, to: String)]
    var onSelect: (Entity) -> Void = { _ in }

    @State private var pos: [String: CGPoint] = [:]
    @State private var vel: [String: CGVector] = [:]
    @State private var engine: GraphLayoutEngine?
    @State private var laidOutFor: CGSize = .zero
    @State private var viewSize: CGSize = .zero
    @State private var simulating = false
    @State private var alpha: Double = 0   // sim temperature: hot while dragging, decays to rest

    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize = .zero
    @State private var dragId: String?
    @State private var dragTarget: CGPoint?
    @State private var dragMoved = false
    @State private var panning = false
    @State private var selectedId: String?
    @State private var hoveredId: String?
    // Camera fit: frames the whole graph into the view so nodes never spill off-screen,
    // no matter how large the settled layout grows. User zoom/pan composes on top.
    @State private var fitScale: CGFloat = 1
    @State private var fitCenter: CGPoint = .zero

    // The 60fps physics ticker only runs while the layout is actually moving.
    // An always-on `Timer.publish(…).autoconnect()` woke the main runloop 60×/s
    // forever — even with the graph settled — driving constant AttributeGraph
    // churn at idle. Gated on `simulating`: gestures start it, `tick()` stops it
    // when the graph comes to rest, so a still graph costs zero wakeups.
    @State private var tickerCancellable: AnyCancellable?

    private var degree: [String: Int] {
        var d: [String: Int] = [:]
        for e in edges where e.from != e.to { d[e.from, default: 0] += 1; d[e.to, default: 0] += 1 }
        return d
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Palette.base
                if entities.isEmpty {
                    ContentUnavailableView("The graph is empty", systemImage: "brain",
                        description: Text("As knowledge accumulates from your sessions, entities and relations appear here as a graph."))
                } else {
                    // Timeline drives the signal animation. The physics ticker stays separate
                    // and still stops when the layout settles; this only redraws.
                    TimelineView(.animation(minimumInterval: 1.0 / 40.0)) { timeline in
                        Canvas { ctx, size in
                            render(&ctx, size: size,
                                   time: timeline.date.timeIntervalSinceReferenceDate)
                        }
                    }
                        .gesture(dragGesture(in: geo.size))
                        .simultaneousGesture(
                            MagnificationGesture()
                                .onChanged { zoom = min(4, max(0.3, baseZoom * $0)) }
                                .onEnded { _ in baseZoom = zoom }
                        )
                        .onContinuousHover(coordinateSpace: .local) { phase in
                            guard dragId == nil, !panning else { return }
                            switch phase {
                            case .active(let p): hoveredId = nearest(to: layoutPoint(p, size: geo.size))
                            case .ended: hoveredId = nil
                            }
                        }
                }
                if !entities.isEmpty { legend; graphStats }
            }
            .contentShape(Rectangle())
            .onAppear { viewSize = geo.size; ensureLayout(geo.size) }
            .onChange(of: geo.size) { _, s in viewSize = s; ensureLayout(s) }
            .onChange(of: entities.count) { _, _ in laidOutFor = .zero; ensureLayout(geo.size) }
            .onChange(of: edges.count) { _, _ in laidOutFor = .zero; ensureLayout(geo.size) }
            .onChange(of: simulating) { _, on in setTicking(on) }
            .onDisappear { setTicking(false) }
        }
    }

    // MARK: - Rendering

    private func nodeColor(_ kind: String) -> Color {
        switch kind {
        case "person":      return Palette.magenta
        case "project":     return Palette.acid
        case "file":        return Palette.cyan
        case "tool", "lib": return Palette.accent
        case "concept":     return Palette.cyan
        default:            return Palette.textDim
        }
    }

    private func radius(_ deg: Int) -> CGFloat { 3 + min(10, CGFloat(deg).squareRoot() * 2.1) }

    /// Corner key for the node colours, so the kind-coding is legible.
    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            legendRow("person", "person")
            legendRow("project", "project")
            legendRow("file", "file")
            legendRow("tool", "tool / lib")
            legendRow("concept", "kavram")
        }
        .padding(8)
        .siftPanel(cornerRadius: 8)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(false)
    }

    private func legendRow(_ kind: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(nodeColor(kind)).frame(width: 7, height: 7)
            Text(label).font(Palette.font(10)).foregroundStyle(Palette.textDim)
        }
    }

    /// Top-right key: how many nodes/links are drawn, plus a controls hint so the
    /// drag/zoom/hover interactions are discoverable.
    private var graphStats: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(entities.count) nodes · \(edges.count) links")
                .font(Palette.font(10, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
            Text("drag · zoom · hover")
                .font(Palette.font(10)).foregroundStyle(Palette.textDim)
        }
        .padding(8)
        .siftPanel(cornerRadius: 8)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(false)
    }

    /// A stable per-edge phase in 0..<1, so every axon fires on its own rhythm instead of the
    /// whole graph pulsing in lockstep.
    private func phase(_ from: String, _ to: String) -> Double {
        var h: UInt64 = 5381
        for byte in from.utf8 { h = h &* 33 &+ UInt64(byte) }
        for byte in to.utf8 { h = h &* 33 &+ UInt64(byte) }
        return Double(h % 1000) / 1000
    }

    /// Point on the quadratic curve an edge is drawn along, so a signal rides the same arc.
    private func pointOnCurve(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
                       y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }

    private func render(_ ctx: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let s = fitScale * zoom   // combined camera scale (fit-to-view × user zoom)
        ctx.translateBy(x: center.x + pan.width, y: center.y + pan.height)
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -fitCenter.x, y: -fitCenter.y)

        let deg = degree

        // Focus = the hovered node (or, if none, the selected one). When set, it and its
        // direct neighbours stay bright while everything else dims — Obsidian's hover view.
        let focus = hoveredId ?? selectedId
        var neighbors: Set<String> = []
        if let focus {
            for e in edges where e.from != e.to {
                if e.from == focus { neighbors.insert(e.to) }
                else if e.to == focus { neighbors.insert(e.from) }
            }
        }
        func dimmed(_ id: String) -> Bool { focus != nil && id != focus && !neighbors.contains(id) }

        // Links. Drawn as shallow arcs rather than straight lines: in a dense graph two nodes
        // often have several near-parallel paths between them, and a slight bow separates
        // them instead of overprinting. Each edge fades between its endpoints' colours, so
        // where a link goes is readable without following it.
        let kinds = Dictionary(entities.map { ($0.id, $0.k) }, uniquingKeysWith: { a, _ in a })
        for e in edges where e.from != e.to {
            guard let a = pos[e.from], let b = pos[e.to] else { continue }
            let touchesFocus = focus != nil && (e.from == focus || e.to == focus)
            let faded = focus != nil && !touchesFocus

            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let dx = b.x - a.x, dy = b.y - a.y
            let control = CGPoint(x: mid.x - dy * 0.09, y: mid.y + dx * 0.09)
            var path = Path()
            path.move(to: a)
            path.addQuadCurve(to: b, control: control)

            // A link between two hubs carries more of the structure, so it draws heavier.
            let weight = min(CGFloat((deg[e.from] ?? 0) + (deg[e.to] ?? 0)), 24) / 24
            let width = (touchesFocus ? 2.0 : 0.9 + weight * 1.1) / s
            let strength = touchesFocus ? 0.95 : (faded ? 0.12 : 0.30 + weight * 0.35)
            let from = (touchesFocus ? Palette.accent : nodeColor(kinds[e.from] ?? "")).opacity(strength)
            let to = (touchesFocus ? Palette.accent : nodeColor(kinds[e.to] ?? "")).opacity(strength)
            ctx.stroke(path, with: .linearGradient(Gradient(colors: [from, to]),
                                                   startPoint: a, endPoint: b),
                       style: StrokeStyle(lineWidth: width, lineCap: .round))

            // The signal: a bright head with a short tail riding the same arc, like an
            // impulse travelling down an axon. Each edge keeps its own phase, so the graph
            // reads as a network that is alive rather than one synchronised blinker.
            //
            // Every edge carries traffic all the time. Focus only changes how brightly it
            // reads — suppressing signals on unfocused edges made the graph look dead the
            // moment a node was hovered or clicked, and a click leaves a node selected.
            let travel = (time * 0.28 + phase(e.from, e.to)).truncatingRemainder(dividingBy: 1)
            // A rest gap between impulses; only the first stretch of the cycle carries one.
            let dutyCycle = 0.62
            guard travel < dutyCycle else { continue }
            let t = travel / dutyCycle
            let signal = touchesFocus ? Palette.accent : nodeColor(kinds[e.to] ?? "")
            let lit = touchesFocus ? 1.0 : (faded ? 0.55 : 0.9)
            // Fade in and out at the ends so impulses emerge and land instead of popping.
            let ends = min(1, min(t, 1 - t) / 0.18) * lit

            var tail = Path()
            let tailStart = max(0, t - 0.13)
            tail.move(to: pointOnCurve(a, control, b, tailStart))
            var step = tailStart
            while step < t {
                step = min(t, step + 0.03)
                tail.addLine(to: pointOnCurve(a, control, b, step))
            }
            ctx.stroke(tail, with: .color(signal.opacity(0.5 * ends)),
                       style: StrokeStyle(lineWidth: (width * 1.6), lineCap: .round))

            let head = pointOnCurve(a, control, b, t)
            let headR = (touchesFocus ? 3.0 : 2.2) / s
            ctx.fill(circle(head, headR * 3),
                     with: .radialGradient(Gradient(colors: [signal.opacity(0.45 * ends), .clear]),
                                           center: head, startRadius: 0, endRadius: headR * 3))
            ctx.fill(circle(head, headR), with: .color(signal.opacity(0.95 * ends)))
        }

        // How recently each node was struck by an arriving impulse, so a node lights up as
        // the signal lands on it — the payoff that makes the links read as traffic.
        var fired: [String: Double] = [:]
        for e in edges where e.from != e.to {
            let travel = (time * 0.28 + phase(e.from, e.to)).truncatingRemainder(dividingBy: 1)
            guard travel < 0.62 else { continue }
            let t = travel / 0.62
            guard t > 0.82 else { continue }
            let strength = (t - 0.82) / 0.18
            fired[e.to] = max(fired[e.to] ?? 0, strength)
        }

        // Nodes. Lit rather than flat: a soft outer bloom plus a radial body gradient makes
        // the hubs read as depth instead of pasted-on dots.
        for n in entities {
            guard let c = pos[n.id] else { continue }
            let r = radius(deg[n.id] ?? 0)
            let dim = dimmed(n.id)
            let base = nodeColor(n.k)
            // Dimmed nodes still fire, just quietly — the whole network stays alive while
            // focus highlights one part of it.
            let fire = (fired[n.id] ?? 0) * (dim ? 0.35 : 1)

            let halo = n.id == focus ? r * 2.8 : r * (1.9 + fire * 1.3)
            let haloStrength = n.id == focus ? 0.55 : (dim ? 0.0 : 0.22 + fire * 0.45)
            if haloStrength > 0 {
                ctx.fill(circle(c, halo),
                         with: .radialGradient(Gradient(colors: [base.opacity(haloStrength), .clear]),
                                               center: c, startRadius: r * 0.5, endRadius: halo))
            }
            ctx.fill(circle(c, r * (1 + fire * 0.18)),
                     with: .radialGradient(
                        Gradient(colors: [base.opacity(dim ? 0.30 : 1.0),
                                          base.opacity(dim ? 0.16 : 0.72)]),
                        center: CGPoint(x: c.x - r * 0.3, y: c.y - r * 0.3),
                        startRadius: 0, endRadius: r * 1.4))
            if fire > 0 {
                ctx.fill(circle(c, r * 0.55),
                         with: .color(Palette.textPrimary.opacity(0.55 * fire)))
            }
            ctx.stroke(circle(c, r), with: .color(Palette.textPrimary.opacity(dim ? 0.08 : 0.32)), lineWidth: 0.7 / s)
        }

        // Labels with greedy declutter: highest-degree first, skip any that would collide
        // with one already placed. Font/offset are divided by `s` so labels stay a constant
        // on-screen size regardless of zoom. When focusing, label only the focus + neighbours.
        let threshold = zoom >= 1.8 ? 1 : (zoom >= 1.2 ? 3 : 6)
        let minGap = 34 / s
        var placed: [CGPoint] = []
        for n in entities.sorted(by: { (deg[$0.id] ?? 0) > (deg[$1.id] ?? 0) }) {
            guard let c = pos[n.id] else { continue }
            let focal = n.id == focus || neighbors.contains(n.id)
            let show = focus != nil ? focal : (deg[n.id] ?? 0) >= threshold
            guard show else { continue }
            // Always declutter (focus node is highest-degree so it's placed first and kept).
            if placed.contains(where: { hypot($0.x - c.x, $0.y - c.y) < minGap }) { continue }
            placed.append(c)
            let r = radius(deg[n.id] ?? 0)
            ctx.draw(Text(n.n).font(Palette.font(9 / s)).foregroundStyle(Palette.textPrimary.opacity(0.88)),
                     at: CGPoint(x: c.x, y: c.y - r - 6 / s), anchor: .bottom)
        }
    }

    private func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    // MARK: - Interaction

    private func layoutPoint(_ screen: CGPoint, size: CGSize) -> CGPoint {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let s = fitScale * zoom
        return CGPoint(x: fitCenter.x + (screen.x - center.x - pan.width) / s,
                       y: fitCenter.y + (screen.y - center.y - pan.height) / s)
    }

    private func nearest(to point: CGPoint) -> String? {
        var best: (id: String, dist: CGFloat)?
        let threshold = max(10, 22 / (fitScale * zoom))
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
                        simulating = true; alpha = max(alpha, 0.15)
                    } else {
                        panning = true; panStart = pan
                    }
                }
                if abs(v.translation.width) + abs(v.translation.height) > 3 { dragMoved = true }
                if dragId != nil {
                    // Set the drag target; the sim pins this node there and flows the rest.
                    dragTarget = layoutPoint(v.location, size: size)
                    simulating = true; alpha = max(alpha, 0.12)
                } else if panning {
                    pan = CGSize(width: panStart.width + v.translation.width,
                                 height: panStart.height + v.translation.height)
                }
            }
            .onEnded { _ in
                if let id = dragId, !dragMoved, let e = entities.first(where: { $0.id == id }) {
                    onSelect(e)
                } else if dragId == nil && !dragMoved {
                    // Clicking empty space clears the selection. Without this a single click
                    // left the graph permanently in focus mode: everything but one node
                    // stayed dimmed even after the pointer moved away.
                    selectedId = nil
                }
                dragId = nil
                dragTarget = nil
                panning = false
                simulating = true; alpha = max(alpha, 0.15)   // let it settle smoothly after release
            }
    }

    // MARK: - Simulation

    /// Start/stop the physics ticker. Idempotent: gestures re-assert
    /// `simulating = true` mid-drag, and the guard skips a redundant restart.
    private func setTicking(_ on: Bool) {
        if on {
            guard tickerCancellable == nil else { return }
            tickerCancellable = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common)
                .autoconnect()
                .sink { _ in tick() }
        } else {
            tickerCancellable?.cancel()
            tickerCancellable = nil
        }
    }

    private func tick() {
        guard simulating, let engine, !entities.isEmpty,
              viewSize.width > 0, viewSize.height > 0 else { return }
        let dragging = dragId != nil
        // Ease the temperature toward its target: stay hot (responsive) while dragging,
        // decay to zero after release so the graph settles and ticking stops.
        // Held deliberately low: a hot sim during a drag is what made the neighbours
        // overshoot and the whole graph shudder. The dragged node still follows the cursor
        // exactly (it is pinned, not simulated), so responsiveness doesn't depend on this.
        let target = dragging ? 0.12 : 0.0
        alpha += (target - alpha) * 0.07
        var p = pos
        var v = vel
        _ = engine.relax(&p, vel: &v, size: viewSize, pinned: dragId,
                                 pinTo: dragging ? dragTarget : nil,
                                 alpha: alpha, maxStep: dragging ? 14 : 18)
        pos = p
        vel = v
        if !dragging && alpha < 0.012 { alpha = 0; simulating = false }   // settled — stop ticking
    }

    private func ensureLayout(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != laidOutFor, !entities.isEmpty else { return }
        laidOutFor = size
        pan = .zero; zoom = 1; baseZoom = 1
        var radii: [String: CGFloat] = [:]
        let deg = degree
        for n in entities { radii[n.id] = radius(deg[n.id] ?? 0) }
        let eng = GraphLayoutEngine(ids: entities.map(\.id), edges: edges, radii: radii)
        engine = eng
        pos = eng.layout(size: size)   // instant good layout (no overlap)
        vel = [:]
        simulating = false
        computeFit(size: size)
    }

    /// Frame every node into the view: scale the settled bounding box down to fit, centered.
    /// Capped so a tiny graph isn't blown up. Recomputed only on (re)layout, so interaction
    /// doesn't make the camera jump.
    private func computeFit(size: CGSize) {
        guard !pos.isEmpty else { fitScale = 1; fitCenter = CGPoint(x: size.width / 2, y: size.height / 2); return }
        let xs = pos.values.map(\.x), ys = pos.values.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let bw = max(1, maxX - minX), bh = max(1, maxY - minY)
        let margin: CGFloat = 60
        fitScale = min(min((size.width - 2 * margin) / bw, (size.height - 2 * margin) / bh), 2.0)
        fitCenter = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
    }
}
