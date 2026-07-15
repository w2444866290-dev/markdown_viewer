import AppKit
import Testing
@testable import MarkdownViewer

struct FindFocusBridgeTests {
    @Test
    func escapeClosesFindWithoutInputFocus() {
        #expect(FindKeyboardPolicy.action(
            forKeyCode: 53,
            modifiers: [],
            queryFieldFocused: false
        ) == .close)
        #expect(FindKeyboardPolicy.action(
            forKeyCode: 53,
            modifiers: [],
            queryFieldFocused: true
        ) == .close)
    }

    @Test
    func shiftReturnOnlyNavigatesBackwardFromQueryField() {
        #expect(FindKeyboardPolicy.action(
            forKeyCode: 36,
            modifiers: [.shift],
            queryFieldFocused: true
        ) == .navigatePrevious)
        #expect(FindKeyboardPolicy.action(
            forKeyCode: 36,
            modifiers: [.shift],
            queryFieldFocused: false
        ) == .passThrough)
    }

    @Test
    func queryFieldLookupIgnoresOtherTextFields() throws {
        let root = NSView()
        let sidebar = NSTextField()
        sidebar.placeholderString = "筛选文档"
        let container = NSView()
        let find = NSTextField()
        find.placeholderString = "查找"
        root.addSubview(sidebar)
        root.addSubview(container)
        container.addSubview(find)

        #expect(FindFocusBridge.findQueryField(in: root) === find)
    }
}
