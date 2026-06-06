import XCTest
import Foundation
@testable import ClaudeOSBrain

final class EntityKindTests: XCTestCase {

    // MARK: - Extractor.parse tests

    func testObjectFormEntityYieldsNameAndKind() throws {
        let json = """
        {"atoms":[{"t":"D","s":"use SwiftTerm","imp":8,"entities":[{"n":"SwiftTerm","k":"lib"}]}],"relations":[]}
        """
        let result = try Extractor.parse(json)
        XCTAssertEqual(result.atoms.count, 1)
        XCTAssertEqual(result.atoms[0].entities, ["SwiftTerm"])
        XCTAssertEqual(result.entityKinds["SwiftTerm"], "lib")
    }

    func testStringFormEntityStillParsesAndDefaultsKind() throws {
        let json = """
        {"atoms":[{"t":"F","s":"use GRDB","imp":5,"entities":["GRDB"]}],"relations":[]}
        """
        let result = try Extractor.parse(json)
        XCTAssertEqual(result.atoms.count, 1)
        XCTAssertEqual(result.atoms[0].entities, ["GRDB"])
        // Kind defaults to "concept" for plain strings.
        XCTAssertEqual(result.entityKinds["GRDB"], "concept")
    }

    func testMixedEntitiesObjectAndString() throws {
        let json = """
        {"atoms":[{"t":"F","s":"two entities","imp":6,"entities":[{"n":"Alice","k":"person"},"GRDB"]}],"relations":[]}
        """
        let result = try Extractor.parse(json)
        XCTAssertEqual(result.atoms[0].entities, ["Alice", "GRDB"])
        XCTAssertEqual(result.entityKinds["Alice"], "person")
        XCTAssertEqual(result.entityKinds["GRDB"], "concept")
    }

    func testMultipleAtomsKindsAccumulate() throws {
        let json = """
        {"atoms":[
            {"t":"F","s":"a","imp":3,"entities":[{"n":"MyLib","k":"lib"}]},
            {"t":"D","s":"b","imp":7,"entities":[{"n":"BobPerson","k":"person"}]}
        ],"relations":[]}
        """
        let result = try Extractor.parse(json)
        XCTAssertEqual(result.entityKinds["MyLib"], "lib")
        XCTAssertEqual(result.entityKinds["BobPerson"], "person")
    }

    // MARK: - Consolidator.ingest(result:) test

    func testConsolidatorUsesEntityKindFromResult() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("brain-ek-\(UUID().uuidString).sqlite")
        let store = try BrainStore(path: url.path)
        let c = Consolidator(store: store, embed: { _ in [1, 0] })

        let json = """
        {"atoms":[{"t":"D","s":"use SwiftTerm","imp":8,"entities":[{"n":"SwiftTerm","k":"lib"}]}],"relations":[]}
        """
        let result = try Extractor.parse(json)
        // Sanity-check the parse side.
        XCTAssertEqual(result.entityKinds["SwiftTerm"], "lib")

        try c.ingest(result: result, proj: "p", src: "s#1")

        // The entity stored in the DB should have kind "lib", not "concept".
        let entities = try store.allEntities(limit: 100)
        let swiftTerm = entities.first(where: { $0.n == "SwiftTerm" })
        XCTAssertNotNil(swiftTerm, "SwiftTerm entity should exist")
        XCTAssertEqual(swiftTerm?.k, "lib")
    }
}
