import AppKit
import Foundation

struct MarkdownTableCell: Hashable, Sendable {
    let row: Int
    let column: Int

    static func header(_ column: Int) -> MarkdownTableCell {
        MarkdownTableCell(row: -1, column: column)
    }
}

/// Per-tab native block document state.
///
/// The store survives tab switches, owns one undo history, and exposes only local
/// mutations to the UI. Source edits are held as a draft until a commit boundary.
@MainActor
final class BlockEditorStore: ObservableObject {
    private enum SuspendedEditingState {
        case source(blockID: UUID, selection: NSRange?)
        case table(blockID: UUID, cell: MarkdownTableCell)
    }

    let tabID: UUID
    let undoManager = UndoManager()
    let sourceEditorBridge = BlockSourceEditorBridge()
    let tableEditorBridge = MarkdownTableEditorBridge()

    @Published private(set) var document: MarkdownDocument
    @Published private(set) var activeBlockID: UUID?
    private(set) var activeSelection: NSRange?
    @Published private(set) var activeTableID: UUID?
    @Published private(set) var tableDraft: MarkdownTableGrid?
    @Published var activeTableCell: MarkdownTableCell?
    @Published private(set) var tableStructureGeneration =
        MarkdownTableStructureGeneration.initial
    @Published private(set) var parseCount = 1
    @Published private(set) var localMutationCount = 0
    @Published private(set) var renderRevisionByBlock: [UUID: Int] = [:]
    @Published private(set) var findResult = BlockFindResult(matches: [], error: nil)
    @Published private(set) var currentFindIndex = 0

    private var activeDraftSource: String?
    private var suspendedEditingState: SuspendedEditingState?
    private var findOptions = BlockFindOptions(query: "")
    private let onDraftDivergence: () -> Void
    private let onDocumentChange: (MarkdownDocument) -> Void

    init(
        tabID: UUID,
        document: MarkdownDocument,
        onDraftDivergence: @escaping () -> Void = {},
        onDocumentChange: @escaping (MarkdownDocument) -> Void
    ) {
        self.tabID = tabID
        self.document = document
        self.onDraftDivergence = onDraftDivergence
        self.onDocumentChange = onDocumentChange
    }

    var source: String { document.source }

    func snapshotDocument() -> MarkdownDocument {
        if let activeTableID,
           var grid = tableDraft,
           let live = tableEditorBridge.snapshot(),
           let snapshot = applying(live.value, to: live.cell, in: &grid) {
            var documentSnapshot = document
            do {
                try documentSnapshot.replaceTable(blockID: activeTableID, with: snapshot)
                return documentSnapshot
            } catch {
                assertionFailure("Unable to snapshot active table draft: \(error)")
                return document
            }
        }
        guard let activeBlockID,
              let draft = sourceEditorBridge.snapshot()?.source ?? activeDraftSource,
              draft != document.block(id: activeBlockID)?.source else {
            return document
        }
        var snapshot = document
        do {
            _ = try snapshot.replaceBlock(id: activeBlockID, with: draft)
            return snapshot
        } catch {
            assertionFailure("Unable to snapshot active block draft: \(error)")
            return document
        }
    }

    var snapshotSelection: NSRange? {
        sourceEditorBridge.snapshot()?.selection ?? activeSelection
    }

    var activeBlock: MarkdownBlock? {
        activeBlockID.flatMap(document.block(id:))
    }

    func synchronizeIfNeeded(from source: String) {
        guard activeBlockID == nil, activeTableID == nil, document.source != source else { return }
        document = MarkdownDocument(source: source)
        parseCount += 1
        renderRevisionByBlock = Dictionary(
            uniqueKeysWithValues: document.blocks.map { ($0.id, 1) }
        )
        refreshFind(preservingCurrent: true)
    }

    func beginSourceEditing(blockID: UUID, selection: NSRange? = nil) {
        guard activeTableID == nil, let block = document.block(id: blockID) else { return }
        if activeBlockID != blockID { commitActiveEditing() }
        activeSelection = selection
        activeDraftSource = block.source
        activeBlockID = blockID
        refreshFind(preservingCurrent: true)
    }

    func updateActiveDraft(_ source: String, selection: NSRange? = nil) {
        guard let activeBlockID else { return }
        activeDraftSource = source
        activeSelection = selection
        if document.block(id: activeBlockID)?.source != source {
            onDraftDivergence()
        }
        refreshFind(preservingCurrent: true)
    }

