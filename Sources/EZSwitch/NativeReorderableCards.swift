import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

struct CardReorderID<Value: Hashable & Codable & Sendable>: Hashable, Codable, Sendable {
    let value: Value
}

private struct CardDragItem<Item: Identifiable>: Identifiable, Transferable where Item.ID: Hashable & Codable & Sendable {
    let item: Item
    var id: CardReorderID<Item.ID> { CardReorderID(value: item.id) }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .data) { card in
            try JSONEncoder().encode(card.id)
        }
    }
}

struct NativeCardDragHandle<ID: Hashable & Codable & Sendable>: ViewModifier {
    let id: ID
    var enabled = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 27, *), enabled {
            content.draggable(containerItemID: CardReorderID(value: id))
        } else {
            content
        }
    }
}

struct NativeReorderableCards<Item: Identifiable, Row: View>: View where Item.ID: Hashable & Codable & Sendable {
    let items: [Item]
    let spacing: CGFloat
    var enabled = true
    let move: ([Item.ID], Item.ID?) -> Void
    @ViewBuilder let row: (Item) -> Row

    @ViewBuilder
    var body: some View {
        if #available(macOS 27, *) {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: spacing) {
                    ForEach(items.map { CardDragItem(item: $0) }) { card in
                        row(card.item).frame(minWidth: 0, maxWidth: .infinity)
                    }
                    .reorderable()
                }
                .frame(minWidth: 0, maxWidth: .infinity)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.never)
            .dragContainer(for: CardDragItem<Item>.self) { ids in
                let sourceIDs = Set(ids.map(\.value))
                return items.filter { sourceIDs.contains($0.id) }.map { CardDragItem(item: $0) }
            }
            .reorderContainer(for: CardDragItem<Item>.self, isEnabled: enabled) { difference in
                switch difference.destination.position {
                case .before(let target): move(difference.sources.map(\.value), target.value)
                case .end: move(difference.sources.map(\.value), nil)
                }
            }
        } else {
            List {
                ForEach(items) { item in
                    row(item)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: spacing / 2, leading: 0, bottom: spacing / 2, trailing: 0))
                        .moveDisabled(!enabled)
                }
                .onMove { offsets, destination in
                    move(offsets.map { items[$0].id }, destination < items.count ? items[destination].id : nil)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
        }
    }
}
