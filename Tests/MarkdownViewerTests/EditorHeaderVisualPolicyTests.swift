import Foundation
import Testing
@testable import MarkdownViewer

@Suite("Editor header visual policy")
struct EditorHeaderVisualPolicyTests {
    @Test("tab strip retains prototype interaction geometry")
    func tabStripGeometry() {
        #expect(EditorHeaderVisualPolicy.tabHeight == 28)
        #expect(EditorHeaderVisualPolicy.tabCornerRadius == 6)
        #expect(EditorHeaderVisualPolicy.tabCloseSlot == 16)
        #expect(EditorHeaderVisualPolicy.dirtyIndicatorDiameter == 7)
        #expect(EditorHeaderVisualPolicy.confirmCloseHeight == 18)
    }

    @Test("rest hover selected and pressed fills are distinct")
    func interactionFills() {
        #expect(EditorHeaderVisualPolicy.actionHoverOpacity == 0.05)
        #expect(EditorHeaderVisualPolicy.activeTabOpacity == 0.06)
        #expect(EditorHeaderVisualPolicy.pressedOpacity == 0.08)
    }
}