    func commitActiveEditing() {
        if activeTableID != nil {
            finishTableEditing()
            return
        }
        guard let id = activeBlockID else { return }
        defer {
            activeBlockID = nil
            activeDraftSource = nil
            activeSelection = nil
            refreshFind(preservingCurrent: true)
        }
        guard let draft = activeDraftSource,
              draft != document.block(id: id)?.source else { return }
        mutate(affectedBlockIDs: [id], actionName: "编辑块") { document in
            _ = try document.replaceBlock(id: id, with: draft)
        }
    }

    func flushActiveEditingForLifecycleBoundary() {
        if activeBlockID != nil {
            sourceEditorBridge.flushForLifecycleBoundary()
        }
        commitActiveEditing()
    }

    /// Commit the outgoing tab without forgetting which native editor had focus.
    ///
    /// The live AppKit editor still owns the most recent selection at this point,
    /// so sample it before and after the lifecycle flush. The post-flush sample is
    /// preferred because unmarking IME text can move the caret.
    func suspendEditingForTabSwitch() {
        if let blockID = activeBlockID {
            let selectionBeforeFlush = sourceEditorBridge.snapshot()?.selection
                ?? activeSelection
            flushActiveEditingForLifecycleBoundary()
            guard document.block(id: blockID) != nil else {
                suspendedEditingState = nil
                return
            }
            suspendedEditingState = .source(
                blockID: blockID,
                selection: sourceEditorBridge.snapshot()?.selection
                    ?? selectionBeforeFlush
            )
            return
        }

        if let blockID = activeTableID {
            let cell = tableEditorBridge.snapshot()?.cell
                ?? activeTableCell
                ?? .header(0)
            flushActiveEditingForLifecycleBoundary()
            guard document.block(id: blockID)?.kind == .table else {
                suspendedEditingState = nil
                return
            }
            suspendedEditingState = .table(blockID: blockID, cell: cell)
            return
        }

        suspendedEditingState = nil
    }

    /// Restore a focus snapshot once when its tab becomes active again.
    /// Invalidated block IDs are dropped instead of opening an unrelated editor.
    func restoreEditingAfterTabSwitch() {
        guard activeBlockID == nil,
              activeTableID == nil,
              let state = suspendedEditingState else { return }
        suspendedEditingState = nil

        switch state {
        case let .source(blockID, selection):
            guard document.block(id: blockID) != nil else { return }
            beginSourceEditing(blockID: blockID, selection: selection)

        case let .table(blockID, cell):
            guard let grid = try? document.tableGrid(for: blockID) else { return }
            beginTableEditing(
                blockID: blockID,
                cell: clampedTableCell(cell, in: grid)
            )
        }
    }

    func cancelFocusWithoutDiscarding() {
        commitActiveEditing()
    }

    func splitBlock(id: UUID, atUTF16Offset offset: Int) {
        mutate(affectedBlockIDs: [id], actionName: "拆分块") { document in
            _ = try document.splitBlock(id: id, atUTF16Offset: offset)
        }
        activeBlockID = nil
        activeDraftSource = nil
        activeSelection = nil
    }

    func mergeWithPrevious(id: UUID) {
        mutate(affectedBlockIDs: [id], actionName: "合并块") { document in
            _ = try document.mergeBlockWithPrevious(id: id)
        }
        activeBlockID = nil
        activeDraftSource = nil
        activeSelection = nil
    }

