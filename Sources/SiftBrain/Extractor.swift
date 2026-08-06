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
    /// Maps entity name → kind ("person"/"project"/"file"/"tool"/"lib"/"concept").
    /// Populated from object-form entity entries in the extracted JSON.
    /// Plain-string entity entries default to "concept".
    public var entityKinds: [String: String]

    public init(atoms: [ExtractedAtom], relations: [(s: String, p: String, o: String)],
                entityKinds: [String: String] = [:]) {
        self.atoms = atoms
        self.relations = relations
        self.entityKinds = entityKinds
    }
}

public struct Extractor {
    public let runner: CommandRunning
    public let claudePath: String
    public let env: [String: String]
    /// Root of `~/.claude/projects`. When set, the transcript a persisted extraction run
    /// creates is deleted afterward so it never reaches the resume picker. nil disables
    /// cleanup — used by unit tests whose stub runners write no files.
    public let projectsRoot: URL?

    public init(runner: CommandRunning, claudePath: String, env: [String: String],
                projectsRoot: URL? = nil) {
        self.runner = runner; self.claudePath = claudePath; self.env = env
        self.projectsRoot = projectsRoot
    }

    /// The marker `looksLikeExtraction` recognises. It has to be a literal substring of
    /// `instruction`: if the two ever drift apart, extraction runs stop being recognised as
    /// machine sessions and the ingester starts feeding its own output back into itself.
    public static let instructionMarker = "Extract DURABLE, REUSABLE knowledge"

    public static let instruction = """
        \(instructionMarker) from the Claude Code session transcript below. \
        Return valid JSON only, with no other text. Schema: \
        {"atoms":[{"t":"F|D|P|H|V","s":"one-line claim","imp":1-10,"entities":["name"]}], \
        "relations":[{"s":"subject","p":"predicate","o":"object"}]}. \
        Write every statement and entity name in English, whatever language the transcript \
        is in, keeping names, paths and identifiers exactly as they appear. \
        Skip small talk, raw error output, and anything trivial. Transcript:
        """

    /// True if a transcript is itself one of our extraction runs (its prompt is the
    /// instruction above). Such sessions must never be ingested — that would feed garbage
    /// atoms into the brain. Extraction now persists (the --no-session-persistence flag
    /// returned empty results), so this check is what breaks the auto-capture feedback loop.
    public static func looksLikeExtraction(_ text: String) -> Bool {
        text.contains(instructionMarker)
    }

    public func extract(transcript: String, proj: String?) throws -> ExtractionResult {
        let prompt = Self.instruction + "\n" + transcript
        // Deliberately NO --no-session-persistence. On current claude builds that flag makes
        // `-p ... --output-format json` return an EMPTY result (the agent loops internally and
        // never emits a final answer), so extraction silently produced zero atoms. The two
        // duties that flag used to serve are handled elsewhere now:
        //   • re-ingest feedback loop → BrainIngester.isNoiseTranscript drops any transcript
        //     whose prompt is our extraction instruction (Extractor.looksLikeExtraction).
        //   • resume-list pollution    → the persisted run is cleaned up below, and
        //     IndexStore.userSessionPredicate hides any that slip through.
        let raw = try runner.run(claudePath,
                                 ["-p", prompt, "--output-format", "json"],
                                 stdin: nil, env: env)
        Self.deletePersistedSession(envelope: raw, projectsRoot: projectsRoot)
        let json = Self.unwrap(raw)
        // An empty result means "nothing to extract", not a parse error — return an empty
        // result instead of throwing. The caller ingests via `try?`, so a throw here is
        // swallowed and indistinguishable from a successful empty extraction; that is exactly
        // how the --no-session-persistence bug stayed invisible.
        if json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ExtractionResult(atoms: [], relations: [])
        }
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

    /// The `session_id` from a `claude --output-format json` envelope, if present and non-empty.
    static func sessionId(fromEnvelope raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sid = obj["session_id"] as? String, !sid.isEmpty else { return nil }
        return sid
    }

    /// Best-effort removal of the transcript a persisted extraction run just created. The run
    /// has to persist (--no-session-persistence empties the result), so we delete its file by
    /// the session_id the envelope reports, keeping the real `claude --resume` picker free of
    /// machine-made extraction sessions. BrainIngester.isNoiseTranscript already stops them
    /// re-entering the brain, so this only keeps ~/.claude/projects tidy. No-op when
    /// projectsRoot is nil (tests) or the envelope carries no session_id.
    static func deletePersistedSession(envelope raw: String, projectsRoot: URL?) {
        guard let projectsRoot, let sid = sessionId(fromEnvelope: raw) else { return }
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: projectsRoot,
                                                     includingPropertiesForKeys: nil) else { return }
        for dir in dirs {
            let candidate = dir.appendingPathComponent("\(sid).jsonl")
            if fm.fileExists(atPath: candidate.path) {
                try? fm.removeItem(at: candidate)
                return
            }
        }
    }

    /// Accepts either a plain JSON string `"Name"` or an object `{"n":"Name","k":"lib"}`.
    struct EntityRef: Decodable {
        let name: String
        let kind: String

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            // Try plain string first.
            if let plain = try? container.decode(String.self) {
                name = plain
                kind = "concept"
                return
            }
            // Fall back to object form.
            struct Obj: Decodable { let n: String; let k: String? }
            let obj = try container.decode(Obj.self)
            name = obj.n
            kind = obj.k ?? "concept"
        }
    }

    struct RawResult: Decodable {
        struct RawAtom: Decodable {
            let t: String; let s: String; let imp: Int; let entities: [EntityRef]
        }
        struct RawRel: Decodable { let s: String; let p: String; let o: String }
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

        var entityKinds: [String: String] = [:]
        let atoms = raw.atoms.map { rawAtom -> ExtractedAtom in
            let refs = rawAtom.entities
            let names = refs.map(\.name)
            for ref in refs { entityKinds[ref.name] = ref.kind }
            return ExtractedAtom(t: AtomType(rawValue: rawAtom.t) ?? .fact,
                                 s: rawAtom.s, imp: rawAtom.imp, entities: names)
        }
        let rels = raw.relations.map { (s: $0.s, p: $0.p, o: $0.o) }
        return ExtractionResult(atoms: atoms, relations: rels, entityKinds: entityKinds)
    }
}
