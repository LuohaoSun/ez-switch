import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

struct ModelDragItem: Identifiable, Codable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .plainText)
            .visibility(.ownProcess)
    }
}

struct NativeModelDrag: ViewModifier {
    let item: ModelDragItem

    func body(content: Content) -> some View {
        content.onDrag {
            let provider = NSItemProvider()
            provider.register(item)
            return provider
        }
    }
}

struct NativeModelDrop: ViewModifier {
    var enabled = true
    let accept: ([ModelDragItem]) -> Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.dropDestination(for: ModelDragItem.self, isEnabled: enabled) { items, _ in
                _ = accept(items)
            }
        } else {
            content.dropDestination(for: ModelDragItem.self) { items, _ in
                enabled && accept(items)
            }
        }
    }
}