    func handleBoundaryAction(
        _ action: MarkdownEditingBoundaryAction,
        selection: NSRange
    ) {
        guard let activeID = activeBlockID,
              let oldIndex = document.blocks.firstIndex(where: { $0.id == activeID }) else {
            return
        }

        switch action {
        case .splitBlock:
            commitActiveEditing()
            guard document.blocks.indices.contains(oldIndex + 1) else { return }
            beginSourceEditing(
                blockID: document.blocks[oldIndex + 1].id,
                selection: NSRange(location: 0, length: 0)
            )

        case .exitList, .exitQuote:
            exitContainerEditing(
                action,
                blockID: activeID,
                selection: selection
            )

        case .mergeWithPrevious:
            commitActiveEditing()
            guard oldIndex > 0,
                  document.blocks.indices.contains(oldIndex) else { return }
            let previousID = document.blocks[oldIndex - 1].id
            let caret = (document.blocks[oldIndex - 1].source as NSString).length
            mergeWithPrevious(id: document.blocks[oldIndex].id)
            if document.block(id: previousID) != nil {
                beginSourceEditing(
                    blockID: previousID,
                    selection: NSRange(location: caret, length: 0)
                )
            }

        case .navigateToPreviousBlock:
            commitActiveEditing()
            guard oldIndex > 0, document.blocks.indices.contains(oldIndex - 1) else { return }
            let target = document.blocks[oldIndex - 1]
            beginSourceEditing(
                blockID: target.id,
                selection: NSRange(location: (target.source as NSString).length, length: 0)
            )

        case .navigateToNextBlock:
            commitActiveEditing()
            guard document.blocks.indices.contains(oldIndex + 1) else { return }
            beginSourceEditing(
                blockID: document.blocks[oldIndex + 1].id,
                selection: NSRange(location: 0, length: 0)
            )
        }
    }

    private func exitContainerEditing(
        _ action: MarkdownEditingBoundaryAction,
        blockID: UUID,
        selection: NSRange
    ) {
        guard let draft = activeDraftSource,
              let original = document.block(id: blockID) else { return }
        activeBlockID = nil
        activeDraftSource = nil
        activeSelection = nil

        var targetID = blockID
        mutate(affectedBlockIDs: [blockID], actionName: "退出容器") { document in
            _ = try document.replaceBlock(id: blockID, with: draft)
            let remainsInsideQuote = action == .exitList && original.kind == .quote
            if !remainsInsideQuote,
               let retained = document.block(id: blockID),
               retained.kind != .paragraph {
                targetID = try document.insertEmptyParagraph(after: blockID)
            }
        }

        guard let target = document.block(id: targetID) else { return }
        let targetSelection = targetID == blockID
            ? NSRange(
                location: min(selection.location, (target.source as NSString).length),
                length: 0
            )
            : NSRange(location: 0, length: 0)
        beginSourceEditing(blockID: targetID, selection: targetSelection)
    }

    func toggleTask(blockID: UUID, itemIndex: Int) {
        mutate(affectedBlockIDs: [blockID], actionName: "更新任务") { document in
            _ = try document.toggleTask(blockID: blockID, itemIndex: itemIndex)
        }
        Toaster.shared.flash("已更新任务")
    }

    func beginTableEditing(blockID: UUID, cell: MarkdownTableCell?) {
        commitActiveEditing()
        guard let grid = try? document.tableGrid(for: blockID) else { return }
        tableStructureGeneration = tableEditorBridge.beginEditingSession()
        activeTableID = blockID
        tableDraft = grid
        activeTableCell = clampedTableCell(cell ?? .header(0), in: grid)
    }

    func setTableCellFromEditor(
        _ cell: MarkdownTableCell,
        value: String,
        tableID: UUID,
        generation: MarkdownTableStructureGeneration
    ) {
        guard activeTableID == tableID,
              tableStructureGeneration == generation else { return }
        setTableCell(cell, value: value)
    }

    func setTableCell(_ cell: MarkdownTableCell, value: String) {
        guard var grid = tableDraft, let blockID = activeTableID else { return }
        do {
            if cell.row < 0 {
                if grid.header.indices.contains(cell.column),
                   grid.header[cell.column] == value {
                    return
                }
                try grid.setHeader(column: cell.column, value: value)
            } else {
                if grid.rows.indices.contains(cell.row),
                   grid.rows[cell.row].indices.contains(cell.column),
                   grid.rows[cell.row][cell.column] == value {
                    return
                }
                try grid.setCell(row: cell.row, column: cell.column, value: value)
            }
            tableDraft = grid
            commitTableDraft(blockID: blockID, grid: grid, actionName: "编辑表格单元格")
        } catch {
            MVLog.warn("table cell edit failed: \(error)", category: "editor")
        }
    }

    func addTableRow() {
        guard tableDraft != nil, activeTableID != nil else { return }
        tableStructureGeneration =
            tableEditorBridge.flushAndAdvanceStructureGeneration()
        guard var grid = tableDraft, let blockID = activeTableID else { return }
        grid.addRow()
        tableDraft = grid
        activeTableCell = MarkdownTableCell(row: grid.rows.count - 1, column: 0)
        commitTableDraft(blockID: blockID, grid: grid, actionName: "添加表格行")
    }

