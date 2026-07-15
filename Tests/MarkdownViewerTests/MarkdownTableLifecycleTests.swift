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

    @Test("view-update field transitions defer store publication without losing text")
    func viewUpdateFieldTransitionDefersPublication() throws {
        let source = """
        | Name| Value  |Note|
        | :--- |---:|:---: |
        | alpha   |  7| keep   spacing |
        | beta|11  |second|
        """
        let document = MarkdownDocument(source: source)
        let store = BlockEditorStore(tabID: UUID(), document: document) { _ in }
        let tableID = try #require(document.blocks.first?.id)
        let firstCell = MarkdownTableCell(row: 0, column: 0)
        let secondCell = MarkdownTableCell(row: 0, column: 1)
        store.beginTableEditing(blockID: tableID, cell: firstCell)
        let generation = store.tableStructureGeneration

        let firstField = NSTextField(frame: .zero)
        firstField.stringValue = "alpha"
        let secondField = NSTextField(frame: .zero)
        secondField.stringValue = "7"
        let bridge = store.tableEditorBridge
        bridge.activate(
            field: firstField,
            cell: firstCell,
            generation: generation,
            onValue: { [weak store] _, value in
                store?.setTableCell(firstCell, value: value)
            }
        )

        firstField.stringValue = "changed"
        bridge.activateFromViewUpdate(
            field: secondField,
            cell: secondCell,
            generation: generation,
            onValue: { [weak store] _, value in
                store?.setTableCell(secondCell, value: value)
            }
        )

        #expect(store.tableDraft?.rows[0][0] == "alpha")
        #expect(store.source == source)

        bridge.deactivate(
            field: secondField,
            cell: secondCell,
            generation: generation,
            flush: false
        )
        _ = bridge.flushForLifecycleBoundary()

        #expect(store.tableDraft?.rows[0][0] == "changed")
        #expect(store.source == source.replacingOccurrences(
            of: "| alpha   |",
            with: "| changed   |"
        ))

        bridge.activate(
            field: firstField,
            cell: firstCell,
            generation: generation,
            onValue: { [weak store] _, value in
                store?.setTableCell(firstCell, value: value)
            }
        )
        firstField.stringValue = "deactivated"
        bridge.deactivateFromViewUpdate(
            field: firstField,
            cell: firstCell,
            generation: generation
        )

        #expect(store.tableDraft?.rows[0][0] == "changed")
        _ = bridge.flushForLifecycleBoundary()
        #expect(store.tableDraft?.rows[0][0] == "deactivated")
    }

    @Test("deleting a non-final row invalidates reused and dismantled field callbacks")
    func deletingNonFinalRowInvalidatesStaleFieldCallbacks() async throws {
        let source = """
        | Name| Value  |Note|
        | :--- |---:|:---: |
        | alpha   |  7| keep   spacing |
        | beta|11  |second|
        """
        let expected = """
        | Name| Value  |Note|
        | :--- |---:|:---: |
        | beta|11  |second|
        """
        let document = MarkdownDocument(source: source)
        let store = BlockEditorStore(tabID: UUID(), document: document) { _ in }
        let tableID = try #require(document.blocks.first?.id)
        let cell = MarkdownTableCell(row: 0, column: 0)
        store.beginTableEditing(blockID: tableID, cell: cell)
        let oldGeneration = store.tableStructureGeneration
        let liveField = try LiveTableField(store: store, cell: cell, value: "alpha")
        defer { liveField.teardown() }

        store.tableEditorBridge.deactivateFromViewUpdate(
            field: liveField.field,
            cell: cell,
            generation: oldGeneration
        )
        store.tableEditorBridge.activateFromViewUpdate(
            field: liveField.field,
            cell: cell,
            generation: oldGeneration,
            onValue: { [weak store] callbackCell, value in
                store?.setTableCellFromEditor(
                    callbackCell,
                    value: value,
                    tableID: tableID,
                    generation: oldGeneration
                )
            }
        )

        store.deleteActiveTableRow()

        let newGeneration = store.tableStructureGeneration
        #expect(newGeneration != oldGeneration)
        #expect(liveField.editor == nil)
        #expect(store.source == expected)

        liveField.field.stringValue = "alpha"
        store.tableEditorBridge.activateFromViewUpdate(
            field: liveField.field,
            cell: cell,
            generation: oldGeneration,
            onValue: { [weak store] callbackCell, value in
                store?.setTableCellFromEditor(
                    callbackCell,
                    value: value,
                    tableID: tableID,
                    generation: oldGeneration
                )
            }
        )
        store.tableEditorBridge.deactivateFromViewUpdate(
            field: liveField.field,
            cell: cell,
            generation: oldGeneration
        )
        store.setTableCellFromEditor(
            cell,
            value: "alpha",
            tableID: tableID,
            generation: oldGeneration
        )
        await drainMainQueue()

        liveField.field.stringValue = "beta"
        store.tableEditorBridge.activateFromViewUpdate(
            field: liveField.field,
            cell: cell,
            generation: newGeneration,
            onValue: { [weak store] callbackCell, value in
                store?.setTableCellFromEditor(
                    callbackCell,
                    value: value,
                    tableID: tableID,
                    generation: newGeneration
                )
            }
        )
        store.tableEditorBridge.deactivateFromViewUpdate(
            field: liveField.field,
            cell: cell,
            generation: oldGeneration
        )
        store.finishTableEditing()

        #expect(store.source == expected)
        #expect(try store.document.tableGrid(for: tableID).rows == [["beta", "11", "second"]])
    }

    @Test("deleting a non-final column rejects stale delivery through save")
    func deletingNonFinalColumnRejectsStaleDeliveryThroughSave() async throws {
        let root = try temporaryRoot(named: "delete-column")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = """
        | Name| Value  |Note|
        | :--- |---:|:---: |
        | alpha   |  7| keep   spacing |
        | beta|11  |second|
        """
        let expected = """
        | Value  |Note|
        |---:|:---: |
        |  7| keep   spacing |
        |11  |second|
        """
        let manager = DocumentManager(
            sessionURL: root.appendingPathComponent("session.json"),
            sessionSaveDelay: 3_600
        )
        let documentURL = root.appendingPathComponent("table.md")
        try Data(source.utf8).write(to: documentURL)
        manager.openTab(for: documentURL, text: source)
        let tab = try #require(manager.activeTab)
        let store = manager.blockEditorStore(for: tab)
        let tableID = try #require(store.document.blocks.first?.id)
        let cell = MarkdownTableCell(row: 0, column: 0)
        store.beginTableEditing(blockID: tableID, cell: cell)
        let oldGeneration = store.tableStructureGeneration
        let liveField = try LiveTableField(store: store, cell: cell, value: "alpha")
        defer { liveField.teardown() }

        store.deleteActiveTableColumn()

        let newGeneration = store.tableStructureGeneration
        #expect(newGeneration != oldGeneration)
        #expect(liveField.editor == nil)
        #expect(store.source == expected)

        liveField.field.stringValue = "7"
        store.tableEditorBridge.activateFromViewUpdate(
            field: liveField.field,
            cell: cell,
            generation: newGeneration,
            onValue: { [weak store] callbackCell, value in
                store?.setTableCellFromEditor(
                    callbackCell,
                    value: value,
                    tableID: tableID,
                    generation: newGeneration
                )
            }
        )
        store.tableEditorBridge.deactivateFromViewUpdate(
            field: liveField.field,
            cell: cell,
            generation: oldGeneration
        )
        store.setTableCellFromEditor(
            cell,
            value: "alpha",
            tableID: tableID,
            generation: oldGeneration
        )
        await drainMainQueue()

        var writtenText: String?
        #expect(manager.saveActiveDocument { text, url in
            writtenText = text
            try Data(text.utf8).write(to: url)
        })
        #expect(writtenText == expected)
        #expect(store.source == expected)
        #expect(try store.document.tableGrid(for: tableID).rows == [
            ["7", "keep   spacing"],
            ["11", "second"],
        ])
    }

    @Test("undo and redo of row deletion invalidate the shifted field identity")
    func undoRedoRowDeletionInvalidatesShiftedFieldIdentity() async throws {
        let source = """
        | Name| Value  |Note|
        | :--- |---:|:---: |
        | alpha   |  7| keep   spacing |
        | beta|11  |second|
        """
        let deletedSource = """
        | Name| Value  |Note|
        | :--- |---:|:---: |
        | beta|11  |second|
        """
        let document = MarkdownDocument(source: source)
        let store = BlockEditorStore(tabID: UUID(), document: document) { _ in }
        let tableID = try #require(document.blocks.first?.id)
        let cell = MarkdownTableCell(row: 0, column: 0)
        store.beginTableEditing(blockID: tableID, cell: cell)
        let liveField = try LiveTableField(store: store, cell: cell, value: "alpha")
        defer { liveField.teardown() }

        store.deleteActiveTableRow()
        let deletedGeneration = store.tableStructureGeneration
        liveField.field.stringValue = "beta"
        store.tableEditorBridge.activateFromViewUpdate(
            field: liveField.field,
            cell: cell,
            generation: deletedGeneration,
            onValue: { [weak store] callbackCell, value in
                store?.setTableCellFromEditor(
                    callbackCell,
                    value: value,
                    tableID: tableID,
                    generation: deletedGeneration
                )
            }
        )
        liveField.window.makeFirstResponder(liveField.field)
        #expect(liveField.editor != nil)

        store.undoManager.undo()

        #expect(store.tableStructureGeneration != deletedGeneration)
        #expect(liveField.editor == nil)
        store.setTableCellFromEditor(
            cell,
            value: "beta",
            tableID: tableID,
            generation: deletedGeneration
        )
        store.tableEditorBridge.deactivateFromViewUpdate(
            field: liveField.field,
            cell: cell,
            generation: deletedGeneration
        )
        await drainMainQueue()
        #expect(store.source == source)
        #expect(store.tableDraft?.rows == [
            ["alpha", "7", "keep   spacing"],
            ["beta", "11", "second"],
        ])

        store.undoManager.redo()
        await drainMainQueue()
        #expect(store.source == deletedSource)
        #expect(store.tableDraft?.rows == [["beta", "11", "second"]])
        store.finishTableEditing()
        #expect(store.source == deletedSource)
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

    @Test("failed save keeps marked table text and focused native cell")
    func failedSavePreservesMarkedTableEditor() throws {
        enum WriteFailure: Error { case expected }
        let root = try temporaryRoot(named: "failed-save")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DocumentManager(
            sessionURL: root.appendingPathComponent("session.json"),
            sessionSaveDelay: 3_600
        )
        let documentURL = root.appendingPathComponent("table.md")
        let source = "| Name |\n| --- |\n| old |"
        try Data(source.utf8).write(to: documentURL)
        manager.openTab(for: documentURL, text: source)
        let tab = try #require(manager.activeTab)
        let store = manager.blockEditorStore(for: tab)
        let tableID = try #require(store.document.blocks.first?.id)
        let cell = MarkdownTableCell(row: 0, column: 0)
        store.beginTableEditing(blockID: tableID, cell: cell)
        let liveField = try LiveTableField(store: store, cell: cell, value: "old")
        defer { liveField.teardown() }
        liveField.appendMarkedText("输入")

        #expect(!manager.saveActiveDocument { _, _ in throw WriteFailure.expected })

        #expect(manager.lastSaveFailure == .writeFailed)
        #expect(liveField.hasMarkedText)
        #expect(store.activeTableID == tableID)
        #expect(store.activeTableCell == cell)
        #expect(store.snapshotDocument().source.contains("old输入"))
        #expect(manager.activeTab?.text.contains("old输入") == true)
        #expect(manager.activeTab?.isDirty == true)
        #expect(try Data(contentsOf: documentURL) == Data(source.utf8))
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
        try Data(source.utf8).write(to: documentURL)
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
            #expect(manager.saveActiveDocument { text, url in
                writtenText = text
                try Data(text.utf8).write(to: url)
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

        if boundary == .save {
            #expect(liveField.hasMarkedText)
            #expect(store.activeTableID == tableID)
            #expect(store.activeTableCell == cell)
        } else {
            #expect(!liveField.hasMarkedText)
            #expect(store.activeTableID == nil)
            #expect(store.tableDraft == nil)
        }
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
            #expect(try String(contentsOf: documentURL, encoding: .utf8).contains("old输入"))
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

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    @MainActor
    private final class LiveTableField {
        let field = NSTextField(frame: .zero)
        let window: NSWindow
        let bridge: MarkdownTableEditorBridge
        let cell: MarkdownTableCell
        let generation: MarkdownTableStructureGeneration

        var editor: NSTextView? { field.currentEditor() as? NSTextView }
        var hasMarkedText: Bool { editor?.hasMarkedText() == true }

        init(
            store: BlockEditorStore,
            cell: MarkdownTableCell,
            value: String
        ) throws {
            bridge = store.tableEditorBridge
            self.cell = cell
            generation = store.tableStructureGeneration
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
                generation: generation,
                onValue: { [weak store] callbackCell, value in
                    store?.setTableCell(callbackCell, value: value)
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
            bridge.deactivate(
                field: field,
                cell: cell,
                generation: generation,
                flush: false
            )
            window.makeFirstResponder(nil)
            window.contentView = nil
        }
    }
}
