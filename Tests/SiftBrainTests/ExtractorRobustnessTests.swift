import XCTest
@testable import SiftBrain

final class ExtractorRobustnessTests: XCTestCase {
    func testCleanJSONStripsMarkdownFence() throws {
        let fenced = "```json\n{\"atoms\":[{\"t\":\"F\",\"s\":\"x\",\"imp\":3,\"entities\":[]}],\"relations\":[]}\n```"
        let r = try Extractor.parse(fenced)
        XCTAssertEqual(r.atoms.count, 1)
        XCTAssertEqual(r.atoms[0].s, "x")
    }

    func testCleanJSONStripsSurroundingProse() throws {
        let prose = "Here is the JSON:\n{\"atoms\":[],\"relations\":[{\"s\":\"a\",\"p\":\"uses\",\"o\":\"b\"}]}\nDone."
        let r = try Extractor.parse(prose)
        XCTAssertEqual(r.relations.count, 1)
        XCTAssertEqual(r.relations[0].p, "uses")
    }

    func testCleanJSONPlainPassesThrough() {
        XCTAssertEqual(Extractor.cleanJSON("{\"a\":1}"), "{\"a\":1}")
    }
}
