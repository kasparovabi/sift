import Foundation

/// Minimal MCP (Model Context Protocol) JSON-RPC 2.0 dispatcher over [String: Any] messages.
/// Handles initialize / notifications/initialized / tools/list / tools/call.
public final class MCPDispatcher: @unchecked Sendable {
    private let service: BrainService
    public init(service: BrainService) { self.service = service }

    /// Returns a JSON-RPC response object, or nil for notifications (no id).
    public func handle(message: [String: Any]) -> [String: Any]? {
        let method = message["method"] as? String ?? ""
        let id = message["id"]

        switch method {
        case "initialize":
            let version = (message["params"] as? [String: Any])?["protocolVersion"] as? String ?? "2024-11-05"
            return ok(id, [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "claudeos-brain", "version": "1"],
            ])
        case "notifications/initialized", "notifications/cancelled":
            return nil
        case "tools/list":
            return ok(id, ["tools": Self.toolSchemas])
        case "tools/call":
            return handleToolCall(id: id, params: message["params"] as? [String: Any] ?? [:])
        default:
            guard id != nil else { return nil }
            return err(id, -32601, "Method not found: \(method)")
        }
    }

    private func handleToolCall(id: Any?, params: [String: Any]) -> [String: Any]? {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        do {
            let text: String
            switch name {
            case "brain_search":
                text = try service.search(query: args["query"] as? String ?? "",
                                          proj: args["proj"] as? String,
                                          k: args["k"] as? Int ?? 8)
            case "brain_recall":
                text = try service.recall(entity: args["entity"] as? String ?? "")
            case "brain_remember":
                let t = AtomType(rawValue: (args["type"] as? String ?? "F")) ?? .fact
                text = try service.remember(text: args["text"] as? String ?? "",
                                            type: t,
                                            importance: args["importance"] as? Int ?? 5,
                                            proj: args["proj"] as? String)
            case "brain_stats":
                text = try service.stats()
            default:
                return err(id, -32602, "Unknown tool: \(name)")
            }
            return ok(id, ["content": [["type": "text", "text": text]], "isError": false])
        } catch {
            return ok(id, ["content": [["type": "text", "text": "error: \(error)"]], "isError": true])
        }
    }

    private func ok(_ id: Any?, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }
    private func err(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    nonisolated(unsafe) static let toolSchemas: [[String: Any]] = [
        ["name": "brain_search",
         "description": "Search the Claude OS brain (semantic + keyword) and return compact BrainText atoms.",
         "inputSchema": ["type": "object",
                         "properties": ["query": ["type": "string"],
                                        "proj": ["type": "string"],
                                        "k": ["type": "integer"]],
                         "required": ["query"]]],
        ["name": "brain_recall",
         "description": "Recall everything the brain knows about a named entity.",
         "inputSchema": ["type": "object",
                         "properties": ["entity": ["type": "string"]],
                         "required": ["entity"]]],
        ["name": "brain_remember",
         "description": "Store a durable fact in the brain now.",
         "inputSchema": ["type": "object",
                         "properties": ["text": ["type": "string"],
                                        "type": ["type": "string", "enum": ["F", "D", "P", "E", "H", "V"]],
                                        "importance": ["type": "integer"],
                                        "proj": ["type": "string"]],
                         "required": ["text"]]],
        ["name": "brain_stats",
         "description": "Return brain statistics (atom counts).",
         "inputSchema": ["type": "object", "properties": [String: Any]()]],
    ]
}
