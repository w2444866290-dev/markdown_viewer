import AppKit
import SwiftUI
import Testing
@testable import MarkdownViewer

@MainActor
@Suite(.serialized)
struct PlainSourceFindCoordinatorTests {
    @Test("plain-source save reads marked text without ending native editing")
    func savePreservesMarkedPlainSourceEditor() throws {
        let root = try temporaryRoot(named: "save-marked")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("source.txt")
        let harness = try makeNativeSaveHarness(source: "before", url: url)
        defer { harness.teardown() }
        appendMarkedText("输入", to: harness.textView)

        #expect(harness.manager.saveActiveDocument())

        #expect(harness.textView.hasMarkedText())
        #expect(harness.textView.string == "before输入")
        #expect(harness.manager.activeTab?.text == "before输入")
        #expect(harness.manager.activeTab?.isDirty == false)
        #expect(try Data(contentsOf: url) == Data("before输入".utf8))
    }

    @Test("plain-source conflict preserves marked text, draft, and dirty state")
    func conflictPreservesMarkedPlainSourceEditor() throws {
        let root = try temporaryRoot(named: "conflict-marked")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("source.txt")
        let harness = try makeNativeSaveHarness(source: "before", url: url)
        defer { harness.teardown() }
        appendMarkedText("输入", to: harness.textView)
        try Data("external".utf8).write(to: url)

        #expect(!harness.manager.saveActiveDocument())

        #expect(harness.manager.lastSaveFailure == .conflict(.modified))
        #expect(harness.textView.hasMarkedText())
        #expect(harness.textView.string == "before输入")
        #expect(harness.manager.activeTab?.text == "before输入")
        #expect(harness.manager.activeTab?.isDirty == true)
        #expect(try Data(contentsOf: url) == Data("external".utf8))
    }

    @Test("plain-source mount recomputes an existing query")
    func mountRecomputesExistingQuery() {
        let state = FindState()
        state.query = "heading"
        state.matchCount = 99
        let harness = makeHarness(
            source: "# heading\n**heading**",
            findState: state
        )

        harness.coordinator.searchCurrentFindQueryIfNeeded()

        #expect(state.matchCount == 2)
        #expect(state.currentIndex == 0)
        #expect(!state.isError)
    }

    @Test("plain-source replacements preserve flat source styling")
    func replacementsPreservePlainStyling() {
        let state = FindState()
        state.query = "heading"
        state.replaceText = "title"
        let harness = makeHarness(
            source: "# heading\n**heading**",
            findState: state
        )
        harness.coordinator.searchCurrentFindQueryIfNeeded()

        state.onReplaceCurrent?()

        #expect(harness.textView.string == "# title\n**heading**")
        #expect(state.matchCount == 1)
        expectFlatPlainAttributes(harness.textView)

        state.replaceText = "body"
        state.onReplaceAll?()

        #expect(harness.textView.string == "# title\n**body**")
        #expect(state.matchCount == 0)
        expectFlatPlainAttributes(harness.textView)
    }

