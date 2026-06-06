import XCTest
@testable import ClaudeOSBrain

final class BrainCodecDecodeTests: XCTestCase {
    func testDecodeRoundTrip() throws {
        let atoms = [
            Atom(id: "a3f", t: .decision, s: "PTY via SwiftTerm", proj: "claudeos", src: "s#1", imp: 8,
                 createdAt: 0, validAt: nil, invalidAt: nil, retrievals: 0, lastRetrievedAt: nil),
            Atom(id: "a40", t: .fact, s: "FTS5 prefixes 2,3", proj: "claudeos", src: "s#2", imp: 6,
                 createdAt: 0, validAt: nil, invalidAt: nil, retrievals: 0, lastRetrievedAt: nil),
        ]
        let rels = [("claudeos", "uses", "SwiftTerm")]
        let text = BrainCodec.encode(atoms: atoms, relations: rels, proj: "claudeos")

        let decoded = try BrainCodec.decode(text)
        XCTAssertEqual(decoded.proj, "claudeos")
        XCTAssertEqual(decoded.atoms.count, 2)
        XCTAssertEqual(decoded.atoms[0].id, "a3f")
        XCTAssertEqual(decoded.atoms[0].t, .decision)
        XCTAssertEqual(decoded.atoms[1].s, "FTS5 prefixes 2,3") // unquoted back
        XCTAssertEqual(decoded.relations.count, 1)
        XCTAssertEqual(decoded.relations[0].1, "uses")
    }
}
