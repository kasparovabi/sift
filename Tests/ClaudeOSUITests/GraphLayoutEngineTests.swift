import XCTest
import CoreGraphics
@testable import ClaudeOSUI

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
}