    func addTableColumn() {
        guard tableDraft != nil, activeTableID != nil else { return }
        tableStructureGeneration =
            tableEditorBridge.flushAndAdvanceStructureGeneration()
        guard var grid = tableDraft, let blockID = activeTableID else { return }
        grid.addColumn()
        tableDraft = grid
        activeTableCell = .header(grid.columnCount - 1)
        commitTableDraft(blockID: blockID, grid: grid, actionName: "添加表格列")
    }

    func deleteActiveTableRow() {
        guard let grid = tableDraft,
              activeTableID != nil,
              let cell = activeTableCell,
              cell.row >= 0,
              grid.rows.indices.contains(cell.row) else { return }
        tableStructureGeneration =
            tableEditorBridge.flushAndAdvanceStructureGeneration()
        guard var grid = tableDraft,
              let blockID = activeTableID,
              grid.deleteRow(at: cell.row) else { return }
        tableDraft = grid
        let nextRow = min(cell.row, max(0, grid.rows.count - 1))
        activeTableCell = grid.rows.isEmpty ? .header(cell.column) : MarkdownTableCell(
            row: nextRow,
            column: min(cell.column, grid.columnCount - 1)
        )
        commitTableDraft(blockID: blockID, grid: grid, actionName: "删除表格行")
    }

    func deleteActiveTableColumn() {
        guard let grid = tableDraft,
              activeTableID != nil,
              let cell = activeTableCell,
              grid.columnCount > 1,
              grid.header.indices.contains(cell.column) else { return }
        tableStructureGeneration =
            tableEditorBridge.flushAndAdvanceStructureGeneration()
        guard var grid = tableDraft,
              let blockID = activeTableID,
              grid.deleteColumn(at: cell.column) else { return }
        tableDraft = grid
        activeTableCell = MarkdownTableCell(
            row: min(cell.row, max(-1, grid.rows.count - 1)),
            column: min(cell.column, grid.columnCount - 1)
        )
        commitTableDraft(blockID: blockID, grid: grid, actionName: "删除表格列")
    }

    func cycleActiveTableAlignment() {
        tableEditorBridge.flushForLifecycleBoundary()
        guard var grid = tableDraft,
              let blockID = activeTableID,
              let column = activeTableCell?.column else { return }
        do {
            _ = try grid.cycleAlignment(at: column)
            tableDraft = grid
            commitTableDraft(blockID: blockID, grid: grid, actionName: "表格对齐")
        } catch {
            MVLog.warn("table alignment failed: \(error)", category: "editor")
        }
    }

    func finishTableEditing() {
        tableStructureGeneration = tableEditorBridge.finishEditingSession()
        activeTableID = nil
        tableDraft = nil
        activeTableCell = nil
    }

    // MARK: - Visible-text find and replace

    func search(_ options: BlockFindOptions) {
        findOptions = options
        refreshFind(preservingCurrent: false)
    }

    func navigateFind(_ delta: Int) {
        guard let next = findResult.wrappedIndex(from: currentFindIndex, delta: delta) else {
            currentFindIndex = 0
            return
        }
        currentFindIndex = next
    }

    @discardableResult
    func replaceCurrentFind(with template: String) -> Int {
        guard findResult.error == nil,
              findResult.matches.indices.contains(currentFindIndex) else { return 0 }
        let match = findResult.matches[currentFindIndex]

        if match.blockID == activeBlockID {
            return replaceActiveSourceMatches(
                [match],
                with: template,
                actionName: "替换",
                advanceAfterReplacement: true
            )
        }

        let editingToRestore = findEditingStateForRestoration()
        commitActiveEditing()
        var replacementDocument = document
        do {
            _ = try BlockFindEngine.replace(
                match,
                with: template,
                in: &replacementDocument
            )
        } catch {
            MVLog.warn("find replacement failed: \(error)", category: "find")
            restoreEditingState(editingToRestore)
            refreshFind(preservingCurrent: true)
            return 0
        }
        mutate(affectedBlockIDs: [match.blockID], actionName: "替换") { document in
            document = replacementDocument
        }
        restoreEditingState(editingToRestore)
        refreshFind(preservingCurrent: true)
        advanceFind(after: match, replacement: match.expandedReplacement(for: template))
        return 1
    }

