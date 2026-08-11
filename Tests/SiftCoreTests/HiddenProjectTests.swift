import XCTest
@testable import SiftCore

final class HiddenProjectTests: XCTestCase {
    func testAFolderCoversItselfAndEverythingUnderIt() {
        XCTAssertTrue(HiddenProjects.covers("/Users/alex/harness", "/Users/alex/harness"))
        XCTAssertTrue(HiddenProjects.covers("/Users/alex/harness", "/Users/alex/harness/run1"))
        XCTAssertTrue(HiddenProjects.covers("/Users/alex/harness", "/Users/alex/harness/"))
        XCTAssertTrue(HiddenProjects.covers(#"A:\harness"#, #"A:\harness\sandbox\run1"#))

        // Matched on whole components, so hiding one folder leaves its neighbour alone.
        XCTAssertFalse(HiddenProjects.covers("/Users/alex/harness", "/Users/alex/harness-notes"))
        XCTAssertFalse(HiddenProjects.covers("/Users/alex/harness/run", "/Users/alex/harness"))
        XCTAssertFalse(HiddenProjects.covers("/Users/alex/harness", "/Users/alex/other"))
    }

    func testTheListIgnoresBlanksAndComments() {
        let parsed = HiddenProjects.parse("""
            # Folders Sift will not list.
            /Users/alex/harness

              /Users/alex/scratch/
            """)
        XCTAssertEqual(parsed, ["/Users/alex/harness", "/Users/alex/scratch"])
    }

    func testNothingHiddenAddsNothingToTheQuery() {
        XCTAssertNil(HiddenProjects.predicate([]))
    }

    func testTheWildcardComesAfterASeparator() {
        // Without that, hiding `harness` also hides `harness-notes`, a different folder.
        let sql = try! XCTUnwrap(HiddenProjects.predicate(["/Users/alex/harness"]))
        XCTAssertTrue(sql.hasPrefix("NOT ("))
        XCTAssertTrue(sql.contains("= '/Users/alex/harness'"))
        XCTAssertTrue(sql.contains("'/Users/alex/harness/%'"))
        XCTAssertFalse(sql.contains("'/Users/alex/harness%'"))
    }

    func testAQuoteInAPathCannotBreakTheQuery() {
        let sql = try! XCTUnwrap(HiddenProjects.predicate(["/Users/alex/it's"]))
        XCTAssertTrue(sql.contains("it''s"))
    }
}
