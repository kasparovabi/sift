import XCTest
import Foundation
@testable import ClaudeOSBrain

final class MCPToolCallTests: XCTestCase {
    func testRememberThenSearchViaMCP() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("brain-\(UUID().uuidString).sqlite")
        let table: [String: [Float]] = ["use GRDB": [1, 0], "database lib": [0.9, 0.1]]
        let svc = try BrainService(path: url.path, embed: { table[$0] ?? [0, 0] })
        let d = MCPDispatcher(service: svc)

        let remember: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "brain_remember",
                       "arguments": ["text": "use GRDB", "type": "D", "importance": 8, "proj": "p"]]]
        _ = d.handle(message: remember)

        let search: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "brain_search", "arguments": ["query": "database lib", "proj": "p", "k": 5]]]
        let resp = d.handle(message: search)
        let content = ((resp?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first
        let text = content?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("GRDB"))
    }
}
