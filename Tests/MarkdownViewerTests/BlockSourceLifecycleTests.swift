import AppKit
import Foundation
import Testing
@testable import MarkdownViewer

@MainActor
@Suite(.serialized)
struct BlockSourceLifecycleTests {
    private enum ExplicitBoundary: String, CaseIterable {
        case preview
        case save
        case tabSwitch
        case close
    }

    private enum WaitError: Error {
        case timedOut
    }

    @Test
    func explicitBoundariesFlushMarkedTextBeforeCommitting() throws {
        for boundary in ExplicitBoundary.allCases {
            let root = try temporaryRoot(named: boundary.rawValue)
            defer { try? FileManager.default.removeItem(at: root) }
            try expectMarkedTextFlush(at: boundary, root: root)
        }
    }

    @Test
    func delayedSessionSnapshotPreservesMarkedSourceEditing() async throws {
        let root = try temporaryRoot(named: "source-session")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionURL = root.appendingPathComponent("session.json")
        let manager = makeManager(root: root, sessionURL: sessionURL, delay: 0.02)
        manager.openTab(for: root.appendingPathComponent("source.md"), text: "before")
        let tab = try #require(manager.activeTab)
        let store = manager.blockEditorStore(for: tab)
        let blockID = try #require(store.document.blocks.first?.id)
        store.beginSourceEditing(blockID: blockID)
        let editor = LiveEditor(store: store, blockID: blockID)
        editor.appendMarkedText("输入")
        #expect(editor.textView.hasMarkedText())

        manager.scheduleSessionSave()
        let saved = try await waitForSession(at: sessionURL)

        #expect(editor.textView.hasMarkedText())
        #expect(store.activeBlockID == blockID)
        #expect(store.source == "before")
        #expect(manager.activeTab?.text == "before")
        #expect(saved.tabs.first?.text == "before输入")
        #expect(saved.tabs.first?.markdownDocument?.source == "before输入")
        #expect(saved.tabs.first?.isDirty == true)
        editor.teardown()
    }

    @Test
    func delayedSessionSnapshotPreservesTableEditing() async throws {
        let root = try temporaryRoot(named: "table-session")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionURL = root.appendingPathComponent("session.json")
        let manager = makeManager(root: root, sessionURL: sessionURL, delay: 0.02)
        let source = "| Name |\n| --- |\n| old |"
        manager.openTab(for: root.appendingPathComponent("table.md"), text: source)
        let tab = try #require(manager.activeTab)
        let store = manager.blockEditorStore(for: tab)
        let tableID = try #require(store.document.blocks.first?.id)
        let cell = MarkdownTableCell(row: 0, column: 0)
        store.beginTableEditing(blockID: tableID, cell: cell)
        store.setTableCell(cell, value: "changed")

        let saved = try await waitForSession(at: sessionURL)

        #expect(store.activeTableID == tableID)
        #expect(store.activeTableCell == cell)
        #expect(store.tableDraft?.rows.first?.first == "changed")
        #expect(saved.tabs.first?.text.contains("changed") == true)
        #expect(saved.tabs.first?.markdownDocument?.source.contains("changed") == true)
    }

    @Test("find replacement synchronizes the live source editor and store undo")
    func findReplacementSynchronizesTheLiveSourceEditor() throws {
        let document = MarkdownDocument(source: "Read [Link](old-destination)")
        let store = BlockEditorStore(tabID: UUID(), document: document) { _ in }
        let blockID = try #require(document.blocks.first?.id)
        store.beginSourceEditing(blockID: blockID)
        let editor = LiveEditor(store: store, blockID: blockID)
        defer { editor.teardown() }

        store.search(BlockFindOptions(query: "old-destination"))
        #expect(store.replaceCurrentFind(with: "new-destination") == 1)

        #expect(editor.textView.string == "Read [Link](new-destination)")
        #expect(editor.textView.selectedRange() == NSRange(location: 12, length: 15))
        #expect(store.snapshotDocument().source == editor.textView.string)

        store.undoManager.undo()

        #expect(editor.textView.string == "Read [Link](old-destination)")
        #expect(store.snapshotDocument().source == editor.textView.string)
    }

    @Test("source focus retries two refusals and then succeeds")
    func sourceFocusRetryEventuallySucceeds() async throws {
        let harness = FocusHarness(rejections: 2)
        defer { harness.teardown() }

        harness.load(token: "first")
        try await waitForFocusAttempts(harness.window, count: 3)

        #expect(harness.window.sourceFocusAttemptCount == 3)
        #expect(harness.window.firstResponder === harness.host.textView)
    }

    @Test("source focus stops after exactly four refusals")
    func sourceFocusRetryIsBounded() async throws {
        let harness = FocusHarness(rejections: .max)
        defer { harness.teardown() }

        harness.load(token: "bounded")
        try await waitForFocusAttempts(harness.window, count: 4)
        try await Task.sleep(nanoseconds: 40_000_000)

        #expect(harness.window.sourceFocusAttemptCount == 4)
        #expect(harness.window.firstResponder !== harness.host.textView)
    }

    @Test("source focus work is invalidated by teardown")
    func sourceFocusRetryStopsAfterTeardown() async throws {
        let harness = FocusHarness(rejections: .max)

        harness.load(token: "teardown")
        harness.teardown()
        try await Task.sleep(nanoseconds: 40_000_000)

        #expect(harness.window.sourceFocusAttemptCount == 0)
    }

