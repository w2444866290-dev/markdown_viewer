import Foundation
import Testing
@testable import MarkdownViewer

@MainActor
struct DebugDiagnosticSnapshotTests {
    @Test
    func staleMarkdownSurfaceCannotPublishAfterTabSwitch() {
        let markdownID = UUID()
        let plainSourceID = UUID()

        #expect(DebugDiagnosticPublicationPolicy.allowsPublication(
            mountedDocumentID: markdownID,
            activeDocumentID: markdownID
        ))
        #expect(!DebugDiagnosticPublicationPolicy.allowsPublication(
            mountedDocumentID: markdownID,
            activeDocumentID: plainSourceID
        ))
        #expect(!DebugDiagnosticPublicationPolicy.allowsPublication(
            mountedDocumentID: markdownID,
            activeDocumentID: nil
        ))
    }

    @Test
    func writerPersistsStructuredStateAndPerBlockRenderCounts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownViewerDiagnosticTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = root.appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = DebugDiagnosticWriter(fileURL: fileURL, writeDelay: 3_600)
        let activeBlockID = UUID()
        let otherBlockID = UUID()
        writer.update(snapshot(blockID: activeBlockID))
        writer.recordBlockRender(activeBlockID)
        writer.recordBlockRender(activeBlockID)
        writer.recordBlockRender(otherBlockID)
        try writer.flush()

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(
            DebugDiagnosticSnapshot.self,
            from: Data(contentsOf: fileURL)
        )
        #expect(persisted.document == "fixture.md")
        #expect(persisted.selection == DebugDiagnosticSelection(location: 4, length: 2))
        #expect(persisted.renderedBlockUpdateCount == 3)
        #expect(persisted.activeBlockRenderUpdateCount == 2)
        #expect(persisted.renderedBlockUpdates[activeBlockID.uuidString] == 2)
        #expect(persisted.renderedBlockUpdates[otherBlockID.uuidString] == 1)
        #expect(!persisted.visual.documentVisible)
    }

    @Test
    func nonMarkdownSurfacesReplaceTheLastMarkdownSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownViewerDiagnosticSurfaceTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = root.appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = DebugDiagnosticWriter(fileURL: fileURL, writeDelay: 3_600)
        let renderedBlockID = UUID()
        writer.update(snapshot(blockID: renderedBlockID))
        writer.recordBlockRender(renderedBlockID)
        writer.update(.plainSource(
            document: "config.yaml",
            selection: NSRange(location: 7, length: 3),
            dirty: false,
            find: emptyFindState(),
            scrollY: 24,
            sessionPath: "/tmp/plain-session.json"
        ))
        try writer.flush()

        var persisted = try decode(from: fileURL)
        #expect(persisted.document == "config.yaml")
        #expect(persisted.mode == "source")
        #expect(persisted.blockID == nil)
        #expect(persisted.blockType == nil)
        #expect(persisted.selection == DebugDiagnosticSelection(location: 7, length: 3))
        #expect(persisted.outline == DebugDiagnosticOutlineState(headingCount: 0, activeIndex: 0))
        #expect(persisted.renderedBlockUpdateCount == 1)

        writer.update(.emptyWorkspace(
            find: emptyFindState(),
            sessionPath: "/tmp/empty-session.json"
        ))
        try writer.flush()

        persisted = try decode(from: fileURL)
        #expect(persisted.document.isEmpty)
        #expect(persisted.mode == "empty")
        #expect(persisted.blockID == nil)
        #expect(persisted.blockType == nil)
        #expect(persisted.selection == nil)
        #expect(!persisted.dirty)
        #expect(persisted.scrollY == 0)
        #expect(persisted.renderedBlockUpdateCount == 1)
    }

    @Test
    func writerPublishesMeasuredVisualStateAndRemovesDisappearedAnchors() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownViewerDiagnosticVisualTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = root.appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = DebugDiagnosticWriter(fileURL: fileURL, writeDelay: 3_600)
        writer.update(snapshot(blockID: UUID()))
        writer.updateVisualState(
            documentVisible: true,
            sidebarVisible: true,
            paletteVisible: false,
            palettePresentation: PalettePresentationMode.inlinePassive.rawValue,
            findPanelVisible: false,
            replaceRowVisible: false,
            previewActive: false
        )
        writer.updateVisualAnchor(
            "source-editor-frame",
            frame: CGRect(x: 12, y: 34, width: 640, height: 48)
        )
        try writer.flush()

        var persisted = try decode(from: fileURL)
        #expect(persisted.visual.documentVisible)
        #expect(persisted.visual.sidebarVisible)
        #expect(persisted.visual.palettePresentation == "inline-passive")
        #expect(persisted.visual.sourceEditorVisible)
        #expect(persisted.visual.anchors["source-editor-frame"] == DebugDiagnosticRect(
            CGRect(x: 12, y: 34, width: 640, height: 48)
        ))

        writer.updateVisualAnchor("source-editor-frame", frame: nil)
        try writer.flush()
        persisted = try decode(from: fileURL)
        #expect(!persisted.visual.sourceEditorVisible)
        #expect(persisted.visual.anchors["source-editor-frame"] == nil)
    }

    private func decode(from fileURL: URL) throws -> DebugDiagnosticSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            DebugDiagnosticSnapshot.self,
            from: Data(contentsOf: fileURL)
        )
    }

    private func emptyFindState() -> DebugDiagnosticFindState {
        DebugDiagnosticFindState(
            query: "",
            display: "",
            matchCount: 0,
            currentIndex: 0,
            invalidRegex: false,
            replaceExpanded: false,
            caseSensitive: false,
            wholeWord: false,
            regex: false
        )
    }

    private func snapshot(blockID: UUID) -> DebugDiagnosticSnapshot {
        DebugDiagnosticSnapshot(
            schemaVersion: 1,
            document: "fixture.md",
            blockID: blockID.uuidString,
            blockType: "paragraph",
            mode: "edit",
            selection: DebugDiagnosticSelection(location: 4, length: 2),
            activeTableCell: nil,
            dirty: true,
            find: DebugDiagnosticFindState(
                query: "fixture",
                display: "1/1",
                matchCount: 1,
                currentIndex: 0,
                invalidRegex: false,
                replaceExpanded: false,
                caseSensitive: false,
                wholeWord: false,
                regex: false
            ),
            outline: DebugDiagnosticOutlineState(headingCount: 2, activeIndex: 0),
            scrollY: 12,
            sessionPath: "/tmp/session.json",
            parseCount: 1,
            localMutationCount: 0,
            renderedBlockUpdateCount: 0,
            activeBlockRenderUpdateCount: 0,
            renderedBlockUpdates: [:],
            visual: .empty,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
