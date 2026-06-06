import Foundation
import Observation
import ClaudeOSBrain

@MainActor
@Observable
public final class BrainViewModel {
    public let service: BrainService
    public var atoms: [Atom] = []
    public var entities: [Entity] = []
    /// Relations as entity-id pairs, for the neural-network graph view.
    public var relations: [(from: String, predicate: String, to: String)] = []
    public var query: String = ""
    public var selectedAtomId: String?

    public init(service: BrainService) { self.service = service }

    public func reload() async {
        atoms = (try? await service.store.recentAtoms(limit: 200)) ?? []
        entities = (try? await service.store.allEntities(limit: 300)) ?? []
        relations = (try? await service.store.allRelations(limit: 800)) ?? []
        clampSelection()
    }

    public func runSearch() async {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { await reload(); return }
        // Use FTS directly for the UI list (deterministic, no embed dependency).
        atoms = (try? await service.store.searchFTS(query, limit: 200)) ?? []
        clampSelection()
    }

    public func delete(id: String) async {
        try? await service.store.deleteAtom(id: id)
        await reload()
    }

    public func setImportance(id: String, imp: Int) async {
        try? await service.store.setImportance(id: id, imp: imp)
        await reload()
    }

    public func invalidate(id: String) async {
        try? await service.store.invalidate(id: id)
        await reload()
    }

    @discardableResult
    public func forget() async -> Int {
        let n = (try? await service.forget()) ?? 0
        await reload()
        return n
    }

    public func selectedAtom() -> Atom? { atoms.first { $0.id == selectedAtomId } }

    /// Drop the list selection if it no longer points at a visible atom
    /// (after delete/forget/reload/search the selected row may be gone).
    private func clampSelection() {
        if let id = selectedAtomId, !atoms.contains(where: { $0.id == id }) {
            selectedAtomId = nil
        }
    }
}
