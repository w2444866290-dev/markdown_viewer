import SwiftUI

/// Single AppKit → SwiftUI observable bridge and command channel.
final class EditorBridge: ObservableObject {
    @Published var headings: [OutlineController.Heading] = []
    @Published var activeHeadingIndex: Int = 0
    @Published var scrollProgress: Double = 0
    /// URL under the mouse cursor (browser-convention bottom-left preview).
    /// Empty string = nothing hovered.
    @Published var hoveredURL: String = ""

    /// Set by EditorView.Coordinator — when called, scrolls to heading.
    var onJumpToHeading: ((Int) -> Void)?
}
