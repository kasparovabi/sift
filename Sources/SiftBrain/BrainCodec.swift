import Foundation

public enum BrainCodec {
    public static let legend =
        "#brain1 atoms:id|t|s|imp · rel:s>p>o · t:F=fact D=decision P=pref E=entity H=howto V=event"

    public static func encode(atoms: [Atom],
                              relations: [(String, String, String)],
                              proj: String?) -> String {
        var lines = [legend]
        if let proj { lines.append("@\(proj)") }
        lines.append("atoms[\(atoms.count)]{id,t,s,imp}:")
        for a in atoms {
            lines.append("\(a.id),\(a.t.rawValue),\(field(a.s)),\(a.imp)")
        }
        if !relations.isEmpty {
            lines.append("rel:")
            for (s, p, o) in relations {
                // Sanitize: replace any ">" in entity/predicate names with a space
                // so the s>p>o split is unambiguous.
                let ss = s.replacingOccurrences(of: ">", with: " ")
                let pp = p.replacingOccurrences(of: ">", with: " ")
                let oo = o.replacingOccurrences(of: ">", with: " ")
                lines.append("\(ss)>\(pp)>\(oo)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Quote a field if it contains a comma or quote; escape newlines as literal \n so
    /// a claim never spans physical lines. Decode unescapes them on the way back.
    static func field(_ value: String) -> String {
        // Escape newlines first so the resulting string is single-line.
        let escaped = value
            .replacingOccurrences(of: "\r\n", with: #"\n"#)
            .replacingOccurrences(of: "\r", with: #"\n"#)
            .replacingOccurrences(of: "\n", with: #"\n"#)
        if escaped.contains(",") || escaped.contains("\"") {
            return "\"" + escaped.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return escaped
    }

    // MARK: - Decode

    public struct Decoded {
        public var proj: String?
        public var atoms: [DecodedAtom]
        public var relations: [(String, String, String)]
    }

    public struct DecodedAtom: Equatable {
        public var id: String
        public var t: AtomType
        public var s: String
        public var imp: Int
    }

    public static func decode(_ text: String) throws -> Decoded {
        var proj: String?
        var atoms: [DecodedAtom] = []
        var relations: [(String, String, String)] = []
        var section = ""   // "atoms" or "rel"
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("#brain") { continue }
            if line.hasPrefix("@") { proj = String(line.dropFirst()); continue }
            if line.hasPrefix("atoms[") { section = "atoms"; continue }
            if line == "rel:" { section = "rel"; continue }
            if line.isEmpty { continue }
            switch section {
            case "atoms":
                let parts = splitFields(line)
                guard parts.count >= 4, let t = AtomType(rawValue: parts[1]), let imp = Int(parts[3]) else { continue }
                // Unescape literal \n sequences back to real newlines in the claim field.
                let claim = parts[2].replacingOccurrences(of: #"\n"#, with: "\n")
                atoms.append(DecodedAtom(id: parts[0], t: t, s: claim, imp: imp))
            case "rel":
                let r = line.components(separatedBy: ">")
                if r.count == 3 { relations.append((r[0], r[1], r[2])) }
            default:
                continue
            }
        }
        return Decoded(proj: proj, atoms: atoms, relations: relations)
    }

    /// Split a BrainText row into fields, honoring a quoted 3rd field (the claim).
    static func splitFields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if inQuotes && i + 1 < chars.count && chars[i + 1] == "\"" {
                    current.append("\""); i += 2; continue
                }
                inQuotes.toggle(); i += 1; continue
            }
            if c == "," && !inQuotes {
                fields.append(current); current = ""; i += 1; continue
            }
            current.append(c); i += 1
        }
        fields.append(current)
        return fields
    }
}
