import SwiftUI

/// Single AppKit → SwiftUI observable bridge and command channel.
final class EditorBridge: ObservableObject {
    @Published var headings: [OutlineController.Heading] = []

    /// Set by EditorView.Coordinator — when called, scrolls to heading.
    var onJumpToHeading: ((Int) -> Void)?

    /// True while the mouse is over the outline rail. Plain (non-@Published) so
    /// setting it never re-renders ContentView; PaperTextView reads it in
    /// `cursorUpdate` to show a pointing-hand over the rail instead of the I-beam.
    var cursorOverRail = false
}

/// Isolated, single-value observable for the status-bar scroll percentage.
///
/// Scroll progress changes on every frame while scrolling. If it lived on
/// `EditorBridge`, every `@Published` change would re-evaluate the whole
/// `ContentView` body (editor, outline rail, overlays) because SwiftUI
/// invalidation is object-level. Keeping it on its own tiny object — held by
/// `ContentView` via `@State` (which does NOT subscribe to `objectWillChange`)
/// and observed only by the isolated `EditorStatusBar` — means scrolling
/// re-renders just that one small view.
final class ScrollProgressModel: ObservableObject {
    @Published var value: Double = 0
}

/// Isolated, single-value observable for the active outline heading.
///
/// The active heading changes on every scroll frame (as new headings cross the
/// top of the viewport). For the exact reason `ScrollProgressModel` is isolated:
/// if it lived on `EditorBridge`, each `@Published` change would re-evaluate the
/// whole `ContentView` body (editor, sidebar, rail, overlays) because SwiftUI
/// invalidation is object-level. Keeping it on its own tiny object — held by
/// `ContentView` via `@State` (which does NOT subscribe to `objectWillChange`)
/// and observed only by the isolated `OutlineRailView` — means scrolling
/// re-renders just the rail.
final class ActiveHeadingModel: ObservableObject {
    @Published var index: Int = 0
}

/// Isolated, single-value observable for the link URL under the mouse cursor.
///
/// The hovered URL changes on every mouse move over a link. For the exact reason
/// `ActiveHeadingModel` is isolated: if it lived on `EditorBridge`, each
/// `@Published` change would re-evaluate the whole `ContentView` body because
/// SwiftUI invalidation is object-level. Keeping it on its own tiny object — held
/// by `ContentView` via `@State` (which does NOT subscribe to `objectWillChange`)
/// and observed only by the isolated bottom-left hover-preview leaf — means a
/// mouse move over a link re-renders just that preview.
/// Empty string = nothing hovered.
final class HoverURLModel: ObservableObject {
    @Published var url: String = ""
}

/// Isolated observable for the document's character / line counts.
///
/// The counts change on every edit (recomputed only on text change, not per
/// scroll frame, so the status bar never does O(n) work while scrolling). They
/// are shown ONLY by the bottom-right `EditorStatusBar`. If they lived on
/// `EditorBridge` (which `ContentView` observes via `@StateObject`), each
/// `@Published` change would re-evaluate the whole `ContentView` body because
/// SwiftUI invalidation is object-level. Keeping them on their own tiny object —
/// held by `ContentView` via `@State` (which does NOT subscribe to
/// `objectWillChange`) and observed only by the isolated `EditorStatusBar` —
/// means an edit re-renders just that one small view (性能-3).
final class DocMetricsModel: ObservableObject {
    @Published var charCount: Int = 0
    @Published var lineCount: Int = 0
}

// DIAG (temporary) -----------------------------------------------------------
/// TEMPORARY diagnostic sink for the "whole-document styling flashes for one
/// frame while typing/deleting" bug. Records WHICH re-style code path each
/// keystroke took and drives an always-visible on-screen readout.
///
/// Isolated exactly like `ScrollProgressModel`/`ActiveHeadingModel`/`HoverURLModel`:
/// held by `ContentView` via `@State` (NOT observed there), so writing it on every
/// keystroke does NOT re-evaluate the whole `ContentView` body. This matters here -
/// the instrumentation itself must not trigger the very whole-view re-render we are
/// hunting. Only the isolated `DiagReadout` leaf observes it. Rip out together with
/// the rest of the `// DIAG (temporary)` markers once the bug is found.
final class DiagModel: ObservableObject {
    @Published var text: String = ""
    /// Second HUD line: the last find-search summary (see FindController
    /// `lastDebugDiagnostic`). Written by the editor Coordinator after each search.
    @Published var findText: String = ""
    /// The full per-match dump copied when the HUD is clicked (not displayed - the
    /// HUD only shows the summary line). Plain var: no view observes it for layout.
    var findDetail: String = ""
}
