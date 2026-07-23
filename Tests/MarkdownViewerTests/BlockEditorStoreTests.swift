import Foundation
import Testing
@testable import MarkdownViewer

@Suite(.serialized)
@MainActor
struct BlockEditorStoreTests {
    @Test("ordinary Return splits paragraph and heading at every caret boundary")
    func ordinaryReturnSplitMatrix() throws {
        for source in ["paragraph", "# Heading"] {
            for command in [MarkdownEditingCommand.enter, .shiftEnter] {
                let length = (source as NSString).length
                for offset in [0, length / 2, length] {
                    let document = MarkdownDocument(source: source)
                    let originalID = try #require(document.blocks.first?.id)
                    let store = BlockEditorStore(tabID: UUID(), document: document) { _ in }
                    let result = try MarkdownEditingCommands.apply(
                        command,
                        to: source,
                        selection: NSRange(location: offset, length: 0),
                        blockKind: document.blocks[0].kind
                    )

                    store.beginSourceEditing(blockID: originalID)
                    store.updateActiveDraft(
                        result.replacementSource,
                        selection: result.selection
                    )
                    store.handleBoundaryAction(
                        try #require(result.boundaryAction),
                        selection: result.selection
                    )

                    let left = (source as NSString).substring(to: offset)
                    let right = (source as NSString).substring(from: offset)
                    guard store.document.blocks.count == 2 else {
                        Issue.record("Return did not create exactly one right-hand block")
                        continue
                    }
                    #expect(store.document.blocks[0].id == originalID)
                    #expect(store.document.blocks[0].source == left)
                    #expect(store.document.blocks[1].source == right)
                    #expect(store.activeBlockID == store.document.blocks[1].id)
                    #expect(store.activeSelection == NSRange(location: 0, length: 0))
                }
            }
        }
    }

    @Test("tail Return inserts and focuses an empty paragraph before an existing successor")
    func tailReturnInsertsBeforeExistingSuccessor() throws {
        for source in ["paragraph", "# Heading"] {
            let original = MarkdownDocument(source: source + "\n\nsuccessor")
            let edited = original.blocks[0]
            let successor = original.blocks[1]
            let store = BlockEditorStore(tabID: UUID(), document: original) { _ in }
            let result = try MarkdownEditingCommands.apply(
                .enter,
                to: edited.source,
                selection: NSRange(
                    location: (edited.source as NSString).length,
                    length: 0
                ),
                blockKind: edited.kind
            )

            store.beginSourceEditing(blockID: edited.id)
            store.updateActiveDraft(result.replacementSource, selection: result.selection)
            store.handleBoundaryAction(
                try #require(result.boundaryAction),
                selection: result.selection
            )

            guard store.document.blocks.count == 3 else {
                Issue.record("Return did not insert a block before the successor")
                continue
            }
            #expect(store.document.blocks[0].id == edited.id)
            #expect(store.document.blocks[1].kind == .paragraph)
            #expect(store.document.blocks[1].source.isEmpty)
            #expect(store.document.blocks[2].id == successor.id)
            #expect(store.activeBlockID == store.document.blocks[1].id)
            #expect(store.activeSelection == NSRange(location: 0, length: 0))
        }
    }

    @Test("tail Return preserves neighbors when splitting first, middle, and last blocks")
    func tailReturnPreservesEveryNeighborPosition() throws {
        for targetIndex in 0..<3 {
            let original = MarkdownDocument(source: "first\n\nmiddle\n\nlast")
            let originalIDs = original.blocks.map(\.id)
            let target = original.blocks[targetIndex]
            let store = BlockEditorStore(tabID: UUID(), document: original) { _ in }
            let offset = (target.source as NSString).length

            store.beginSourceEditing(blockID: target.id)
            store.updateActiveDraft(
                target.source,
                selection: NSRange(location: offset, length: 0)
            )
            store.handleBoundaryAction(
                .splitBlock,
                selection: NSRange(location: offset, length: 0)
            )

            #expect(store.document.blocks.count == 4)
            #expect(store.document.blocks[targetIndex].id == target.id)
            #expect(store.document.blocks[targetIndex + 1].source.isEmpty)
            #expect(store.activeBlockID == store.document.blocks[targetIndex + 1].id)
            for originalIndex in original.blocks.indices where originalIndex != targetIndex {
                let shiftedIndex = originalIndex > targetIndex
                    ? originalIndex + 1
                    : originalIndex
                #expect(store.document.blocks[shiftedIndex].id == originalIDs[originalIndex])
            }
        }
    }

