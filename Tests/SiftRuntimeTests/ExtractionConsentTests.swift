import XCTest
@testable import SiftRuntime

/// Knowledge extraction is the only thing Sift does that leaves the machine, and it spends
/// the user's tokens to do it. These pin the consent and the pacing.
final class ExtractionConsentTests: XCTestCase {
    private let key = "sift.knowledgeExtractionEnabled"
    private var original: Any?

    override func setUp() {
        original = UserDefaults.standard.object(forKey: key)
    }

    override func tearDown() {
        if let original {
            UserDefaults.standard.set(original, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func testAFreshInstallDoesNotSendTranscriptsAnywhere() {
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(Preferences.knowledgeExtractionEnabled)
    }

    func testTheSwitchSticks() {
        Preferences.knowledgeExtractionEnabled = true
        XCTAssertTrue(Preferences.knowledgeExtractionEnabled)
        Preferences.knowledgeExtractionEnabled = false
        XCTAssertFalse(Preferences.knowledgeExtractionEnabled)
    }

    func testABacklogDrainsGraduallyAndCompletely() {
        var ingested: [String] = []
        let queue = BrainIngestQueue(debounce: 60, maxPerTick: 2) { ingested.append($0) }
        for i in 0..<7 { queue.touch("/t/\(i).jsonl", now: 0) }

        queue.tick(now: 100)
        XCTAssertEqual(ingested.count, 2, "a week away must not become 7 claude runs in one tick")
        XCTAssertEqual(queue.pendingCount, 5)

        for _ in 0..<3 { queue.tick(now: 100) }
        XCTAssertEqual(ingested.count, 7, "pacing delays the work, it does not drop it")
        XCTAssertEqual(Set(ingested).count, 7, "no transcript is extracted twice")
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testDebounceStillHoldsBackFreshWrites() {
        var ingested: [String] = []
        let queue = BrainIngestQueue(debounce: 60, maxPerTick: 10) { ingested.append($0) }
        queue.touch("/t/live.jsonl", now: 0)
        queue.tick(now: 30)
        XCTAssertTrue(ingested.isEmpty, "a session still being typed in is not finished")
        queue.tick(now: 61)
        XCTAssertEqual(ingested, ["/t/live.jsonl"])
    }

    func testTurningExtractionOffDiscardsTheBacklog() {
        var ingested: [String] = []
        let queue = BrainIngestQueue(debounce: 0, maxPerTick: 10) { ingested.append($0) }
        queue.touch("/t/a.jsonl", now: 0)
        queue.drop()
        queue.tick(now: 100)
        XCTAssertTrue(ingested.isEmpty, "re-enabling later must not flush what accumulated meanwhile")
    }
}