    @discardableResult
    func replaceAllFind(with template: String) -> Int {
        let snapshot = findResult
        guard snapshot.error == nil, !snapshot.matches.isEmpty else { return 0 }
        var replacementCount = 0

        let activeSourceMatches = activeBlockID.map { activeID in
            snapshot.matches.filter { $0.blockID == activeID }
        } ?? []
        if !activeSourceMatches.isEmpty {
            replacementCount += replaceActiveSourceMatches(
                activeSourceMatches,
                with: template,
                actionName: "全部替换",
                advanceAfterReplacement: false
            )
        }

        let remaining = BlockFindResult(
            matches: snapshot.matches.filter { match in
                !activeSourceMatches.contains(match)
            },
            error: nil
        )
        guard !remaining.matches.isEmpty else {
            refreshFind(preservingCurrent: false)
            return replacementCount
        }

        let editingToRestore = findEditingStateForRestoration()
        commitActiveEditing()
        let affected = Set(remaining.matches.map(\.blockID))
        mutate(affectedBlockIDs: affected, actionName: "全部替换") { document in
            replacementCount += try BlockFindEngine.replaceAll(
                remaining,
                with: template,
                in: &document
            )
        }
        restoreEditingState(editingToRestore)
        refreshFind(preservingCurrent: false)
        return replacementCount
    }

    var currentFindMatch: BlockFindMatch? {
        findResult.matches.indices.contains(currentFindIndex)
            ? findResult.matches[currentFindIndex]
            : nil
    }

    var currentFindTableCell: MarkdownTableCell? {
        currentFindMatch?.tableCell.map {
            MarkdownTableCell(row: $0.row, column: $0.column)
        }
    }

    var currentFindTableRange: NSRange? {
        currentFindMatch?.tableCell?.range
    }

    func tableCellHasFindMatch(
        blockID: UUID,
        cell: MarkdownTableCell,
        currentOnly: Bool = false
    ) -> Bool {
        let matches = currentOnly
            ? currentFindMatch.map { [$0] } ?? []
            : findMatches(for: blockID)
        return matches.contains { match in
            guard match.blockID == blockID, let target = match.tableCell else { return false }
            return target.row == cell.row && target.column == cell.column
        }
    }

    func findMatches(for blockID: UUID) -> [BlockFindMatch] {
        findResult.matches.filter { $0.blockID == blockID }
    }

    private func replaceActiveSourceMatches(
        _ matches: [BlockFindMatch],
        with template: String,
        actionName: String,
        advanceAfterReplacement: Bool
    ) -> Int {
        guard let blockID = activeBlockID,
              !matches.isEmpty,
              matches.allSatisfy({ $0.blockID == blockID }),
              let originalBlock = document.block(id: blockID),
              let draft = sourceEditorBridge.snapshot()?.source ?? activeDraftSource else {
            return 0
        }
        let draftBlock = MarkdownBlock(
            id: originalBlock.id,
            kind: originalBlock.kind,
            source: draft,
            leadingTrivia: originalBlock.leadingTrivia
        )
        let replacementSource: String
        do {
            replacementSource = try BlockFindEngine.replacementSource(
                for: matches,
                with: template,
                in: draftBlock
            )
        } catch {
            MVLog.warn("active source find replacement failed: \(error)", category: "find")
            return 0
        }

        let selection: NSRange
        if matches.count == 1, let match = matches.first {
            selection = NSRange(
                location: match.sourceRange.location,
                length: match.expandedReplacement(for: template).utf16.count
            )
        } else {
            selection = NSRange(
                location: min(
                    activeSelection?.location ?? 0,
                    (replacementSource as NSString).length
                ),
                length: 0
            )
        }

        activeDraftSource = replacementSource
        activeSelection = selection
        _ = sourceEditorBridge.applyFindReplacement(
            source: replacementSource,
            selection: selection
        )
        mutate(affectedBlockIDs: [blockID], actionName: actionName) { document in
            _ = try document.replaceBlock(id: blockID, with: replacementSource)
        }

        if document.block(id: blockID)?.source != replacementSource {
            activeBlockID = nil
            activeDraftSource = nil
            activeSelection = nil
        }
        refreshFind(preservingCurrent: matches.count == 1)
        if advanceAfterReplacement, let match = matches.first {
            advanceFind(
                after: match,
                replacement: match.expandedReplacement(for: template)
            )
        }
        return matches.count
    }

