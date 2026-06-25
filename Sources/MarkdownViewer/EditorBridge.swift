import SwiftUI

/// Single AppKit → SwiftUI observable bridge and command channel.
final class EditorBridge: ObservableObject {
    @Published var headings: [OutlineController.Heading] = []
    @Published var activeHeadingIndex: Int = 0
    /// Cached document metrics — recomputed only on text change (not per scroll
    /// frame) so the status bar never does O(n) work while scrolling.
    @Published var charCount: Int = 0
    @Published var lineCount: Int = 0
    /// URL under the mouse cursor (browser-convention bottom-left preview).
    /// Empty string = nothing hovered.
    @Published var hoveredURL: String = ""

    /// Set by EditorView.Coordinator — when called, scrolls to heading.
    var onJumpToHeading: ((Int) -> Void)?
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
