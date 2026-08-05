import XCTest
@testable import SiftBrain
@testable import SiftCore
@testable import SiftIndex

/// Sift's own extraction runs must stay out of the session list, and nothing else may be
/// caught by that filter. The old rule matched the literal `F|D|P|H|V` anywhere in a first
/// message, which is a JSON schema fragment, not a reliable signature.
@MainActor
final class ExtractionFilterTests: XCTestCase {

    func testTheSQLFilterAndTheRealPromptAreOneString() {
        XCTAssertEqual(IndexStore.extractionMarker, Extractor.instructionMarker,
                       "SiftIndex holds a copy because it does not depend on SiftBrain")
        XCTAssertTrue(Extractor.instruction.hasPrefix(IndexStore.extractionMarker),
                      "the predicate is LIKE 'marker%', so the prompt must start with the marker")
    }

    func testExtractionRunsAreHidden() {
        XCTAssertFalse(IndexCoordinator.isUserStarted(session(firstMessage: Extractor.instruction)))
    }

    func testARealSessionMentioningTheSchemaIsNotHidden() {
        let innocent = "help me write a regex that matches F|D|P|H|V in this log"
        XCTAssertTrue(IndexCoordinator.isUserStarted(session(firstMessage: innocent)),
                      "the old contains() rule hid legitimate work")
    }

    func testHeadlessObserverToolsAreStillHidden() {
        XCTAssertFalse(IndexCoordinator.isUserStarted(session(firstMessage: "You are a Claude-Mem observer")))
        XCTAssertFalse(IndexCoordinator.isUserStarted(session(entrypoint: "sdk-py")))
        XCTAssertFalse(IndexCoordinator.isUserStarted(session(cwd: "/Users/a/.claude-mem/x")))
    }

    func testOrdinaryWorkSurvives() {
        XCTAssertTrue(IndexCoordinator.isUserStarted(session(firstMessage: "fix the login bug")))
        XCTAssertTrue(IndexCoordinator.isUserStarted(session(entrypoint: nil)),
                      "an unknown launcher is never hidden")
    }

    private func session(cwd: String = "/w", firstMessage: String = "hello",
                         entrypoint: String? = "cli") -> SessionSummary {
        SessionSummary(sessionId: "s", projectId: "p", filePath: "/f", cwd: cwd,
                       firstMessage: firstMessage, entrypoint: entrypoint)
    }
}
