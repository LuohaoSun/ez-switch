# Native API audit

Scope: replace supplier and route card reordering, then review the app for custom interaction code that Apple frameworks can simplify. Other opportunities below are recommendations, not changes made in this patch.

## Card reordering implemented

`Sources/EZSwitch/NativeReorderableCards.swift` uses `ForEach.reorderable()`, `dragContainer`, `reorderContainer`, and header-only `draggable(containerItemID:)` on macOS 27+. The ForEach element, drag payload, and reorder container use the same identifiable wrapper type. Only its ID is exported; supplier connection details are not included in the drag data. The system owns placement previews and drag animations. The move callback persists through the existing ConfigStore operations.

macOS 13–26 uses native `List` / `ForEach.onMove`. The minimum deployment target remains macOS 13. No handwritten card DropDelegate, temporary display order, custom hover sorting, or drag-provider deinit cleanup remains.

## Recommended opportunities

| Priority | Current implementation | Native alternative | Availability and practical benefit |
| --- | --- | --- | --- |
| High | `SettingsView.swift:118` and `SettingsSidebarRow`: HStack/VStack sidebar, manual width/opacity hiding, selection painting and selected accessibility trait | `NavigationSplitView`, sidebar `List(selection:)`, column visibility binding | NavigationSplitView is macOS 13+. Gives standard sidebar visibility, selection, keyboard navigation, resizing and system appearance. Preserve the workspace's minimum usable column widths. |
| High | `RouteWorkspaceView.swift:171`, `:207`, `:343`, `:375`: NSItemProvider string UUID export, async NSString loading, UUID parsing and main-queue hop for model dragging | A small model-ID `Transferable` with `.draggable` / `.dropDestination` | macOS 13+. Typed drag data and framework decoding replace manual transport plumbing. Model membership validation, cross-panel assignment and candidate insertion rules remain app logic. Use a separate payload type from card dragging; never transfer API keys or full RemoteModel records. |
| Medium | `RouteWorkspaceView.swift:127` and `:250`: chevrons, tap gestures, button traits and accessibility action for expansion | `DisclosureGroup(isExpanded:)`, optionally a custom `DisclosureGroupStyle` | DisclosureGroup is macOS 11+; custom style is macOS 13+. Consolidates expansion semantics and accessibility while retaining card appearance. Keep menu/toggle actions outside the disclosure trigger, and verify title dragging does not toggle expansion. |
| Medium | `RouteWorkspaceView.swift:427` and `RemotesView.swift:630`: manually drawn circle/checkmark buttons and Set mutation for model selection | Native checkbox `Toggle` per row, or `List(selection: Binding<Set<String>>)` | Available within the existing deployment target. Checkbox toggles preserve the current single-click multiple-selection behavior; List(selection:) adds Command/Shift range selection and keyboard navigation but changes interaction expectations. |
| Low | `RouterApp.swift:22`: singleton AppWindowManager creates NSWindow/NSHostingController, sets dimensions and reuses the window | SwiftUI `Window(id:)` plus `openWindow`, default size and resizing modifiers | macOS 13+. Can reduce window-creation code; the log window already uses a Window scene. AppKit itself is native, so this is simplification, not replacement of a non-native implementation. Retain or explicitly verify accessory/regular activation, login-item launch and Dock reopen behavior. |
| Low | `Log.swift:39`: manually scales bytes and writes KB/MB suffixes | `ByteCountFormatter` or `ByteCountFormatStyle` | Foundation APIs support localized units and large sizes. Exact precision and binary-unit display differ; decide on the desired log format before changing it. |
| Optional | `RouteWorkspaceView.swift:44`: fixed supplier/content HStack with Divider | `HSplitView` | macOS 10.15+. Adds system divider resizing if user-adjustable panel widths are desired. This is an optional feature, not an existing broken reimplementation. |

## Keep or distinguish from native API replacements

- `GeneralPane.swift` already uses SMAppService for login items and NSWorkspace for Finder reveal; `UIComponents.swift` uses NSPasteboard for copying.
- `Config.swift` already uses FileManager and a DispatchSource filesystem watcher. `UpdateChecker.swift` already uses URLSession, CryptoKit SHA256 and NSWorkspace to download, verify and open updates.
- `RouterApp.swift` already uses MenuBarExtra, a native log Window scene, standard About panel and NSAlert. `SettingsView.swift` activation coordination uses AppKit notifications and activation policy. The menu-bar application's policy changes still need explicit behavior, even if window creation is migrated to SwiftUI scenes.
- `LogWindowView.swift:14` uses native Timer. Event-driven updates through Combine/NotificationCenter could avoid one-second polling, but that is an update-design improvement rather than replacement of a handwritten timer API. Route current-model TimelineView polling has the same distinction.
- `Forwarder.swift:30` bridges native URLSessionDataDelegate to chunked NIO buffers. URLSession.bytes(for:) offers an async byte sequence, but is not a drop-in replacement for the current chunk-oriented forwarding, cancellation and explicit redirect policy. Preserve it unless equivalent latency and transport behavior are measured.
- NIO routing, fallback policy, harness configuration edits, Responses/Chat translation and GitHub release selection/checksum policy are app-specific behavior. Apple has no native API implementing those features. Sparkle would be a third-party updater, not an Apple-native replacement.

## Verification and limits

- Final code compiled and all 107 Swift tests in 18 suites passed. Release configuration built successfully, the preview's ad-hoc signature verified, and route dragging also succeeded in the Release preview. Restarting the preview retained saved supplier and route ordering.
- GUI verification used `/tmp/EZSwitch-NativePreview.app`, a separate configuration and port 18993. The production router at port 8788 was not stopped or replaced.
- On macOS 27.2, supplier and route cards reordered successfully. Supplier moves in both directions and collapsed-card moves were observed; route expanded and collapsed moves were observed. The saved config and reorder log confirmed commits.
- Comparing route records by ID before and after card moves confirmed candidate arrays, selected model and autoFallback remained unchanged. Supplier model records also remained unchanged.
- A supplier model could still be dragged into a route with the native card container present.
- Search input required a real edit/commit in the automation tool; setting the AX textfield value alone changed the visible text without updating its SwiftUI binding. After edit/commit, filtering worked. A drag attempted while filtering did not create a provider reorder log or change persisted order.
- System drag placement and final layouts were observed. The automation captures settled/intermediate frames, not a continuous animation recording; exact animation timing and smoothness were not independently measured.
- The macOS 13–26 List branch was compiled but not runtime tested on an older OS. Cancellation/end-of-list behavior was not exhaustively tested. These limitations must not be described as full cross-version GUI acceptance.