    @Test("first and last block edge commands keep the source editor active")
    func documentEdgeCommandsPreserveEditing() throws {
        let original = MarkdownDocument(source: "first\n\nlast")
        let first = original.blocks[0]
        let last = original.blocks[1]
        let store = BlockEditorStore(tabID: UUID(), document: original) { _ in }

        for action in [
            MarkdownEditingBoundaryAction.mergeWithPrevious,
            .navigateToPreviousBlock,
        ] {
            let selection = NSRange(location: 0, length: 0)
            store.beginSourceEditing(blockID: first.id, selection: selection)
            store.handleBoundaryAction(action, selection: selection)
            #expect(store.activeBlockID == first.id)
            #expect(store.activeSelection == selection)
        }

        let lastSelection = NSRange(
            location: (last.source as NSString).length,
            length: 0
        )
        store.beginSourceEditing(blockID: last.id, selection: lastSelection)
        store.handleBoundaryAction(.navigateToNextBlock, selection: lastSelection)
        #expect(store.activeBlockID == last.id)
        #expect(store.activeSelection == lastSelection)
    }

    @Test("single block has no merge or vertical navigation escape")
    func singleBlockEdgeCommandsPreserveEditing() throws {
        let document = MarkdownDocument(source: "only")
        let block = try #require(document.blocks.first)
        let store = BlockEditorStore(tabID: UUID(), document: document) { _ in }

        for (action, offset) in [
            (MarkdownEditingBoundaryAction.mergeWithPrevious, 0),
            (.navigateToPreviousBlock, 0),
            (.navigateToNextBlock, (block.source as NSString).length),
        ] {
            let selection = NSRange(location: offset, length: 0)
            store.beginSourceEditing(blockID: block.id, selection: selection)
            store.handleBoundaryAction(action, selection: selection)
            #expect(store.activeBlockID == block.id)
            #expect(store.activeSelection == selection)
        }
    }

    @Test
    func sourceCommitMutatesOnlyTheEditedBlock() throws {
        let original = MarkdownDocument(source: "before\n\n**middle**\n\nafter\n")
        let originalBlocks = original.blocks
        var snapshots: [MarkdownDocument] = []
        let store = BlockEditorStore(tabID: UUID(), document: original) {
            snapshots.append($0)
        }
        let edited = try #require(originalBlocks[safe: 1])

        store.beginSourceEditing(blockID: edited.id)
        store.updateActiveDraft("**changed**", selection: NSRange(location: 11, length: 0))
        store.commitActiveEditing()

        #expect(store.source == "before\n\n**changed**\n\nafter\n")
        #expect(store.document.blocks[0] == originalBlocks[0])
        #expect(store.document.blocks[1].id == edited.id)
        #expect(store.document.blocks[2] == originalBlocks[2])
        #expect(store.parseCount == 2)
        #expect(store.localMutationCount == 1)
        #expect(snapshots.count == 1)
    }

    @Test("stale source callbacks cannot overwrite a newly activated block")
    func staleSourceCallbacksAreRejectedAfterBlockSwitch() throws {
        let original = MarkdownDocument(source: "# A\n\nB")
        let first = try #require(original.blocks[safe: 0])
        let second = try #require(original.blocks[safe: 1])
        let store = BlockEditorStore(tabID: UUID(), document: original) { _ in }

        store.beginSourceEditing(blockID: first.id)
        let firstSession = try #require(store.activeSourceEditingToken)
        store.beginSourceEditing(blockID: second.id)
        let secondSession = try #require(store.activeSourceEditingToken)

        store.updateActiveDraft(
            first.source,
            selection: NSRange(location: first.source.utf16.count, length: 0),
            sessionToken: firstSession
        )
        store.commitActiveEditing(sessionToken: firstSession)

        #expect(store.source == original.source)
        #expect(store.activeBlockID == second.id)
        #expect(store.activeSourceEditingToken == secondSession)
        #expect(store.snapshotDocument().block(id: second.id)?.source == second.source)
    }

