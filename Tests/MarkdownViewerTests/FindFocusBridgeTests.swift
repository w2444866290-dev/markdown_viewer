import AppKit
import Testing
@testable import MarkdownViewer

struct FindFocusBridgeTests {
    @Test
    func reopeningFindKeepsPanelOpenAndRequestsFocusAgain() {
        let state = FindState()

        state.openFind()
        #expect(state.isOpen)
        #expect(state.focusRequest == 1)

        state.openFind()
        #expect(state.isOpen)
        #expect(state.focusRequest == 2)
    }

    @Test
    func closingFindClearsTransientPanelStateButKeepsSearchOptions() {
        let state = FindState()
        var searchRequests: [String] = []
        state.onSearch = { searchRequests.append($0) }
        state.isOpen = true
        state.query = "needle"
        state.replaceText = "thread"
        state.showReplace = true
        state.matchCount = 2
        state.currentIndex = 1
        state.isError = true
        state.caseSensitive = true
        state.wholeWord = true
        state.useRegex = true

        state.closeFind()

        #expect(searchRequests == [""])
        #expect(!state.isOpen)
        #expect(state.query.isEmpty)
        #expect(state.replaceText.isEmpty)
        #expect(!state.showReplace)
        #expect(state.matchCount == 0)
        #expect(state.currentIndex == 0)
        #expect(!state.isError)
        #expect(state.caseSensitive)
        #expect(state.wholeWord)
        #expect(state.useRegex)
    }

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
