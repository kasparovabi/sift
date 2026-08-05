import XCTest
@testable import SiftBrain

final class BrainCodecRobustnessTests: XCTestCase {
    // (a) An atom whose claim contains a newline round-trips to the identical string.
    func testNewlineInClaimRoundTrips() throws {
        let s = "line1\nline2"
        let atom = Atom(id: "z01", t: .fact, s: s, proj: nil, src: "src", imp: 5,
                        createdAt: 0, validAt: nil, invalidAt: nil, retrievals: 0, lastRetrievedAt: nil)
        let text = BrainCodec.encode(atoms: [atom], relations: [], proj: nil)
        let decoded = try BrainCodec.decode(text)
        XCTAssertEqual(decoded.atoms.count, 1, "Must decode exactly 1 atom")
        XCTAssertEqual(decoded.atoms[0].s, s, "Claim with newline must round-trip")
    }

    // (b) A relation whose s contains ">" encodes+decodes without desync.
    func testGTInRelationSanitized() throws {
        let text = BrainCodec.encode(atoms: [], relations: [("a>b", "uses", "c")], proj: nil)
        let decoded = try BrainCodec.decode(text)
        XCTAssertEqual(decoded.relations.count, 1, "Must decode exactly 1 relation")
        // The ">" was sanitized so decode correctly splits into 3 parts.
    }
}
