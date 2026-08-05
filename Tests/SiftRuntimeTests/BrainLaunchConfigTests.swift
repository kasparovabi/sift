import XCTest
import Foundation
@testable import SiftRuntime

final class BrainLaunchConfigTests: XCTestCase {
    func testMCPConfigJSON() throws {
        let json = BrainLaunchConfig.mcpConfigJSON(binaryPath: "/Applications/Sift.app/Contents/MacOS/sift-brain-mcp",
                                                   dbPath: "/tmp/brain.sqlite")
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let servers = obj["mcpServers"] as! [String: Any]
        let brain = servers["sift-brain"] as! [String: Any]
        XCTAssertEqual(brain["command"] as? String, "/Applications/Sift.app/Contents/MacOS/sift-brain-mcp")
        XCTAssertEqual((brain["env"] as? [String: Any])?["SIFT_BRAIN_DB"] as? String, "/tmp/brain.sqlite")
    }

    func testArgvIncludesMCPAndSystemPrompt() {
        let argv = BrainLaunchConfig.extraArgs(mcpConfigPath: "/tmp/cfg.json", digest: "#brain1 ...")
        XCTAssertTrue(argv.contains("--mcp-config"))
        XCTAssertTrue(argv.contains("/tmp/cfg.json"))
        XCTAssertTrue(argv.contains("--append-system-prompt"))
        XCTAssertTrue(argv.contains("#brain1 ..."))
    }

    func testEmptyDigestOmitsSystemPrompt() {
        let argv = BrainLaunchConfig.extraArgs(mcpConfigPath: "/tmp/cfg.json", digest: "")
        XCTAssertFalse(argv.contains("--append-system-prompt"))
        XCTAssertTrue(argv.contains("--mcp-config"))
    }
}
