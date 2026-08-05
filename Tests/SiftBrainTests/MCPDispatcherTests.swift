import XCTest
import Foundation
@testable import SiftBrain

final class MCPDispatcherTests: XCTestCase {
    func makeDispatcher() throws -> MCPDispatcher {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("brain-\(UUID().uuidString).sqlite")
        let svc = try BrainService(path: url.path, embed: { _ in [1, 0] })
        return MCPDispatcher(service: svc)
    }

    func handle(_ d: MCPDispatcher, _ json: String) -> [String: Any]? {
        let data = json.data(using: .utf8)!
        let msg = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        return d.handle(message: msg)
    }

    func testInitializeReturnsServerInfo() throws {
        let d = try makeDispatcher()
        let resp = handle(d, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#)
        let result = resp?["result"] as? [String: Any]
        XCTAssertEqual((result?["serverInfo"] as? [String: Any])?["name"] as? String, "sift-brain")
        XCTAssertNotNil(result?["capabilities"])
    }

    func testNotificationReturnsNil() throws {
        let d = try makeDispatcher()
        XCTAssertNil(handle(d, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
    }

    func testToolsListHasFourTools() throws {
        let d = try makeDispatcher()
        let resp = handle(d, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = (resp?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 4)
        XCTAssertTrue(tools?.contains { ($0["name"] as? String) == "brain_search" } ?? false)
    }

    func testUnknownMethodReturnsError() throws {
        let d = try makeDispatcher()
        let resp = handle(d, #"{"jsonrpc":"2.0","id":9,"method":"no/such"}"#)
        XCTAssertNotNil(resp?["error"])
    }
}
