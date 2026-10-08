import SwiftUI

struct ModelSelectionToggle: View {
    let model: String
    @Binding var selection: Set<String>

    var body: some View {
        Toggle(isOn: Binding(
            get: { selection.contains(model) },
            set: { selected in
                if selected { selection.insert(model) }
                else { selection.remove(model) }
            }
        )) {
            Text(model).font(.system(.body, design: .monospaced))
        }
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
