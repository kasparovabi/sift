import XCTest
import Foundation
import ClaudeOSBrain
@testable import ClaudeOSUI

@MainActor
final class BrainViewModelTests: XCTestCase {
    func makeVM() throws -> BrainViewModel {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("brain-\(UUID().uuidString).sqlite")
        let svc = try BrainService(path: url.path, embed: { _ in [1, 0] })
        return BrainViewModel(service: svc)
    }
    func testReloadShowsRecent() async throws {
        let vm = try makeVM()
        _ = try vm.service.store.insertAtom(t: .fact, s: "hello", proj: "p", src: "x", imp: 5)
        await vm.reload()
        XCTAssertEqual(vm.atoms.count, 1)
        XCTAssertEqual(vm.atoms.first?.s, "hello")
    }
    func testDeleteRemoves() async throws {
        let vm = try makeVM()
        let id = try vm.service.store.insertAtom(t: .fact, s: "x", proj: "p", src: "x", imp: 5)
        await vm.reload()
        await vm.delete(id: id)
        XCTAssertTrue(vm.atoms.isEmpty)
    }
}
