import XCTest
@testable import SiftBrain

final class BrainCodecTests: XCTestCase {
    func testEncodeBasic() {
        let atoms = [
            Atom(id: "a3f", t: .decision, s: "PTY via SwiftTerm", proj: "sift", src: "s#1", imp: 8,
                 createdAt: 0, validAt: nil, invalidAt: nil, retrievals: 0, lastRetrievedAt: nil),
            Atom(id: "a40", t: .fact, s: "FTS5 prefixes 2,3", proj: "sift", src: "s#2", imp: 6,
                 createdAt: 0, validAt: nil, invalidAt: nil, retrievals: 0, lastRetrievedAt: nil),
        ]
        let rels = [("sift", "uses", "SwiftTerm")]
        let text = BrainCodec.encode(atoms: atoms, relations: rels, proj: "sift")
        XCTAssertTrue(text.hasPrefix("#brain1 "))
        XCTAssertTrue(text.contains("@sift"))
        XCTAssertTrue(text.contains("atoms[2]{id,t,s,imp}:"))
        XCTAssertTrue(text.contains("a3f,D,PTY via SwiftTerm,8"))
        XCTAssertTrue(text.contains("\"FTS5 prefixes 2,3\"")) // comma -> quoted
        XCTAssertTrue(text.contains("sift>uses>SwiftTerm"))
    }
}
