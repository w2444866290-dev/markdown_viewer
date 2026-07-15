import CoreFoundation
import Foundation
import Testing
@testable import MarkdownViewer

@Suite(.serialized)
@MainActor
struct BlockEditorPerformanceTests {
    @Test("large document edit reparses and rerenders only the local block")
    func largeDocumentLocalEdit() throws {
        let source = (0..<4_000)
            .map { "Paragraph \($0) with **formatting** and value \($0)." }
            .joined(separator: "\n\n")
        let document = MarkdownDocument(source: source)
        #expect(document.blocks.count == 4_000)
        let originalIDs = document.blocks.map(\.id)
        let targetIndex = 2_000
        let targetID = originalIDs[targetIndex]
        let store = BlockEditorStore(tabID: UUID(), document: document) { _ in }

        let start = CFAbsoluteTimeGetCurrent()
        store.beginSourceEditing(blockID: targetID)
        store.updateActiveDraft("Paragraph 2000 changed locally.")
        store.commitActiveEditing()
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        #expect(store.document.blocks.count == 4_000)
        #expect(store.document.blocks[targetIndex].id == targetID)
        #expect(store.document.blocks[targetIndex - 1].id == originalIDs[targetIndex - 1])
        #expect(store.document.blocks[targetIndex + 1].id == originalIDs[targetIndex + 1])
        #expect(store.parseCount == 2)
        #expect(store.localMutationCount == 1)
        #expect(store.renderRevisionByBlock.count == 1)
        #expect(store.renderRevisionByBlock[targetID] == 1)
        #expect(elapsed < 2.0)
    }

    @Test("large document undo and redo invalidate only the changed block")
    func largeDocumentLocalUndoAndRedo() throws {
        let source = (0..<4_000)
            .map { "Paragraph \($0)." }
            .joined(separator: "\n\n")
        let document = MarkdownDocument(source: source)
        let targetID = try #require(document.blocks[safe: 2_000]?.id)
        let previousID = try #require(document.blocks[safe: 1_999]?.id)
        let nextID = try #require(document.blocks[safe: 2_001]?.id)
        let store = BlockEditorStore(tabID: UUID(), document: document) { _ in }

        store.beginSourceEditing(blockID: targetID)
        store.updateActiveDraft("Paragraph 2000 changed locally.")
        store.commitActiveEditing()
        #expect(store.renderRevisionByBlock == [targetID: 1])

        store.undoManager.undo()
        #expect(store.source == source)
        #expect(store.renderRevisionByBlock[targetID] == 2)
        #expect(store.renderRevisionByBlock[previousID] == nil)
        #expect(store.renderRevisionByBlock[nextID] == nil)
        #expect(store.renderRevisionByBlock.count == 1)

        store.undoManager.redo()
        #expect(store.source.contains("Paragraph 2000 changed locally."))
        #expect(store.renderRevisionByBlock[targetID] == 3)
        #expect(store.renderRevisionByBlock[previousID] == nil)
        #expect(store.renderRevisionByBlock[nextID] == nil)
        #expect(store.renderRevisionByBlock.count == 1)
    }

    @Test("large visible-text search stays bounded and does not mutate the document")
    func largeDocumentFind() {
        let source = (0..<4_000)
            .map { "Row \($0) contains searchable text and `code-\($0)`." }
            .joined(separator: "\n\n")
        let document = MarkdownDocument(source: source)
        let start = CFAbsoluteTimeGetCurrent()
        let result = BlockFindEngine.search(
            in: document,
            options: BlockFindOptions(query: "searchable text")
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        #expect(result.matches.count == 4_000)
        #expect(document.source == source)
        #expect(elapsed < 3.0)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
