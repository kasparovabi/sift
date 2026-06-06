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
                lines.append("\(s)>\(p)>\(o)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Quote a field if it contains a comma, quote, or newline; double inner quotes.
    static func field(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
