import XCTest
@testable import ClaudeOSRuntime

final class BrainIngestQueueTests: XCTestCase {
    func testDebounceCoalesces() {
        var ingested: [String] = []
        let q = BrainIngestQueue(debounce: 1.0, ingest: { path in ingested.append(path) })
        q.touch("a.jsonl", now: 0)
        q.touch("a.jsonl", now: 0.5)   // resets window
        q.tick(now: 1.4)               // not yet (last touch 0.5 + 1.0 = 1.5)
        XCTAssertEqual(ingested, [])
        q.tick(now: 1.6)               // fires once
        XCTAssertEqual(ingested, ["a.jsonl"])
    }

    func testSeparatePathsBothFire() {
        var ingested: [String] = []
        let q = BrainIngestQueue(debounce: 1.0, ingest: { ingested.append($0) })
        q.touch("a.jsonl", now: 0)
        q.touch("b.jsonl", now: 0)
        q.tick(now: 1.1)
        XCTAssertEqual(Set(ingested), ["a.jsonl", "b.jsonl"])
    }
}
