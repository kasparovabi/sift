import Foundation

/// Pure builders for wiring the brain MCP server + digest into a `claude` launch.
public enum BrainLaunchConfig {
    public static func mcpConfigJSON(binaryPath: String, dbPath: String) -> String {
        let obj: [String: Any] = [
            "mcpServers": [
                "claudeos-brain": [
                    "command": binaryPath,
                    "args": [String](),
                    "env": ["CLAUDEOS_BRAIN_DB": dbPath],
                ],
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    public static func extraArgs(mcpConfigPath: String, digest: String) -> [String] {
        var args = ["--mcp-config", mcpConfigPath]
        if !digest.isEmpty {
            args += ["--append-system-prompt", digest]
        }
        return args
    }

    /// Write the MCP config to a temp file and return its path.
    public static func writeMCPConfig(binaryPath: String, dbPath: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("claudeos-brain-mcp-\(UUID().uuidString).json")
        try mcpConfigJSON(binaryPath: binaryPath, dbPath: dbPath).write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }
}

/// Hook injected into `SessionRuntime` to append MCP-config + digest args at launch.
public struct BrainLaunchHook: Sendable {
    public var binaryPath: String
    public var dbPath: String
    public var digestForProject: @Sendable (_ proj: String) -> String

    public init(binaryPath: String, dbPath: String,
                digestForProject: @escaping @Sendable (String) -> String) {
        self.binaryPath = binaryPath
        self.dbPath = dbPath
        self.digestForProject = digestForProject
    }

    public func extraArgs(proj: String?) -> [String] {
        guard let configPath = try? BrainLaunchConfig.writeMCPConfig(binaryPath: binaryPath, dbPath: dbPath) else { return [] }
        let digest = proj.map(digestForProject) ?? ""
        return BrainLaunchConfig.extraArgs(mcpConfigPath: configPath, digest: digest)
    }
}
