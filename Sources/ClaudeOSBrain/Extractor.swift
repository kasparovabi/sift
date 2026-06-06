import Foundation

public protocol CommandRunning {
    func run(_ executable: String, _ args: [String], stdin: String?, env: [String: String]) throws -> String
}

/// Runs a subprocess and returns its stdout as a UTF-8 string.
public struct ProcessRunner: CommandRunning {
    public init() {}
    public func run(_ executable: String, _ args: [String], stdin: String?, env: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if !env.isEmpty { process.environment = env }
        let outPipe = Pipe()
        process.standardOutput = outPipe
        if let stdin {
            let inPipe = Pipe()
            process.standardInput = inPipe
            try process.run()
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            inPipe.fileHandleForWriting.closeFile()
        } else {
            try process.run()
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

public struct ExtractionResult {
    public var atoms: [ExtractedAtom]
    public var relations: [(s: String, p: String, o: String)]
}

public struct Extractor {
    public let runner: CommandRunning
    public let claudePath: String
    public let env: [String: String]

    public init(runner: CommandRunning, claudePath: String, env: [String: String]) {
        self.runner = runner; self.claudePath = claudePath; self.env = env
    }

    public static let instruction = """
        Aşağıdaki Claude Code oturum transkriptinden KALICI DEĞERLİ bilgi çıkar. \
        Sadece geçerli JSON döndür, başka metin yok. Şema: \
        {"atoms":[{"t":"F|D|P|H|V","s":"tek satır iddia","imp":1-10,"entities":["ad"]}], \
        "relations":[{"s":"özne","p":"yüklem","o":"nesne"}]}. \
        Geçici sohbeti, ham hata çıktısını, önemsiz şeyleri atla. Transkript:
        """

    public func extract(transcript: String, proj: String?) throws -> ExtractionResult {
        let prompt = Self.instruction + "\n" + transcript
        let raw = try runner.run(claudePath, ["-p", prompt, "--output-format", "json"], stdin: nil, env: env)
        let json = Self.unwrap(raw)
        return try Self.parse(json)
    }

    /// Extract inner content from a `claude --output-format json` envelope, else return as-is.
    public static func unwrap(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = obj["result"] as? String else {
            return raw
        }
        return result
    }

    struct RawResult: Codable {
        struct RawAtom: Codable { let t: String; let s: String; let imp: Int; let entities: [String] }
        struct RawRel: Codable { let s: String; let p: String; let o: String }
        let atoms: [RawAtom]
        let relations: [RawRel]
    }

    /// Strip markdown code fences / surrounding prose and return the outermost JSON object.
    public static func cleanJSON(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let firstNewline = s.firstIndex(of: "\n") { s = String(s[s.index(after: firstNewline)...]) }
            if let fenceEnd = s.range(of: "```", options: .backwards) { s = String(s[..<fenceEnd.lowerBound]) }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end {
            return String(s[start...end])
        }
        return s
    }

    public static func parse(_ json: String) throws -> ExtractionResult {
        let data = Data(cleanJSON(json).utf8)
        let raw = try JSONDecoder().decode(RawResult.self, from: data)
        let atoms = raw.atoms.map {
            ExtractedAtom(t: AtomType(rawValue: $0.t) ?? .fact, s: $0.s, imp: $0.imp, entities: $0.entities)
        }
        let rels = raw.relations.map { (s: $0.s, p: $0.p, o: $0.o) }
        return ExtractionResult(atoms: atoms, relations: rels)
    }
}
