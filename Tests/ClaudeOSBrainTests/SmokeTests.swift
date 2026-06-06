import XCTest
@testable import ClaudeOSBrain

final class SmokeTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(ClaudeOSBrain.version, "1")
    }
}
