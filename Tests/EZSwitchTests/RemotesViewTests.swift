import Foundation
import Testing
@testable import EZSwitch

@MainActor
@Suite("Provider selection")
struct RemotesViewTests {
    @Test
    func removingModelSelectsNextModelInSameProvider() {
        let first = remote("Alpha", "one")
        let before = remote("Beta", "one")
        let selected = remote("Beta", "two")
        let after = remote("Beta", "three")
        let groups = [RemoteGroup(provider: "Alpha", remotes: [first]),
                      RemoteGroup(provider: "Beta", remotes: [before, selected, after])]

        let ui = RemotesViewDraft()
        #expect(ui.selectionAfterRemoving(selected, from: groups) == .model(after.id))
    }

    @Test
    func removingLastModelSelectsPreviousModelInSameProvider() {
        let first = remote("Alpha", "one")
        let previous = remote("Beta", "one")
        let selected = remote("Beta", "two")
        let groups = [RemoteGroup(provider: "Alpha", remotes: [first]),
                      RemoteGroup(provider: "Beta", remotes: [previous, selected])]

        let ui = RemotesViewDraft()
        #expect(ui.selectionAfterRemoving(selected, from: groups) == .model(previous.id))
    }

    @Test
    func removingProvidersOnlyModelClearsSelection() {
        let selected = remote("Beta", "one")
        let groups = [RemoteGroup(provider: "Beta", remotes: [selected])]

        let ui = RemotesViewDraft()
        #expect(ui.selectionAfterRemoving(selected, from: groups) == nil)
    }

    private func remote(_ provider: String, _ model: String) -> RemoteModel {
        RemoteModel(id: UUID(), name: "\(provider) · \(model)", apiKey: "key", model: model,
                    extraHeaders: [:], apiEndpoints: .all(baseURL: "https://example.com"))
    }
}
