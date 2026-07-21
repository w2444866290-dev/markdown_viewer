import Testing
@testable import MarkdownViewer

struct MarkdownTableEditorVisualTests {
    @Test("toolbar visual states retain hover pressed and disabled distinctions")
    func toolbarInteractionVisualStates() {
        #expect(MarkdownTableToolbarVisualPolicy.fillOpacity(
            isEnabled: true,
            isHovering: false,
            isPressed: false
        ) == 0)
        #expect(MarkdownTableToolbarVisualPolicy.fillOpacity(
            isEnabled: true,
            isHovering: true,
            isPressed: false
        ) == 0.14)
        #expect(MarkdownTableToolbarVisualPolicy.fillOpacity(
            isEnabled: true,
            isHovering: true,
            isPressed: true
        ) == 0.22)
        #expect(MarkdownTableToolbarVisualPolicy.fillOpacity(
            isEnabled: false,
            isHovering: true,
            isPressed: true
        ) == 0)
        #expect(MarkdownTableToolbarVisualPolicy.disabledContentOpacity == 0.42)
        #expect(MarkdownTableToolbarVisualPolicy.focusRingOpacity == 0.70)
    }
}
