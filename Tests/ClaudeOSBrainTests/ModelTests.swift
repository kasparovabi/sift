import XCTest
@testable import ClaudeOSBrain

final class ModelTests: XCTestCase {
    func testBase62() {
        XCTAssertEqual(Base62.encode(0), "0")
        XCTAssertEqual(Base62.encode(1), "1")
        XCTAssertEqual(Base62.encode(61), "Z")
        XCTAssertEqual(Base62.encode(62), "10")
    }
    func testAtomTypeRoundTrip() {
        for t in AtomType.allCases {
            XCTAssertEqual(AtomType(rawValue: t.rawValue), t)
        }
    }
    func testAtomDefaults() {
        let a = Atom(id: "a1", t: .decision, s: "x", proj: "p", src: "s#1", imp: 5,
                     createdAt: 0, validAt: nil, invalidAt: nil, retrievals: 0, lastRetrievedAt: nil)
        XCTAssertEqual(a.t, .decision)
        XCTAssertNil(a.invalidAt)
    }
}
