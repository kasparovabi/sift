import Foundation
import GRDB

public enum AtomType: String, Codable, Sendable, CaseIterable {
    case fact = "F", decision = "D", pref = "P", entity = "E", howto = "H", event = "V"
}

public struct Atom: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "atom"
    public var id: String
    public var t: AtomType
    public var s: String
    public var proj: String?
    public var src: String
    public var imp: Int
    public var createdAt: Double
    public var validAt: Double?
    public var invalidAt: Double?
    public var retrievals: Int
    public var lastRetrievedAt: Double?
}

public struct Entity: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "entity"
    public var id: String
    public var n: String
    public var k: String
}

public struct Relation: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "relation"
    public var id: String
    public var subjectId: String
    public var predicate: String
    public var objectId: String
    public var validAt: Double?
    public var invalidAt: Double?
    public var src: String
}