    @Test("plain-source text mutations immediately refresh find results")
    func textMutationsRefreshFindResults() {
        let state = FindState()
        state.query = "needle"
        let harness = makeHarness(
            source: "needle and hay",
            findState: state
        )
        harness.coordinator.searchCurrentFindQueryIfNeeded()
        #expect(state.matchCount == 1)

        harness.textView.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: 6),
            with: "thread"
        )
        harness.textView.didChangeText()

        #expect(state.matchCount == 0)
        #expect(state.currentIndex == 0)
        #expect(state.displayText == "无结果")
    }

    @Test("replace-current refreshes a stale same-length match snapshot")
    func replaceCurrentRefreshesStaleSnapshot() {
        let state = FindState()
        state.query = "cat"
        state.replaceText = "fox"
        let harness = makeHarness(
            source: "cat dog",
            findState: state
        )
        harness.coordinator.searchCurrentFindQueryIfNeeded()

        harness.textView.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: 7),
            with: "dog cat"
        )
        state.onReplaceCurrent?()

        #expect(harness.textView.string == "dog fox")
        #expect(state.matchCount == 0)
        #expect(state.currentIndex == 0)
    }

    @Test("replace-all refreshes a stale snapshot before mutating")
    func replaceAllRefreshesStaleSnapshot() {
        let state = FindState()
        state.query = "cat"
        state.replaceText = "fox"
        let harness = makeHarness(
            source: "cat xx cat",
            findState: state
        )
        harness.coordinator.searchCurrentFindQueryIfNeeded()

        harness.textView.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: 3),
            with: "dog"
        )
        state.onReplaceAll?()

        #expect(harness.textView.string == "dog xx fox")
        #expect(state.matchCount == 0)
        #expect(state.currentIndex == 0)
    }

    @Test("regex and whole-word options compose for plain source")
    func regexWholeWordOptionsCompose() {
        let state = FindState()
        state.query = #"cat(?:s)?"#
        state.useRegex = true
        state.wholeWord = true
        let harness = makeHarness(
            source: "cat cats bobcat catsup",
            findState: state
        )

        harness.coordinator.searchCurrentFindQueryIfNeeded()

        #expect(state.matchCount == 2)
        #expect(harness.coordinator.findController.matches == [
            NSRange(location: 0, length: 3),
            NSRange(location: 4, length: 4)
        ])
    }

    @Test("replace-current synchronizes the wrapped result index")
    func replaceCurrentSynchronizesWrappedIndex() {
        let state = FindState()
        state.query = "one"
        state.replaceText = "two"
        let harness = makeHarness(
            source: "one one one",
            findState: state
        )
        harness.coordinator.searchCurrentFindQueryIfNeeded()
        state.onNavigate?(-1)
        #expect(state.currentIndex == 2)

        state.onReplaceCurrent?()

        #expect(harness.textView.string == "one one two")
        #expect(state.matchCount == 2)
        #expect(state.currentIndex == 0)
        #expect(state.displayText == "1/2")
    }

    @Test("replace-all synchronizes matches introduced by replacement text")
    func replaceAllSynchronizesRemainingMatches() {
        let state = FindState()
        state.query = "cat"
        state.replaceText = "cat!"
        let harness = makeHarness(
            source: "cat cat",
            findState: state
        )
        harness.coordinator.searchCurrentFindQueryIfNeeded()

        state.onReplaceAll?()

        #expect(harness.textView.string == "cat! cat!")
        #expect(state.matchCount == 2)
        #expect(state.currentIndex == 0)
        #expect(state.displayText == "1/2")
    }

    private func makeHarness(
        source: String,
        findState: FindState
    ) -> (coordinator: EditorView.Coordinator, textView: PaperTextView) {
        let sessionURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PlainSourceFindCoordinatorTests-" + UUID().uuidString + ".json"
            )
        let manager = DocumentManager(
            sessionURL: sessionURL,
            sessionSaveDelay: 3_600
        )
        let editor = EditorView(
            text: source,
            scrollY: 0,
            docManager: manager,
            fontIndex: .constant(1),
            isMarkdown: false,
            isPreviewMode: false,
            findState: findState,
            bridge: EditorBridge(),
            scrollModel: ScrollProgressModel(),
            activeHeadingModel: ActiveHeadingModel(),
            hoverURL: HoverURLModel(),
            docMetrics: DocMetricsModel(),
            diag: DiagModel()
        )
        let coordinator = EditorView.Coordinator(editor)
        let textView = PaperTextView(frame: .zero)
        textView.delegate = coordinator
        textView.textStorage?.delegate = coordinator
        textView.font = NSFont.systemFont(
            ofSize: DesignTokens.bodyFontSizes[1]
        )
        textView.string = source
        coordinator.textView = textView
        coordinator.findController.textView = textView
        if let storage = textView.textStorage {
            editor.applyPlainSource(to: storage, font: textView.font!)
        }
        coordinator.clearPendingEditedRange()
        return (coordinator, textView)
    }

    private func makeNativeSaveHarness(
        source: String,
        url: URL
    ) throws -> (
        manager: DocumentManager,
        textView: PaperTextView,
        teardown: () -> Void
    ) {
        try Data(source.utf8).write(to: url)
        let manager = DocumentManager(
            sessionURL: url.deletingLastPathComponent().appendingPathComponent("session.json"),
            sessionSaveDelay: 3_600
        )
        guard case .openedFile = manager.openSelection(url, admission: .system) else {
            throw NativeSaveHarnessError.openFailed
        }
        let findState = FindState()
        let editor = EditorView(
            text: source,
            scrollY: 0,
            docManager: manager,
            fontIndex: .constant(1),
            isMarkdown: false,
            isPreviewMode: false,
            findState: findState,
            bridge: EditorBridge(),
            scrollModel: ScrollProgressModel(),
            activeHeadingModel: ActiveHeadingModel(),
            hoverURL: HoverURLModel(),
            docMetrics: DocMetricsModel(),
            diag: DiagModel()
        )
        let coordinator = EditorView.Coordinator(editor)
        let textView = PaperTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
        textView.delegate = coordinator
        textView.textStorage?.delegate = coordinator
        textView.string = source
        coordinator.textView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = textView
        _ = window.makeFirstResponder(textView)
        manager.pullActiveText = { [weak textView] in textView?.string ?? "" }
        manager.pullActiveSelection = { [weak textView] in textView?.selectedRange() }
        return (
            manager,
            textView,
            {
                _ = window.makeFirstResponder(nil)
                window.contentView = nil
                textView.delegate = nil
                textView.textStorage?.delegate = nil
            }
        )
    }

    private func appendMarkedText(_ text: String, to textView: NSTextView) {
        let location = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.setMarkedText(
            text,
            selectedRange: NSRange(location: (text as NSString).length, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    private enum NativeSaveHarnessError: Error {
        case openFailed
    }

    private func temporaryRoot(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownViewerPlainSourceTests", isDirectory: true)
            .appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    private func expectFlatPlainAttributes(_ textView: NSTextView) {
        guard let storage = textView.textStorage else {
            Issue.record("missing text storage")
            return
        }
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttributes(in: full) { attributes, _, _ in
            let font = attributes[.font] as? NSFont
            let color = attributes[.foregroundColor] as? NSColor
            #expect(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
            #expect(color?.isEqual(DesignTokens.bodyText) == true)
            #expect(attributes[.mvNonBody] == nil)
        }
    }
}
