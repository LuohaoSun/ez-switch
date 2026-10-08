import Foundation
import CoreTransferable
import Testing
@testable import EZSwitch

@Suite("Typed model transfer")
struct ModelTransferTests {
    @Test func cardIdentityIsDistinctFromModelIdentity() throws {
        let id = UUID()
        let cardID = CardReorderID(value: id)
        #expect(AnyHashable(cardID) != AnyHashable(id))
        let data = try JSONEncoder().encode(cardID)
        #expect(try JSONDecoder().decode(CardReorderID<UUID>.self, from: data) == cardID)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ModelDragItem.self, from: data)
        }
    }

    @Test func roundTripExportsOnlyModelID() async throws {
        let id = UUID()
        let provider = NSItemProvider()
        provider.register(ModelDragItem(id: id))
        let item: ModelDragItem = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: ModelDragItem.self) { result in
                continuation.resume(with: result)
            }
        }
        #expect(item.id == id)
        let data = try JSONEncoder().encode(item)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object == ["id": id.uuidString])
    }
}
