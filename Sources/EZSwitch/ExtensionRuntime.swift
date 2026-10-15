import SwiftUI

struct ExtensionPaneEntry: Identifiable {
    let id: String
    let makeView: @MainActor (ConfigStore, @escaping () -> Void) -> AnyView
}

/// Settings observes one generic signal; connector-specific state stays in its pane.
@MainActor
final class ExtensionRuntime: ObservableObject {
    static let shared = ExtensionRuntime()
    @Published private(set) var revision = 0

    func start(in store: ConfigStore) {
        BuiltinExtensions.start(in: store, runtime: self)
    }

    func connectionChanged() { revision += 1 }
}
