import AppKit
import Testing
@testable import MarkdownViewer

struct ScrollIndicatorPolicyTests {
    @Test("document scrolling keeps an interactive native overlay scroller")
    @MainActor
    func nativeOverlayScrollerRemainsAvailable() throws {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 180))
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 1_200))

        MarkdownDocumentScrollIndicatorPolicy.apply(to: scrollView)

        let scroller = try #require(scrollView.verticalScroller)
        #expect(scrollView.hasVerticalScroller)
        #expect(scrollView.autohidesScrollers)
        #expect(scrollView.scrollerStyle == .overlay)
        #expect(scroller.isEnabled)
        #expect(scroller.accessibilityRole() == .scrollBar)
    }
}
