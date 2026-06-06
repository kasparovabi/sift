import XCTest
@testable import ClaudeOSRuntime

final class BrainIngestQueueTests: XCTestCase {

    // touch at 0 and 0.5 (same path) — tick at 1.4 is within window, tick at 1.6 fires once
    func testDebounceCoalescesRepeatedTouches() {
        var fired: [String] = []
        let q = BrainIngestQueue(debounce: 1.0) { fired.append($0) }

        q.touch("/a/b.jsonl", now: 0.0)
        q.touch("/a/b.jsonl", now: 0.5)  // resets the clock; effective start = 0.5

        q.tick(now: 1.4)  // 1.4 - 0.5 = 0.9 < 1.0 — nothing
        XCTAssertEqual(fired, [])

        q.tick(now: 1.6)  // 1.6 - 0.5 = 1.1 >= 1.0 — fires once
        XCTAssertEqual(fired, ["/a/b.jsonl"])

        q.tick(now: 2.0)  // already removed — still once
        XCTAssertEqual(fired.count, 1)
    }

    // two different paths both fire after the debounce window
    func testTwoDifferentPathsBothFire() {
        var fired: [String] = []
        let q = BrainIngestQueue(debounce: 1.0) { fired.append($0) }

        q.touch("/p/a.jsonl", now: 0.0)
        q.touch("/p/b.jsonl", now: 0.0)

        q.tick(now: 0.5)  // neither ready
        XCTAssertEqual(fired, [])

        q.tick(now: 1.0)  // exactly 1.0 — >= threshold for both
        XCTAssertEqual(Set(fired), Set(["/p/a.jsonl", "/p/b.jsonl"]))
        XCTAssertEqual(fired.count, 2)
    }
}