    @Test("reactivating the same block creates a new source session generation")
    func staleSourceCallbacksAreRejectedAfterBlockReentry() throws {
        let original = MarkdownDocument(source: "# A\n\nB")
        let first = try #require(original.blocks[safe: 0])
        let second = try #require(original.blocks[safe: 1])
        let store = BlockEditorStore(tabID: UUID(), document: original) { _ in }

        store.beginSourceEditing(blockID: first.id)
        let staleSession = try #require(store.activeSourceEditingToken)
        store.beginSourceEditing(blockID: second.id)
        store.beginSourceEditing(blockID: first.id)
        let currentSession = try #require(store.activeSourceEditingToken)

        #expect(currentSession.blockID == staleSession.blockID)
        #expect(currentSession.generation > staleSession.generation)

        store.updateActiveDraft(
            "# CORRUPTED",
            selection: NSRange(location: 11, length: 0),
            sessionToken: staleSession
        )
        store.commitActiveEditing(sessionToken: staleSession)

        #expect(store.source == original.source)
        #expect(store.activeSourceEditingToken == currentSession)
        #expect(store.snapshotDocument().block(id: first.id)?.source == first.source)
    }

    @Test
    func committedSourceEditSupportsUndoAndRedo() throws {
        let original = MarkdownDocument(source: "alpha\n\nomega")
        var latest = original
        let store = BlockEditorStore(tabID: UUID(), document: original) { latest = $0 }
        let firstID = try #require(original.blocks.first?.id)

        store.beginSourceEditing(blockID: firstID)
        store.updateActiveDraft("beta")
        store.commitActiveEditing()
        #expect(latest.source == "beta\n\nomega")

        store.undoManager.undo()
        #expect(store.source == original.source)
        #expect(latest.source == original.source)

        store.undoManager.redo()
        #expect(store.source == "beta\n\nomega")
        #expect(latest.source == "beta\n\nomega")
    }

    @Test
    func tableGridCommitsAndUndoRestoresExactSource() throws {
        let originalSource = "| A | B |\r\n| :--- | ---: |\r\n| 1 | 2 |\r\n"
        let original = MarkdownDocument(source: originalSource)
        var latest = original
        let store = BlockEditorStore(tabID: UUID(), document: original) { latest = $0 }
        let tableID = try #require(original.blocks.first?.id)

        store.beginTableEditing(blockID: tableID, cell: MarkdownTableCell(row: 0, column: 1))
        store.setTableCell(MarkdownTableCell(row: 0, column: 1), value: "changed")
        store.addTableColumn()
        store.finishTableEditing()

        #expect(latest.source.contains("changed"))
        #expect(latest.source.contains("|  |"))
        #expect(latest.source.contains("\r\n"))
        #expect(store.activeTableID == nil)

        store.undoManager.undo()
        store.undoManager.undo()
        #expect(store.source == originalSource)
        #expect(store.document.blocks.first?.id == tableID)
    }

    @Test("bounded table-controls sequence preserves shape and alignment")
    func boundedTableControlsSequence() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ui/格式示例.md")
        let originalSource = try String(contentsOf: fixtureURL, encoding: .utf8)
        let original = MarkdownDocument(source: originalSource)
        let originalBlockCount = original.blocks.count
        let tableBlock = try #require(original.blocks[safe: 28])
        let originalGrid = try original.tableGrid(for: tableBlock.id)
        let firstBodyCell = MarkdownTableCell(row: 0, column: 0)
        let targetRow = "| ⌘B | 加粗 | 全部 |"
        let targetRange = try #require(originalSource.range(of: targetRow))
        var expectedSource = originalSource
        expectedSource.replaceSubrange(
            targetRange,
            with: "| E2E_TABLE | 加粗 | 全部 |"
        )
        let store = BlockEditorStore(tabID: UUID(), document: original) { _ in }

        store.beginTableEditing(blockID: tableBlock.id, cell: firstBodyCell)
        store.setTableCell(firstBodyCell, value: "E2E_TABLE")
        store.moveTableFocus(forward: true)
        #expect(store.activeTableCell == MarkdownTableCell(row: 0, column: 1))