    private func expectMarkedTextFlush(
        at boundary: ExplicitBoundary,
        root: URL
    ) throws {
        let manager = makeManager(
            root: root,
            sessionURL: root.appendingPathComponent("session.json"),
            delay: 3_600
        )
        let documentURL = root.appendingPathComponent("source.md")
        manager.openTab(for: documentURL, text: "before")
        let tab = try #require(manager.activeTab)
        let store = manager.blockEditorStore(for: tab)
        let blockID = try #require(store.document.blocks.first?.id)
        store.beginSourceEditing(blockID: blockID)
        let editor = LiveEditor(store: store, blockID: blockID)
        editor.appendMarkedText("输入")
        #expect(editor.textView.hasMarkedText())
        var writtenText: String?

        switch boundary {
        case .preview:
            manager.togglePreviewMode()
            #expect(manager.previewMode)
        case .save:
            #expect(manager.saveActiveDocument { text, _ in
                writtenText = text
            })
        case .tabSwitch:
            manager.openTab(
                for: root.appendingPathComponent("other.md"),
                text: "other"
            )
            #expect(manager.activeTab?.name == "other.md")
        case .close:
            manager.requestClose(tab)
            #expect(manager.tabs.count == 1)
            #expect(manager.confirmingCloseTabID == tab.id)
        }

        #expect(!editor.textView.hasMarkedText())
        #expect(store.source == "before输入")
        #expect(store.activeBlockID == nil)
        #expect(manager.tabs.first(where: { $0.id == tab.id })?.text == "before输入")
        if boundary == .tabSwitch {
            manager.activateTab(tab.id)
            #expect(store.activeBlockID == blockID)
            #expect(store.activeSelection == NSRange(
                location: ("before输入" as NSString).length,
                length: 0
            ))
        }
        if boundary == .save {
            #expect(writtenText == "before输入")
            #expect(manager.activeTab?.isDirty == false)
        }
        editor.teardown()
    }

    private func waitForSession(at url: URL) async throws -> Session {
        for _ in 0..<100 {
            if let session = SessionStore.load(from: url) {
                return session
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw WaitError.timedOut
    }

    private func waitForFocusAttempts(
        _ window: FocusTestWindow,
        count: Int
    ) async throws {
        for _ in 0..<50 {
            if window.sourceFocusAttemptCount >= count {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw WaitError.timedOut
    }

    private func makeManager(
        root: URL,
        sessionURL: URL,
        delay: TimeInterval
    ) -> DocumentManager {
        DocumentManager(
            sessionURL: sessionURL,
            sessionSaveDelay: delay
        )
    }

    private func temporaryRoot(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownViewerBlockLifecycleTests", isDirectory: true)
            .appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    @MainActor
    private final class FocusTestWindow: NSWindow {
        var rejectionsRemaining: Int
        private(set) var sourceFocusAttemptCount = 0

        init(rejections: Int) {
            rejectionsRemaining = rejections
            super.init(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 180),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
        }

        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            guard responder is BlockSourceTextView else {
                return super.makeFirstResponder(responder)
            }
            sourceFocusAttemptCount += 1
            if rejectionsRemaining > 0 {
                rejectionsRemaining -= 1
                return false
            }
            return super.makeFirstResponder(responder)
        }
    }

    @MainActor
    private final class FocusHarness {
        let coordinator: BlockSourceEditor.Coordinator
        let host: BlockSourceEditorHostView
        let window: FocusTestWindow

        init(rejections: Int) {
            let editor = BlockSourceEditor(
                initialSource: "body",
                blockKind: .paragraph,
                focusToken: "initial",
                onChange: { _, _ in },
                onCommit: { _, _ in }
            )
            coordinator = editor.makeCoordinator()
            host = BlockSourceEditorHostView(
                textView: BlockSourceTextView(frame: .zero)
            )
            window = FocusTestWindow(rejections: rejections)
            window.contentView = host
            coordinator.attach(host: host)
        }

        func load(token: String) {
            coordinator.load(
                source: "body",
                kind: .paragraph,
                token: token,
                selection: NSRange(location: 4, length: 0)
            )
        }

        func teardown() {
            coordinator.teardown()
            _ = window.makeFirstResponder(nil)
            window.contentView = nil
        }
    }

    @MainActor
    private final class LiveEditor {
        let coordinator: BlockSourceEditor.Coordinator
        let host: BlockSourceEditorHostView
        let window: NSWindow

        var textView: BlockSourceTextView { host.textView }

        init(store: BlockEditorStore, blockID: UUID) {
            let block = store.document.block(id: blockID)!
            let editor = BlockSourceEditor(
                initialSource: block.source,
                blockKind: block.kind,
                focusToken: block.id,
                initialSelection: NSRange(
                    location: (block.source as NSString).length,
                    length: 0
                ),
                lifecycleBridge: store.sourceEditorBridge,
                onChange: { [weak store] source, selection in
                    store?.updateActiveDraft(source, selection: selection)
                },
                onCommit: { [weak store] source, selection in
                    store?.updateActiveDraft(source, selection: selection)
                    store?.commitActiveEditing()
                }
            )
            coordinator = editor.makeCoordinator()
            host = BlockSourceEditorHostView(
                textView: BlockSourceTextView(frame: .zero)
            )
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 180),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = host
            coordinator.attach(host: host)
            coordinator.connectLifecycleBridge(editor.lifecycleBridge)
            coordinator.load(
                source: editor.initialSource,
                kind: editor.blockKind,
                token: editor.focusToken,
                selection: editor.initialSelection
            )
            window.makeFirstResponder(host.textView)
        }

        func appendMarkedText(_ text: String) {
            let location = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: location, length: 0))
            textView.setMarkedText(
                text,
                selectedRange: NSRange(
                    location: (text as NSString).length,
                    length: 0
                ),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
        }

        func teardown() {
            coordinator.teardown()
            window.makeFirstResponder(nil)
            window.contentView = nil
        }
    }
}