    private func advanceFind(
        after replacedMatch: BlockFindMatch,
        replacement: String
    ) {
        guard !findResult.matches.isEmpty else {
            currentFindIndex = 0
            return
        }
        let afterEnd = replacedMatch.sourceRange.location + replacement.utf16.count
        currentFindIndex = findResult.matches.firstIndex { match in
            match.blockIndex > replacedMatch.blockIndex
                || (match.blockIndex == replacedMatch.blockIndex
                    && match.sourceRange.location >= afterEnd)
        } ?? 0
    }

    private func findEditingStateForRestoration() -> SuspendedEditingState? {
        if let blockID = activeBlockID {
            return .source(
                blockID: blockID,
                selection: sourceEditorBridge.snapshot()?.selection ?? activeSelection
            )
        }
        if let blockID = activeTableID {
            return .table(
                blockID: blockID,
                cell: tableEditorBridge.snapshot()?.cell
                    ?? activeTableCell
                    ?? .header(0)
            )
        }
        return nil
    }

    private func restoreEditingState(_ state: SuspendedEditingState?) {
        guard let state else { return }
        switch state {
        case let .source(blockID, selection):
            guard document.block(id: blockID) != nil else { return }
            beginSourceEditing(blockID: blockID, selection: selection)
        case let .table(blockID, cell):
            guard let grid = try? document.tableGrid(for: blockID) else { return }
            beginTableEditing(
                blockID: blockID,
                cell: clampedTableCell(cell, in: grid)
            )
        }
    }

    private func refreshFind(preservingCurrent: Bool) {
        guard !findOptions.query.isEmpty else {
            if !findResult.matches.isEmpty || findResult.error != nil {
                findResult = BlockFindResult(matches: [], error: nil)
            }
            currentFindIndex = 0
            return
        }
        let previous = currentFindIndex
        var options = findOptions
        options.activeSourceBlockID = activeBlockID
        options.activeTableBlockID = activeTableID
        var blocks = document.blocks
        if let activeID = activeBlockID,
           let draft = activeDraftSource,
           let index = blocks.firstIndex(where: { $0.id == activeID }) {
            let block = blocks[index]
            blocks[index] = MarkdownBlock(
                id: block.id,
                kind: block.kind,
                source: draft,
                leadingTrivia: block.leadingTrivia
            )
        }
        if let tableID = activeTableID,
           var grid = tableDraft,
           let index = blocks.firstIndex(where: { $0.id == tableID }) {
            if let live = tableEditorBridge.snapshot() {
                _ = applying(live.value, to: live.cell, in: &grid)
            }
            let block = blocks[index]
            blocks[index] = MarkdownBlock(
                id: block.id,
                kind: block.kind,
                source: grid.serialized(),
                leadingTrivia: block.leadingTrivia
            )
        }
        findResult = BlockFindEngine.search(in: blocks, options: options)
        if findResult.matches.isEmpty {
            currentFindIndex = 0
        } else if preservingCurrent {
            currentFindIndex = min(previous, findResult.matches.count - 1)
        } else {
            currentFindIndex = 0
        }
    }

    func moveTableFocus(forward: Bool, vertical: Bool = false) {
        tableEditorBridge.flushForLifecycleBoundary()
        guard var grid = tableDraft,
              let blockID = activeTableID,
              let current = activeTableCell else { return }
        let columns = grid.columnCount
        var row = current.row
        var column = current.column

        if vertical {
            row += 1
            if row >= grid.rows.count {
                grid.addRow()
                tableDraft = grid
                commitTableDraft(blockID: blockID, grid: grid, actionName: "添加表格行")
            }
        } else if forward {
            column += 1
            if column >= columns {
                column = 0
                row += 1
                if row >= grid.rows.count {
                    grid.addRow()
                    tableDraft = grid
                    commitTableDraft(blockID: blockID, grid: grid, actionName: "添加表格行")
                }
            }
        } else {
            column -= 1
            if column < 0 {
                if row > -1 {
                    row -= 1
                    column = columns - 1
                } else {
                    column = 0
                }
            }
        }
        activeTableCell = MarkdownTableCell(row: max(-1, row), column: column)
    }

