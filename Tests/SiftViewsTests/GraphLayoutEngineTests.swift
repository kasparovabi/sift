import XCTest
import CoreGraphics
@testable import SiftViews

final class GraphLayoutEngineTests: XCTestCase {
    let size = CGSize(width: 800, height: 600)

    private func engine(ids: [String], edges: [(String, String)],
                        radius: CGFloat = 8) -> GraphLayoutEngine {
        var radii: [String: CGFloat] = [:]
        for id in ids { radii[id] = radius }
        return GraphLayoutEngine(ids: ids, edges: edges.map { (from: $0.0, to: $0.1) }, radii: radii)
    }

    func testSeedPlacesEveryNode() {
        let eng = engine(ids: ["a", "b", "c", "d"], edges: [])
        let seeded = eng.seed(size: size)
        XCTAssertEqual(Set(seeded.keys), ["a", "b", "c", "d"])
    }

    /// At rest, no two node circles overlap (the "üst üste binmeden" requirement).
    func testCollisionLeavesNoOverlapAtRest() {
        let ids = (0..<24).map { "n\($0)" }
        // A hub connected to everything — the crowded case where leaves would otherwise pile up.
        let edges = ids.dropFirst().map { ("n0", $0) }
        let eng = engine(ids: ids, edges: Array(edges), radius: 10)
        let pos = eng.layout(size: size)
        let minAllowed = 10.0 + 10.0 + 6.0   // r + r + collisionPad
        for a in 0..<ids.count {
            for b in (a + 1)..<ids.count {
                let pa = pos[ids[a]]!, pb = pos[ids[b]]!
                let d = hypot(pa.x - pb.x, pa.y - pb.y)
                XCTAssertGreaterThan(Double(d), minAllowed - 1.5,
                                     "\(ids[a]) and \(ids[b]) overlap (d=\(d))")
            }
        }
    }

    /// Dragging a node pulls its connected neighbour along (the "akışkan hareket" requirement).
    func testPinnedNodePullsNeighbourCloser() {
        let eng = engine(ids: ["a", "b"], edges: [("a", "b")])
        var pos = eng.layout(size: size)
        var vel: [String: CGVector] = [:]
        let pin = CGPoint(x: 120, y: 120)
        let before = hypot(pos["b"]!.x - pin.x, pos["b"]!.y - pin.y)
        for _ in 0..<200 {
            eng.relax(&pos, vel: &vel, size: size, pinned: "a", pinTo: pin, maxStep: 30)
        }
        XCTAssertEqual(pos["a"]!.x, pin.x, accuracy: 0.5)
        XCTAssertEqual(pos["a"]!.y, pin.y, accuracy: 0.5)
        let after = hypot(pos["b"]!.x - pin.x, pos["b"]!.y - pin.y)
        XCTAssertLessThan(after, before, "neighbour should flow toward the dragged node")
    }

    /// The simulation settles: movement decays toward zero.
    func testSimulationSettles() {
        let ids = (0..<30).map { "n\($0)" }
        let edges = (1..<30).map { ("n\($0 - 1)", "n\($0)") }
        let eng = engine(ids: ids, edges: edges)
        var pos = eng.seed(size: size)
        var vel: [String: CGVector] = [:]
        var alpha = 1.0
        var last = Double.greatestFiniteMagnitude
        for _ in 0..<600 {
            last = eng.relax(&pos, vel: &vel, size: size, alpha: alpha, maxStep: 30)
            alpha = max(0, alpha * 0.985)
        }
        XCTAssertLessThan(last, 0.5, "as alpha decays the graph must stop moving")
    }

    // MARK: - Stability while dragging
    //
    // Both force laws are unbounded (the link spring grows with distance squared, repulsion
    // diverges as nodes converge). Dragging a node a few hundred points away used to produce
    // forces in the thousands: every connected node moved at the per-frame cap, overshot,
    // and was pulled back, so the whole graph shook instead of the neighbours following.

    func testDraggingANodeFarAwayDoesNotShakeTheGraph() {
        let ids = (0..<14).map { "n\($0)" }
        let eng = engine(ids: ids, edges: ids.dropFirst().map { ("n0", $0) })
        var pos = eng.layout(size: size)
        var vel: [String: CGVector] = [:]

        // Yank the hub far outside the view and hold it there, as a drag does. Movement is
        // measured from the positions themselves: `relax` reports speed before collision
        // cancels it, so its return value overstates how much actually moved on screen.
        let target = CGPoint(x: 2200, y: 1800)
        var movements: [Double] = []
        for _ in 0..<220 {
            let before = pos
            _ = eng.relax(&pos, vel: &vel, size: size,
                          pinned: "n0", pinTo: target, alpha: 0.12, maxStep: 14)
            let shifted = ids.reduce(0.0) { total, id in
                guard let a = before[id], let b = pos[id] else { return total }
                return total + Double(hypot(b.x - a.x, b.y - a.y))
            }
            movements.append(shifted / Double(ids.count))
        }

        for point in pos.values {
            XCTAssertTrue(point.x.isFinite && point.y.isFinite, "the simulation diverged")
        }
        // Settling means later steps move less than early ones; an oscillating graph keeps
        // moving at the cap forever.
        let early = movements.prefix(20).reduce(0, +) / 20
        let late = movements.suffix(20).reduce(0, +) / 20
        XCTAssertLessThan(late, early, "movement must decay while a node is held")
        // A star whose leaves all want the same orbit is a genuinely tight packing, so a
        // little residual jostle is physics. What must not happen is the runaway this
        // guards: before the forces were clamped, every neighbour moved at the per-frame
        // cap indefinitely.
        XCTAssertLessThan(late, 3.0, "neighbours must not keep moving at the step cap")
    }

    /// The everyday case: a node dragged a normal distance inside the view must leave the
    /// rest of the graph essentially still.
    func testDraggingWithinTheViewLeavesTheGraphSteady() {
        let ids = (0..<20).map { "n\($0)" }
        let edges = (1..<20).map { ("n\($0 % 4)", "n\($0)") }
        let eng = engine(ids: ids, edges: edges)
        var pos = eng.layout(size: size)
        var vel: [String: CGVector] = [:]

        let target = CGPoint(x: 520, y: 360)
        var movements: [Double] = []
        for _ in 0..<220 {
            let before = pos
            _ = eng.relax(&pos, vel: &vel, size: size,
                          pinned: "n7", pinTo: target, alpha: 0.12, maxStep: 14)
            let shifted = ids.reduce(0.0) { total, id in
                guard let a = before[id], let b = pos[id] else { return total }
                return total + Double(hypot(b.x - a.x, b.y - a.y))
            }
            movements.append(shifted / Double(ids.count))
        }
        let late = movements.suffix(20).reduce(0, +) / 20
        XCTAssertLessThan(late, 0.5, "a normal drag must not keep the graph in motion")
    }

    /// The held node stays exactly under the cursor; responsiveness must not depend on a
    /// hot simulation.
    func testAPinnedNodeSitsExactlyOnItsTarget() {
        let ids = ["a", "b", "c"]
        let eng = engine(ids: ids, edges: [("a", "b"), ("b", "c")])
        var pos = eng.layout(size: size)
        var vel: [String: CGVector] = [:]
        let target = CGPoint(x: 640, y: 120)
        for _ in 0..<30 {
            _ = eng.relax(&pos, vel: &vel, size: size, pinned: "b", pinTo: target,
                          alpha: 0.12, maxStep: 14)
        }
        XCTAssertEqual(pos["b"]!.x, target.x, accuracy: 0.001)
        XCTAssertEqual(pos["b"]!.y, target.y, accuracy: 0.001)
    }
}
