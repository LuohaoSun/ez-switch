import SwiftUI

/// The only composition point that names optional connector implementations.
enum BuiltinExtensions {
    static var connectors: [ConnectorDefinition] {
        #if EZSWITCH_CURSOR_EXTENSION
        return [CursorExtension.connector()]
        #else
        return []
        #endif
    }

    @MainActor static var panes: [ExtensionPaneEntry] {
        #if EZSWITCH_CURSOR_EXTENSION
        return [CursorExtension.pane]
        #else
        return []
        #endif
    }

    @MainActor static func start(in store: ConfigStore, runtime: ExtensionRuntime) {
        #if EZSWITCH_CURSOR_EXTENSION
        CursorExtension.start(in: store, runtime: runtime)
        #endif
    }
}