    private func commitTableDraft(
        blockID: UUID,
        grid: MarkdownTableGrid,
        actionName: String
    ) {
        mutate(affectedBlockIDs: [blockID], actionName: actionName) { document in
            try document.replaceTable(blockID: blockID, with: grid)
        }
    }

    private func applying(
        _ value: String,
        to cell: MarkdownTableCell,
        in grid: inout MarkdownTableGrid
    ) -> MarkdownTableGrid? {
        do {
            if cell.row < 0 {
                try grid.setHeader(column: cell.column, value: value)
            } else {
                try grid.setCell(row: cell.row, column: cell.column, value: value)
            }
            return grid
        } catch {
            return nil
        }
    }

    private func mutate(
        affectedBlockIDs: Set<UUID>,
        actionName: String,
        operation: (inout MarkdownDocument) throws -> Void
    ) {
        let before = document
        do {
            try operation(&document)
        } catch {
            MVLog.warn("block mutation failed: \(error)", category: "editor")
            return
        }
        guard document != before else { return }
        registerUndo(from: document, to: before, actionName: actionName)
        recordMutation(affectedBlockIDs: affectedBlockIDs)
        onDocumentChange(document)
        refreshFind(preservingCurrent: true)
    }

    private func registerUndo(
        from current: MarkdownDocument,
        to previous: MarkdownDocument,
        actionName: String
    ) {
        undoManager.registerUndo(withTarget: self) { target in
            let now = target.document
            let affectedBlockIDs = target.changedBlockIDs(from: now, to: previous)
            target.document = previous
            target.recordMutation(affectedBlockIDs: affectedBlockIDs)
            target.resynchronizeActiveSourceDraftAfterHistoryMutation()
            target.resynchronizeTableDraftAfterHistoryMutation()
            target.onDocumentChange(previous)
            target.refreshFind(preservingCurrent: true)
            target.registerUndo(from: previous, to: now, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }

    private func resynchronizeActiveSourceDraftAfterHistoryMutation() {
        guard let blockID = activeBlockID else { return }
        guard let block = document.block(id: blockID) else {
            activeBlockID = nil
            activeDraftSource = nil
            activeSelection = nil
            return
        }
        let length = (block.source as NSString).length
        let location = min(activeSelection?.location ?? length, length)
        let selection = NSRange(location: location, length: 0)
        activeDraftSource = block.source
        activeSelection = selection
        _ = sourceEditorBridge.applyFindReplacement(
            source: block.source,
            selection: selection
        )
    }

    private func resynchronizeTableDraftAfterHistoryMutation() {
        guard let blockID = activeTableID else { return }
        guard let grid = try? document.tableGrid(for: blockID) else {
            tableStructureGeneration = tableEditorBridge.discardEditingSession()
            activeTableID = nil
            tableDraft = nil
            activeTableCell = nil
            return
        }
        // The restored history snapshot is authoritative here.
        // Invalidate the old field without flushing its coordinate into the restored grid.
        tableStructureGeneration =
            tableEditorBridge.advanceStructureGenerationDiscardingActiveEditor()
        tableDraft = grid
        activeTableCell = clampedTableCell(
            activeTableCell ?? .header(0),
            in: grid
        )
    }

    private func clampedTableCell(
        _ cell: MarkdownTableCell,
        in grid: MarkdownTableGrid
    ) -> MarkdownTableCell {
        let column = min(max(0, cell.column), grid.columnCount - 1)
        let row: Int
        if cell.row < 0 || grid.rows.isEmpty {
            row = -1
        } else {
            row = min(cell.row, grid.rows.count - 1)
        }
        return MarkdownTableCell(row: row, column: column)
    }

    private func changedBlockIDs(
        from current: MarkdownDocument,
        to replacement: MarkdownDocument
    ) -> Set<UUID> {
        let currentByID = Dictionary(uniqueKeysWithValues: current.blocks.map { ($0.id, $0) })
        let replacementByID = Dictionary(uniqueKeysWithValues: replacement.blocks.map { ($0.id, $0) })
        return Set(currentByID.keys).union(replacementByID.keys).filter { id in
            currentByID[id] != replacementByID[id]
        }
    }

    private func recordMutation(affectedBlockIDs: Set<UUID>) {
        parseCount += 1
        localMutationCount += 1
        for id in affectedBlockIDs {
            renderRevisionByBlock[id, default: 0] += 1
        }
    }
}
