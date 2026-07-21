import AppKit
import Testing
@testable import MarkdownViewer

struct SidebarResizePolicyTests {
    @Test
    func widthIsClampedAtBothPointerAndAccessibilityBounds() {
        #expect(
            SidebarResizePolicy.clampedWidth(DesignTokens.sidebarMinWidth - 80)
                == DesignTokens.sidebarMinWidth
        )
        #expect(
            SidebarResizePolicy.clampedWidth(DesignTokens.sidebarMaxWidth + 80)
                == DesignTokens.sidebarMaxWidth
        )
        #expect(SidebarResizePolicy.clampedWidth(248) == 248)
    }

    @Test
    func accessibilityStepIsAStableNativeControlIncrement() {
        #expect(SidebarResizePolicy.accessibilityStep == 8)
    }

    @Test
    func filterFocusRingRequiresKeyboardTraversal() {
        #expect(!SidebarFilterFocusPolicy.showsRing(
            isFocused: false,
            hasPendingKeyboardTraversal: true
        ))
        #expect(!SidebarFilterFocusPolicy.showsRing(
            isFocused: true,
            hasPendingKeyboardTraversal: false
        ))
        #expect(!SidebarFilterFocusPolicy.isKeyboardTraversal(keyCode: 0))
        #expect(SidebarFilterFocusPolicy.isKeyboardTraversal(keyCode: 48))
        #expect(SidebarFilterFocusPolicy.showsRing(
            isFocused: true,
            hasPendingKeyboardTraversal: true
        ))
    }
}
