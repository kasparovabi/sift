import Foundation
import ClaudeOSBrain

// DB path: env override or default app-support location.
let dbPath: String = {
    if let p = ProcessInfo.processInfo.environment["CLAUDEOS_BRAIN_DB"], !p.isEmpty { return p }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClaudeOS", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base.appendingPathComponent("brain.sqlite").path
}()

let service: BrainService
do {
    service = try BrainService(path: dbPath)
} catch {
    FileHandle.standardError.write(Data("brain open failed: \(error)\n".utf8))
    exit(1)
}
let dispatcher = MCPDispatcher(service: service)
let out = FileHandle.standardOutput

func writeLine(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    out.write(data)
    out.write(Data("\n".utf8))
}

// Newline-delimited JSON-RPC over stdin.
while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
          let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
    if let response = dispatcher.handle(message: msg) {
        writeLine(response)
    }
}
