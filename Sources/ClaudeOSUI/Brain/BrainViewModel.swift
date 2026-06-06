import Foundation
import Observation
import ClaudeOSBrain

@MainActor
@Observable
public final class BrainViewModel {
    public let service: BrainService
    public var atoms: [Atom] = []
    public var entities: [Entity] = []
    public var query: String = ""
    public var selectedAtomId: String?

    public init(service: BrainService) { self.service = service }

    public func reload() {
        atoms = (try? service.store.recentAtoms(limit: 200)) ?? []
        entities = (try? service.store.allEntities(limit: 200)) ?? []
    }

    public func runSearch() {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { reload(); return }
        // Use FTS directly for the UI list (deterministic, no embed dependency).
        atoms = (try? service.store.searchFTS(query, limit: 200)) ?? []
    }

    public func delete(id: String) {
        try? service.store.deleteAtom(id: id)
        reload()
    }

    public func setImportance(id: String, imp: Int) {
        try? service.store.setImportance(id: id, imp: imp)
        reload()
    }

    public func invalidate(id: String) {
        try? service.store.invalidate(id: id)
        reload()
    }

    @discardableResult
    public func forget() -> Int {
        let n = (try? service.forget()) ?? 0
        reload()
        return n
    }

    public func selectedAtom() -> Atom? { atoms.first { $0.id == selectedAtomId } }
}