        store.cycleActiveTableAlignment()
        store.cycleActiveTableAlignment()
        store.cycleActiveTableAlignment()
        store.addTableRow()
        store.deleteActiveTableRow()
        store.addTableColumn()
        store.deleteActiveTableColumn()
        store.finishTableEditing()

        let committedTable = try store.document.tableGrid(for: tableBlock.id)
        #expect(store.source == expectedSource)
        #expect(store.document.blocks.count == originalBlockCount)
        #expect(store.document.blocks.count == 37)
        #expect(store.document.blocks[28].kind == .table)
        #expect(committedTable.columnCount == originalGrid.columnCount)
        #expect(committedTable.rows.count == originalGrid.rows.count)
        #expect(committedTable.alignments == originalGrid.alignments)
        #expect(committedTable.header == originalGrid.header)
        #expect(committedTable.rows[0][0] == "E2E_TABLE")
        #expect(store.activeTableID == nil)
        #expect(store.activeTableCell == nil)
        #expect(store.localMutationCount == 8)
        #expect(store.parseCount == 9)
    }

    @Test("bounded table-navigation sequence moves focus and adds one terminal row")
    func boundedTableNavigationSequence() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ui/格式示例.md")
        let originalSource = try String(contentsOf: fixtureURL, encoding: .utf8)
        let original = MarkdownDocument(source: originalSource)
        let tableBlock = try #require(original.blocks[safe: 28])
        let originalGrid = try original.tableGrid(for: tableBlock.id)
        let store = BlockEditorStore(tabID: UUID(), document: original) { _ in }

        store.beginTableEditing(
            blockID: tableBlock.id,
            cell: MarkdownTableCell(row: 0, column: 0)
        )
        store.moveTableFocus(forward: true)
        #expect(store.activeTableCell == MarkdownTableCell(row: 0, column: 1))
        store.moveTableFocus(forward: false)
        #expect(store.activeTableCell == MarkdownTableCell(row: 0, column: 0))
        store.moveTableFocus(forward: true, vertical: true)
        #expect(store.activeTableCell == MarkdownTableCell(row: 1, column: 0))
        for _ in 0..<8 {
            store.moveTableFocus(forward: true)
        }
        #expect(store.activeTableCell == MarkdownTableCell(row: 3, column: 2))
        store.moveTableFocus(forward: true)
        #expect(store.activeTableCell == MarkdownTableCell(row: 4, column: 0))
        store.finishTableEditing()

        let committed = try store.document.tableGrid(for: tableBlock.id)
        #expect(committed.header == originalGrid.header)
        #expect(committed.alignments == originalGrid.alignments)
        #expect(committed.rows.dropLast() == originalGrid.rows[...])
        #expect(committed.rows.last == ["", "", ""])
        #expect(committed.rows.count == originalGrid.rows.count + 1)
        #expect(store.document.blocks.count == 37)
        #expect(store.document.blocks[28].source == tableBlock.source + "\n|  |  |  |")
        #expect(store.activeTableID == nil)
        #expect(store.activeTableCell == nil)
        #expect(store.localMutationCount == 1)
        #expect(store.parseCount == 2)
    }

    @Test("bounded editor-boundaries sequence navigates, formats, and merges")
    func boundedEditorBoundariesSequence() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ui/格式示例.md")
        let originalSource = try String(contentsOf: fixtureURL, encoding: .utf8)
        let original = MarkdownDocument(source: originalSource)
        let first = try #require(original.blocks[safe: 10])
        let second = try #require(original.blocks[safe: 11])
        let inlineCode = "`E2E_CODE`"
        let italic = "*E2E_ITALIC*"
        let merged = first.source + inlineCode + italic + second.source
        let store = BlockEditorStore(tabID: UUID(), document: original) { _ in }

        store.beginSourceEditing(blockID: first.id)
        store.handleBoundaryAction(
            .navigateToNextBlock,
            selection: NSRange(location: 0, length: 0)
        )
        #expect(store.activeBlockID == second.id)
        store.updateActiveDraft(
            italic + second.source,
            selection: NSRange(location: (italic as NSString).length, length: 0)
        )
        store.handleBoundaryAction(
            .navigateToPreviousBlock,
            selection: NSRange(location: 0, length: 0)
        )
        #expect(store.activeBlockID == first.id)
        store.updateActiveDraft(
            first.source + inlineCode,
            selection: NSRange(
                location: (first.source as NSString).length + (inlineCode as NSString).length,
                length: 0
            )
        )
        store.handleBoundaryAction(
            .navigateToNextBlock,
            selection: NSRange(location: 0, length: 0)
        )
        store.handleBoundaryAction(
            .mergeWithPrevious,
            selection: NSRange(location: 0, length: 0)
        )
        store.commitActiveEditing()

        #expect(store.document.blocks.count == 36)
        #expect(store.document.blocks[10].kind == .paragraph)
        #expect(store.document.blocks[10].source == merged)
        #expect(store.document.blocks[11].kind == .quote)
        #expect(store.source == originalSource.replacingOccurrences(
            of: first.source + "\n\n" + second.source,
            with: merged
        ))
        #expect(store.activeBlockID == nil)
        #expect(store.localMutationCount == 3)
        #expect(store.parseCount == 4)
    }

    @Test("bounded preview-content sequence toggles only the selected task")
    func boundedPreviewContentSequence() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ui/格式示例.md")
        let originalSource = try String(contentsOf: fixtureURL, encoding: .utf8)
        let original = MarkdownDocument(source: originalSource)
        let originalBlocks = original.blocks
        let taskBlock = try #require(originalBlocks[safe: 19])
        let before = "- [ ] 协同编辑"
        let after = "- [x] 协同编辑"
        #expect(originalSource.components(separatedBy: before).count == 2)
        let store = BlockEditorStore(tabID: UUID(), document: original) { _ in }

        store.toggleTask(blockID: taskBlock.id, itemIndex: 2)

        #expect(store.source == originalSource.replacingOccurrences(
            of: before,
            with: after
        ))
        #expect(store.document.blocks.count == 37)
        #expect(store.document.blocks[19].id == taskBlock.id)
        #expect(store.document.blocks[19].source.contains(after))
        #expect(store.document.blocks.enumerated().allSatisfy { index, block in
            index == 19 || block == originalBlocks[index]
        })
        #expect(store.activeBlockID == nil)
        #expect(store.activeTableID == nil)
        #expect(store.localMutationCount == 1)
        #expect(store.parseCount == 2)
    }

    @Test
    func tableUndoAndRedoResynchronizeTheOpenDraftAndClampItsCell() throws {
        let original = MarkdownDocument(
            source: "| A | B |\n| --- | --- |\n| one | two |"
        )
        let store = BlockEditorStore(tabID: UUID(), document: original) { _ in }
        let tableID = try #require(original.blocks.first?.id)
        let firstCell = MarkdownTableCell(row: 0, column: 0)

        store.beginTableEditing(blockID: tableID, cell: firstCell)
        store.setTableCell(firstCell, value: "changed")
        store.undoManager.undo()

        #expect(store.tableDraft?.rows == [["one", "two"]])

        store.undoManager.redo()

        #expect(store.tableDraft?.rows == [["changed", "two"]])

        store.addTableColumn()
        #expect(store.activeTableCell == .header(2))
        store.undoManager.undo()

        #expect(store.tableDraft?.columnCount == 2)
        #expect(store.activeTableCell == .header(1))

        store.setTableCell(MarkdownTableCell(row: 0, column: 1), value: "later")
        let committed = try store.document.tableGrid(for: tableID)

        #expect(committed.columnCount == 2)
        #expect(committed.rows == [["changed", "later"]])
    }

    @Test
    func synchronizeNeverOverwritesAnActiveDraft() throws {
        let original = MarkdownDocument(source: "first")
        let store = BlockEditorStore(tabID: UUID(), document: original) { _ in }
        let blockID = try #require(original.blocks.first?.id)

        store.beginSourceEditing(blockID: blockID)
        store.updateActiveDraft("draft")
        store.synchronizeIfNeeded(from: "external")
        #expect(store.source == "first")

        store.commitActiveEditing()
        #expect(store.source == "draft")
        store.synchronizeIfNeeded(from: "external")
        #expect(store.source == "external")
        #expect(store.parseCount == 3)
    }

    @Test
    func findUsesVisibleTextAndTracksAnActiveSourceDraft() throws {
        let document = MarkdownDocument(source: "Read **bold** and [link](secret)")
        let store = BlockEditorStore(tabID: UUID(), document: document) { _ in }
        let blockID = try #require(document.blocks.first?.id)

        store.search(BlockFindOptions(query: "secret"))
        #expect(store.findResult.matches.isEmpty)

        store.beginSourceEditing(blockID: blockID)
        store.updateActiveDraft("Read **bold** and [link](changed-secret)")
        store.search(BlockFindOptions(query: "changed-secret"))
        #expect(store.findResult.matches.count == 1)
        #expect(store.currentFindMatch?.blockID == blockID)
    }

    @Test
    func findReplacementUsesLocalMutationAndSupportsUndo() throws {
        let document = MarkdownDocument(source: "before\n\nname Ada\n\nafter")
        let originalBlocks = document.blocks
        let store = BlockEditorStore(tabID: UUID(), document: document) { _ in }

        store.search(BlockFindOptions(query: #"name (\w+)"#, useRegex: true))
        #expect(store.replaceCurrentFind(with: "person $1") == 1)
        #expect(store.source == "before\n\nperson Ada\n\nafter")
        #expect(store.document.blocks[0] == originalBlocks[0])
        #expect(store.document.blocks[2] == originalBlocks[2])

        store.undoManager.undo()
        #expect(store.source == document.source)
    }

    @Test("replace-current advances past inserted matches and wraps after the last result")
    func findReplacementAdvancesLikeNavigation() throws {
        let document = MarkdownDocument(source: "one one one")
        let store = BlockEditorStore(tabID: UUID(), document: document) { _ in }

        store.search(BlockFindOptions(query: "one"))
        store.navigateFind(-1)
        #expect(store.currentFindIndex == 2)

        #expect(store.replaceCurrentFind(with: "two") == 1)
        #expect(store.source == "one one two")
        #expect(store.currentFindIndex == 0)

        store.search(BlockFindOptions(query: #"\d"#, useRegex: true))
        #expect(store.findResult.matches.isEmpty)

        let numeric = MarkdownDocument(source: "1 2")
        let numericStore = BlockEditorStore(tabID: UUID(), document: numeric) { _ in }
        numericStore.search(BlockFindOptions(query: #"\d"#, useRegex: true))

        #expect(numericStore.replaceCurrentFind(with: "9") == 1)
        #expect(numericStore.source == "9 2")
        #expect(numericStore.currentFindIndex == 1)
        #expect(numericStore.currentFindMatch?.visibleText == "2")
    }

    @Test("replace-current mutates a source-only match without leaving block editing")
    func activeSourceReplacementKeepsTheEditingSurfaceLive() throws {
        let document = MarkdownDocument(source: "Read [Link](old-destination)")
        let store = BlockEditorStore(tabID: UUID(), document: document) { _ in }
        let blockID = try #require(document.blocks.first?.id)

        store.beginSourceEditing(blockID: blockID)
        store.search(BlockFindOptions(query: "old-destination"))

        #expect(store.findResult.matches.count == 1)
        #expect(store.replaceCurrentFind(with: "new-destination") == 1)
        #expect(store.snapshotDocument().source == "Read [Link](new-destination)")
        #expect(store.activeBlockID == blockID)
        #expect(store.activeSelection == NSRange(location: 12, length: 15))
        #expect(store.findResult.matches.isEmpty)

        store.undoManager.undo()
        #expect(store.snapshotDocument().source == "Read [Link](old-destination)")
    }

    @Test("replace-all covers source-only and rendered matches while preserving source editing")
    func activeSourceReplaceAllPreservesTheEditingSurface() throws {
        let document = MarkdownDocument(source: """
        Read [Link](old-destination)

        old-destination is visible here
        """)
        let store = BlockEditorStore(tabID: UUID(), document: document) { _ in }
        let sourceBlockID = try #require(document.blocks.first?.id)

        store.beginSourceEditing(
            blockID: sourceBlockID,
            selection: NSRange(location: 5, length: 0)
        )
        store.search(BlockFindOptions(query: "old-destination"))

        #expect(store.findResult.matches.count == 2)
        #expect(store.replaceAllFind(with: "new-destination") == 2)
        #expect(store.snapshotDocument().source == """
        Read [Link](new-destination)

        new-destination is visible here
        """)
        #expect(store.activeBlockID == sourceBlockID)
        #expect(store.findResult.matches.isEmpty)

        store.undoManager.undo()
        #expect(store.snapshotDocument().source == document.source)

        store.undoManager.redo()
        #expect(store.snapshotDocument().source == """
        Read [Link](new-destination)

        new-destination is visible here
        """)
    }

    @Test("active table find maps navigation to cells without stealing the edited cell")
    func activeTableFindExposesCurrentCellState() throws {
        let document = MarkdownDocument(source: """
        | needle | Other |
        | --- | --- |
        | first needle | editing |
        | final | needle |
        """)
        let store = BlockEditorStore(tabID: UUID(), document: document) { _ in }
        let tableID = try #require(document.blocks.first?.id)
        let editedCell = MarkdownTableCell(row: 0, column: 1)

        store.beginTableEditing(blockID: tableID, cell: editedCell)
        store.search(BlockFindOptions(query: "needle"))

        #expect(store.findResult.matches.count == 3)
        #expect(store.currentFindTableCell == .header(0))
        #expect(store.currentFindTableRange == NSRange(location: 0, length: 6))

        store.navigateFind(1)
        #expect(store.currentFindTableCell == MarkdownTableCell(row: 0, column: 0))
        #expect(store.activeTableCell == editedCell)

        store.navigateFind(-1)
        #expect(store.currentFindTableCell == .header(0))
        #expect(store.activeTableCell == editedCell)
    }

    @Test("replace-current edits the active table cell and keeps the grid open")
    func activeTableReplacementKeepsTheGridLive() throws {
        let document = MarkdownDocument(source: """
        | Name | Value |
        | --- | --- |
        | [Link](old-destination) | a\\|b |
        """)
        let store = BlockEditorStore(tabID: UUID(), document: document) { _ in }
        let tableID = try #require(document.blocks.first?.id)
        let cell = MarkdownTableCell(row: 0, column: 0)

        store.beginTableEditing(blockID: tableID, cell: cell)
        store.search(BlockFindOptions(query: "old-destination"))

        #expect(store.currentFindTableCell == cell)
        #expect(store.replaceCurrentFind(with: "new-destination") == 1)
        #expect(store.activeTableID == tableID)
        #expect(store.activeTableCell == cell)
        #expect(store.tableDraft?.rows[0][0] == "[Link](new-destination)")
        #expect(store.snapshotDocument().source.contains("[Link](new-destination)"))
        #expect(store.findResult.matches.isEmpty)
    }

    @Test("replace-all edits every active table cell and keeps the grid open")
    func activeTableReplaceAllPreservesTheGrid() throws {
        let document = MarkdownDocument(source: """
        | Name | Value |
        | --- | --- |
        | [Link](old-destination) | old-destination |
        """)
        let store = BlockEditorStore(tabID: UUID(), document: document) { _ in }
        let tableID = try #require(document.blocks.first?.id)
        let editedCell = MarkdownTableCell(row: 0, column: 1)

        store.beginTableEditing(blockID: tableID, cell: editedCell)
        store.search(BlockFindOptions(query: "old-destination"))

        #expect(store.findResult.matches.count == 2)
        #expect(store.replaceAllFind(with: "new-destination") == 2)
        #expect(store.activeTableID == tableID)
        #expect(store.activeTableCell == editedCell)
        #expect(store.tableDraft?.rows[0] == [
            "[Link](new-destination)",
            "new-destination",
        ])
        #expect(store.findResult.matches.isEmpty)

        store.undoManager.undo()
        #expect(store.activeTableID == tableID)
        #expect(store.tableDraft?.rows[0] == [
            "[Link](old-destination)",
            "old-destination",
        ])

        store.undoManager.redo()
        #expect(store.tableDraft?.rows[0] == [
            "[Link](new-destination)",
            "new-destination",
        ])
    }

    @Test
    func emptyListExitCreatesAnEditableParagraphAtTheCaretBoundary() throws {
        let source = "- one\r\n- \r\n- three"
        let document = MarkdownDocument(source: source)
        let store = BlockEditorStore(tabID: UUID(), document: document) { _ in }
        let listID = try #require(document.blocks.first?.id)

        store.beginSourceEditing(blockID: listID)
        store.updateActiveDraft(
            "- one\r\n\r\n- three",
            selection: NSRange(location: 7, length: 0)
        )
        store.handleBoundaryAction(
            .exitList,
            selection: NSRange(location: 7, length: 0)
        )

        #expect(store.source == "- one\r\n\r\n\r\n\r\n- three")
        #expect(store.document.blocks.map(\.kind) == [.list, .paragraph, .list])
        #expect(store.activeBlock?.kind == .paragraph)
        #expect(store.activeBlock?.source.isEmpty == true)
        #expect(MarkdownDocument(source: store.source).blocks.map(\.kind) == [.list, .paragraph, .list])

        store.undoManager.undo()
        #expect(store.source == source)
    }

    @Test("two Returns at a trailing container create one durable empty paragraph")
    func trailingContainerExitDoesNotDuplicateContent() throws {
        for fixture in [
            (source: "# List tail\n\n- last item", kind: MarkdownBlockKind.list),
            (source: "# Quote tail\n\n> last item", kind: MarkdownBlockKind.quote),
        ] {
            let document = MarkdownDocument(source: fixture.source)
            let store = BlockEditorStore(tabID: UUID(), document: document) { _ in }
            let container = try #require(document.blocks.last)
            let first = try MarkdownEditingCommands.apply(
                .enter,
                to: container.source,
                selection: NSRange(location: (container.source as NSString).length, length: 0),
                blockKind: fixture.kind
            )
            let second = try MarkdownEditingCommands.apply(
                .enter,
                to: first.replacementSource,
                selection: first.selection,
                blockKind: fixture.kind
            )

            store.beginSourceEditing(blockID: container.id)
            store.updateActiveDraft(first.replacementSource, selection: first.selection)
            store.updateActiveDraft(second.replacementSource, selection: second.selection)
            store.handleBoundaryAction(try #require(second.boundaryAction), selection: second.selection)

            let expectedContainer = fixture.kind == .list ? "- last item" : "> last item"
            #expect(store.document.blocks.map(\.kind) == [.heading, fixture.kind, .paragraph])
            #expect(store.document.blocks[1].source == expectedContainer)
            #expect(store.document.blocks[2].source.isEmpty)
            #expect(store.source == fixture.source + "\n\n")

            let reopened = MarkdownDocument(source: store.source)
            #expect(reopened.blocks.map(\.kind) == [.heading, fixture.kind, .paragraph])
            #expect(reopened.blocks[1].source == expectedContainer)
            #expect(reopened.blocks[2].source.isEmpty)
        }
    }

    @Test
    func tableColumnsFillAvailableWidthAndOverflowAtTheirMinimum() {
        #expect(MarkdownTableLayout.columnWidth(availableWidth: 630, columnCount: 3) == 210)
        #expect(MarkdownTableLayout.columnWidth(availableWidth: 630, columnCount: 6) == 120)
        #expect(MarkdownTableLayout.columnWidth(availableWidth: 0, columnCount: 0) == 120)
        #expect(MarkdownTableLayout.rowHeight(header: true) == 39)
        #expect(MarkdownTableLayout.rowHeight(header: false) == 41.5)
        #expect(MarkdownTableLayout.cardHeight(bodyRowCount: 4) == 205)
        #expect(MarkdownTableLayout.cardHeight(bodyRowCount: 5) == 247)
    }

    @Test
    func tableEditorLayoutUsesTheAuthoritativeGridMetrics() {
        #expect(MarkdownTableEditorLayout.toolbarHeight == 32)
        #expect(MarkdownTableEditorLayout.rowHeight(header: true) == 45)
        #expect(MarkdownTableEditorLayout.rowHeight(header: false) == 33)
        #expect(MarkdownTableEditorLayout.gridHeight(bodyRowCount: 4) == 177)
        #expect(MarkdownTableEditorLayout.editorHeight(bodyRowCount: 4) == 274)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
