import AppKit
import Foundation
import Testing
@testable import MarkdownViewer

@MainActor
@Suite(.serialized)
struct MarkdownTableLifecycleTests {
    @Test("table selection requests focus only when the selected cell changes")
    func tableSelectionDoesNotReclaimFindFieldFocus() {
        var state = MarkdownTableCellFocusRequestState()

        let firstSelection = state.update(isSelected: true)
        let stableSelection = state.update(isSelected: true)
        let deselection = state.update(isSelected: false)
        let reselection = state.update(isSelected: true)

        #expect(firstSelection)
        #expect(!stableSelection)
        #expect(!deselection)
        #expect(reselection)
    }

    @Test("table find formatting highlights only exact UTF-16 match ranges")
    func tableFindFormattingUsesExactRanges() {
        let value = "A😀B needle"
        let emoji = (value as NSString).range(of: "😀")
        let needle = (value as NSString).range(of: "needle")
        let attributed = MarkdownTableFindFormatter.attributedValue(
            value,
            font: .systemFont(ofSize: 13),
            textColor: .textColor,
            highlights: [
                MarkdownTableFindHighlight(range: emoji, isCurrent: false),
                MarkdownTableFindHighlight(range: needle, isCurrent: true),
            ]
        )

        #expect(attributed.string == value)
        #expect(attributed.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
        #expect((attributed.attribute(
            .backgroundColor,
            at: emoji.location,
            effectiveRange: nil
        ) as? NSColor)?.isEqual(DesignTokens.accentSoft) == true)
        #expect((attributed.attribute(
            .backgroundColor,
            at: needle.location,
            effectiveRange: nil
        ) as? NSColor)?.isEqual(DesignTokens.accentStrong) == true)
    }

    private enum ExplicitBoundary: String, CaseIterable {
        case preview
        case save
        case tabSwitch
        case close
    }

    private enum LiveFieldError: Error {
        case missingFieldEditor
    }

    @Test
    func explicitBoundariesFlushMarkedTableTextBeforeClearingTheDraft() throws {
        for boundary in ExplicitBoundary.allCases {
            let root = try temporaryRoot(named: boundary.rawValue)
            defer { try? FileManager.default.removeItem(at: root) }
            try expectMarkedTableTextFlush(at: boundary, root: root)
        }
    }

    @Test
    func escapeFlushesTheLiveFieldBeforeTableStateIsCleared() throws {
        let original = MarkdownDocument(source: "| Name |\n| --- |\n| old |")
        var committedSnapshots: [MarkdownDocument] = []
        let store = BlockEditorStore(tabID: UUID(), document: original) {
            committedSnapshots.append($0)
        }
        let tableID = try #require(original.blocks.first?.id)
        let cell = MarkdownTableCell(row: 0, column: 0)
        store.beginTableEditing(blockID: tableID, cell: cell)
        let liveField = try LiveTableField(store: store, cell: cell, value: "old")
        defer { liveField.teardown() }

        liveField.appendMarkedText("输入")
        #expect(liveField.hasMarkedText)
        #expect(store.source.contains("old输入") == false)

        store.finishTableEditing()

        #expect(!liveField.hasMarkedText)
        #expect(store.activeTableID == nil)
        #expect(store.tableDraft == nil)
        #expect(try store.document.tableGrid(for: tableID).rows == [["old输入"]])
        #expect(committedSnapshots.last?.source == store.source)
    }

    private func expectMarkedTableTextFlush(
        at boundary: ExplicitBoundary,
        root: URL
    ) throws {
        let manager = DocumentManager(
            sessionURL: root.appendingPathComponent("session.json"),
            sessionSaveDelay: 3_600
        )
        let documentURL = root.appendingPathComponent("table.md")
        let source = "| Name |\n| --- |\n| old |"
        manager.openTab(for: documentURL, text: source)
        let tab = try #require(manager.activeTab)
        let store = manager.blockEditorStore(for: tab)
        let tableID = try #require(store.document.blocks.first?.id)
        let cell = MarkdownTableCell(row: 0, column: 0)
        store.beginTableEditing(blockID: tableID, cell: cell)
        let liveField = try LiveTableField(store: store, cell: cell, value: "old")
        defer { liveField.teardown() }
        liveField.appendMarkedText("输入")
        #expect(liveField.hasMarkedText)
        #expect(store.source == source)
        #expect(store.snapshotDocument().source.contains("old输入"))
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
            #expect(manager.confirmingCloseTabID == tab.id)
        }

        #expect(!liveField.hasMarkedText)
        #expect(store.activeTableID == nil)
        #expect(store.tableDraft == nil)
        #expect(try store.document.tableGrid(for: tableID).rows == [["old输入"]])
        #expect(manager.tabs.first(where: { $0.id == tab.id })?.text.contains("old输入") == true)
        if boundary == .tabSwitch {
            manager.activateTab(tab.id)
            #expect(store.activeTableID == tableID)
            #expect(store.activeTableCell == cell)
            #expect(store.tableDraft?.rows == [["old输入"]])
        }
        if boundary == .save {
            #expect(writtenText?.contains("old输入") == true)
            #expect(manager.tabs.first(where: { $0.id == tab.id })?.isDirty == false)
        }
    }

    private func temporaryRoot(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownViewerTableLifecycleTests", isDirectory: true)
            .appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    @MainActor
    private final class LiveTableField {
        let field = NSTextField(frame: .zero)
        let window: NSWindow
        let bridge: MarkdownTableEditorBridge

        var editor: NSTextView? { field.currentEditor() as? NSTextView }
        var hasMarkedText: Bool { editor?.hasMarkedText() == true }

        init(
            store: BlockEditorStore,
            cell: MarkdownTableCell,
            value: String
        ) throws {
            bridge = store.tableEditorBridge
            field.stringValue = value
            field.isEditable = true
            field.isSelectable = true
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 80),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = field
            bridge.activate(
                field: field,
                cell: cell,
                onValue: { [weak store] value in
                    store?.setTableCell(cell, value: value)
                }
            )
            window.makeFirstResponder(field)
            guard editor != nil else { throw LiveFieldError.missingFieldEditor }
        }

        func appendMarkedText(_ text: String) {
            guard let editor else { return }
            let location = (editor.string as NSString).length
            editor.setSelectedRange(NSRange(location: location, length: 0))
            editor.setMarkedText(
                text,
                selectedRange: NSRange(
                    location: (text as NSString).length,
                    length: 0
                ),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
        }

        func teardown() {
            bridge.deactivate(field: field, flush: false)
            window.makeFirstResponder(nil)
            window.contentView = nil
        }
    }
}
