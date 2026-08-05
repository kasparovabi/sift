import XCTest
@testable import SiftBrain

final class SmokeTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(SiftBrain.version, "1")
    }
}
