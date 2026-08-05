import XCTest
@testable import SiftCore

final class PathCodecTests: XCTestCase {

    func testDecodeSimplePath() {
        XCTAssertEqual(PathCodec.decode("-Users-alex-Downloads"), "/Users/alex/Downloads")
    }

    func testDecodeRoot() {
        XCTAssertEqual(PathCodec.decode("-"), "/")
    }

    func testDecodeEmptyIsRoot() {
        XCTAssertEqual(PathCodec.decode(""), "/")
    }

    func testEncodeRoundTripForDashFreePaths() {
        let path = "/Users/alex/Developer/claude"
        XCTAssertEqual(PathCodec.decode(PathCodec.encode(path)), path)
    }

    func testDisplayName() {
        XCTAssertEqual(PathCodec.displayName(forDecodedPath: "/Users/alex/Downloads"), "Downloads")
        XCTAssertEqual(PathCodec.displayName(forDecodedPath: "/"), "/")
    }
}
