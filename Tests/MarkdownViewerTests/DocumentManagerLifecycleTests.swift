import Combine
import Foundation
import Testing
@testable import MarkdownViewer

@MainActor
@Suite(.serialized)
struct DocumentManagerLifecycleTests {
    @Test
    func newMarkdownDocumentRequestsImmediateFirstBlockEditing() throws {
        try withTemporaryRoot { root in
            let manager = makeManager(root)
            manager.newDocument()
            let tab = try #require(manager.activeTab)
            let store = manager.blockEditorStore(for: tab)

            #expect(store.activeBlockID == store.document.blocks.first?.id)
            #expect(store.activeSelection == NSRange(location: 0, length: 0))
            #expect(tab.isDirty)
        }
    }

    @Test
    func newMarkdownDocumentLeavesPreviewAndRequestsImmediateEditing() throws {
        try withTemporaryRoot { root in
            let manager = makeManager(root)
            manager.newDocument(text: "# Existing")
            manager.togglePreviewMode()
            #expect(manager.previewMode)

            manager.newDocument()
            let tab = try #require(manager.activeTab)
            let store = manager.blockEditorStore(for: tab)

            #expect(!manager.previewMode)
            #expect(store.activeBlockID == store.document.blocks.first?.id)
            #expect(store.activeSelection == NSRange(location: 0, length: 0))
        }
    }

    @Test
    func untitledNamesStayUniqueAcrossSavedAndUnsavedTabs() throws {
        try withTemporaryRoot { root in
            let manager = makeManager(root)
            manager.openTab(
                for: root.appendingPathComponent("未命名.md"),
                text: "saved"
            )

            manager.newDocument()
            manager.newDocument()
            manager.newDocument()

            #expect(manager.tabs.map(\.name) == [
                "未命名.md",
                "未命名 2.md",
                "未命名 3.md",
                "未命名 4.md",
            ])
            #expect(Set(manager.tabs.map(\.name)).count == manager.tabs.count)
        }
    }

    @Test
    func canonicalAndSymlinkPathsActivateOneExistingTab() throws {
        try withTemporaryRoot { root in
            let manager = makeManager(root)
            let notes = root.appendingPathComponent("notes.md")
            let alias = root.appendingPathComponent("alias.md")
            try Data("disk".utf8).write(to: notes)
            try FileManager.default.createSymbolicLink(
                at: alias,
                withDestinationURL: notes
            )

            manager.openTab(for: notes, text: "first snapshot")
            let originalID = try #require(manager.activeTabID)
            manager.openTab(for: alias, text: "must not replace")

            #expect(manager.tabs.count == 1)
            #expect(manager.activeTabID == originalID)
            #expect(manager.activeTab?.text == "first snapshot")
            #expect(manager.activeTab?.url == notes)
        }
    }

    @Test
    func visualFixtureWorkspaceRowReusesURLlessTabAndTracksDirtyState() throws {
        try withTemporaryRoot { root in
            let manager = DocumentManager(
                sessionURL: root.appendingPathComponent("session.json"),
                sessionSaveDelay: 3_600,
                visualTestEnabled: true
            )
            let fixtureName = "格式示例.md"
            let workspaceFile = root.appendingPathComponent(fixtureName)
            try Data("workspace copy".utf8).write(to: workspaceFile)
            let node = FileNode(
                url: workspaceFile,
                name: fixtureName,
                isDirectory: false
            )
            manager.loadVisualTestDocument(
                name: fixtureName,
                text: "# In-memory fixture",
                scrollY: 0
            )
            let fixtureID = try #require(manager.activeTabID)

            #expect(manager.isActiveFileNode(node))
            #expect(!manager.fileNodeHasDirtyTab(node))

            manager.markActiveDirty()
            #expect(manager.fileNodeHasDirtyTab(node))

            manager.openFileNode(node)

            #expect(manager.tabs.count == 1)
            #expect(manager.activeTabID == fixtureID)
            #expect(manager.activeTab?.url == nil)
            #expect(manager.activeTab?.text == "# In-memory fixture")
        }
    }

    @Test
    func restoredVisualFixtureRebindsWorkspaceRowWithoutLosingSessionState() throws {
        try withTemporaryRoot { root in
            let workspace = root.appendingPathComponent("Workspace", isDirectory: true)
            let docs = workspace.appendingPathComponent("docs", isDirectory: true)
            try FileManager.default.createDirectory(
                at: docs,
                withIntermediateDirectories: true
            )
            let fixtureName = "格式示例.md"
            let workspaceFile = docs.appendingPathComponent(fixtureName)
            try Data("# Pristine workspace copy".utf8).write(to: workspaceFile)

            var document = MarkdownDocument(source: "# Restored unsaved fixture")
            let headingID = try #require(document.blocks.first?.id)
            _ = try document.replaceBlock(
                id: headingID,
                with: "# Restored unsaved fixture edited"
            )
            let fixtureTab = DocumentTab(
                url: nil,
                name: fixtureName,
                text: document.source,
                isDirty: true,
                scrollY: 1_734.5,
                markdownDocument: document
            )
            let draftTab = DocumentTab(
                url: nil,
                name: "未命名 2.md",
                text: "draft",
                isDirty: true,
                selectionLocation: 5
            )
            let session = Session(
                tabs: [fixtureTab, draftTab],
                activeTabID: draftTab.id,
                fontIndex: 2,
                sidebarWidth: 312,
                sidebarOpen: false,
                directoryPath: workspace.path,
                expandedFolderPaths: []
            )
            let manager = DocumentManager(
                sessionURL: root.appendingPathComponent("session.json"),
                sessionSaveDelay: 3_600,
                visualTestEnabled: true
            )

            manager.restoreVisualTestSession(
                from: session,
                fixtureName: fixtureName
            )

            let node = FileNode(
                url: workspaceFile,
                name: fixtureName,
                isDirectory: false
            )
            #expect(manager.tabs.map(\.id) == [fixtureTab.id, draftTab.id])
            #expect(manager.activeTabID == draftTab.id)
            #expect(manager.activeTab?.text == "draft")
            let restoredFixture = try #require(
                manager.tabs.first { $0.id == fixtureTab.id }
            )
            #expect(restoredFixture.text == document.source)
            #expect(restoredFixture.isDirty == true)
            #expect(restoredFixture.scrollY == 1_734.5)
            #expect(restoredFixture.markdownDocument?.blocks.map(\.id)
                    == document.blocks.map(\.id))
            #expect(manager.fontIndex == 2)
            #expect(manager.sidebarWidth == 312)
            #expect(manager.sidebarOpen == false)
            #expect(manager.expandedFolders.isEmpty)
            #expect(!manager.isActiveFileNode(node))
            #expect(manager.fileNodeHasDirtyTab(node))

            manager.openFileNode(node)

            #expect(manager.tabs.map(\.id) == [fixtureTab.id, draftTab.id])
            #expect(manager.activeTabID == fixtureTab.id)
            #expect(manager.activeTab?.url == nil)
            #expect(manager.activeTab?.text == document.source)
        }
    }

    @Test
    func dirtyCloseRequiresConfirmationAndReopenKeepsLiveState() throws {
        try withTemporaryRoot { root in
            let manager = makeManager(root)
            manager.openTab(for: root.appendingPathComponent("a.md"), text: "a")
            manager.newDocument(text: "old draft")
            let dirtyID = try #require(manager.activeTabID)
            manager.openTab(for: root.appendingPathComponent("c.md"), text: "c")
            manager.activateTab(dirtyID)
            manager.pullActiveText = { "latest unsaved draft" }
            manager.pullActiveScrollY = { 388.5 }
            manager.pullActiveSelection = { NSRange(location: 7, length: 8) }

            var staleCleanValue = try #require(manager.activeTab)
            staleCleanValue.isDirty = false
            manager.requestClose(staleCleanValue)

            #expect(manager.tabs.count == 3)
            #expect(manager.confirmingCloseTabID == dirtyID)

            manager.requestClose(staleCleanValue)

            #expect(manager.tabs.count == 2)
            #expect(manager.activeTab?.name == "c.md")
            #expect(manager.lastClosedTab?.id == dirtyID)
            #expect(manager.lastClosedTab?.text == "latest unsaved draft")
            #expect(manager.lastClosedTab?.scrollY == 388.5)
            #expect(manager.lastClosedTab?.selectionRange == NSRange(location: 7, length: 8))
            #expect(manager.lastClosedTab?.isDirty == true)

            manager.reopenClosed()

            #expect(manager.activeTabID == dirtyID)
            #expect(manager.activeTab?.text == "latest unsaved draft")
            #expect(manager.activeTab?.scrollY == 388.5)
            #expect(manager.activeTab?.selectionRange == NSRange(location: 7, length: 8))
            #expect(manager.activeTab?.isDirty == true)
            #expect(manager.lastClosedTab == nil)
        }
    }

    @Test
    func liveBlockDraftMarksCleanSavedTabDirtyBeforeCommit() throws {
        try withTemporaryRoot { root in
            let manager = makeManager(root)
            manager.openTab(
                for: root.appendingPathComponent("saved.md"),
                text: "before"
            )
            let tab = try #require(manager.activeTab)
            let store = manager.blockEditorStore(for: tab)
            let blockID = try #require(store.document.blocks.first?.id)

            store.beginSourceEditing(blockID: blockID)
            store.updateActiveDraft("before", selection: NSRange(location: 1, length: 0))
            #expect(manager.activeTab?.isDirty == false)

            store.updateActiveDraft("after", selection: NSRange(location: 2, length: 0))

            #expect(manager.activeTab?.isDirty == true)
            #expect(manager.activeTab?.text == "before")
            #expect(store.source == "before")
            #expect(store.activeBlockID == blockID)
        }
    }

    @Test
    func activeBlockDraftIsReconciledBeforeCloseDecision() throws {
        try withTemporaryRoot { root in
            let manager = makeManager(root)
            manager.openTab(
                for: root.appendingPathComponent("saved.md"),
                text: "before"
            )
            let cleanTab = try #require(manager.activeTab)
            let store = manager.blockEditorStore(for: cleanTab)
            let blockID = try #require(store.document.blocks.first?.id)
            store.beginSourceEditing(blockID: blockID)
            store.updateActiveDraft("after", selection: NSRange(location: 5, length: 0))

            let activeIndex = try #require(manager.activeIdx)
            manager.tabs[activeIndex].isDirty = false
            manager.requestClose(cleanTab)

            #expect(manager.tabs.count == 1)
            #expect(manager.confirmingCloseTabID == cleanTab.id)
            #expect(manager.activeTab?.isDirty == true)
            #expect(manager.activeTab?.text == "after")
            #expect(manager.activeTab?.selectionRange == NSRange(location: 5, length: 0))
            #expect(store.source == "after")
            #expect(store.activeBlockID == nil)

            manager.requestClose(cleanTab)

            #expect(manager.tabs.isEmpty)
            #expect(manager.lastClosedTab?.text == "after")
            #expect(manager.lastClosedTab?.isDirty == true)
        }
    }

    @Test
    func switchingBackToMarkdownTabRestoresEditedBlockAndSourceSelection() throws {
        try withTemporaryRoot { root in
            let manager = makeManager(root)
            manager.openTab(
                for: root.appendingPathComponent("first.md"),
                text: "# Heading\n\nSecond block"
            )
            let firstTab = try #require(manager.activeTab)
            let store = manager.blockEditorStore(for: firstTab)
            let blockID = try #require(store.document.blocks.last?.id)
            let selection = NSRange(location: 3, length: 6)
            store.beginSourceEditing(blockID: blockID)
            store.updateActiveDraft("Second edited block", selection: selection)

            manager.openTab(
                for: root.appendingPathComponent("other.md"),
                text: "Other"
            )

            #expect(store.activeBlockID == nil)
            #expect(store.source == "# Heading\n\nSecond edited block")

            manager.activateTab(firstTab.id)

            #expect(store.activeBlockID == blockID)
            #expect(store.activeSelection == selection)
            #expect(store.activeBlock?.source == "Second edited block")
        }
    }

    @Test
    func activatingTheCurrentTabDoesNotCommitOrDropItsSourceSelection() throws {
        try withTemporaryRoot { root in
            let manager = makeManager(root)
            manager.openTab(
                for: root.appendingPathComponent("current.md"),
                text: "Current block"
            )
            let tab = try #require(manager.activeTab)
            let store = manager.blockEditorStore(for: tab)
            let blockID = try #require(store.document.blocks.first?.id)
            let selection = NSRange(location: 2, length: 4)
            store.beginSourceEditing(blockID: blockID)
            store.updateActiveDraft("Current edited block", selection: selection)

            manager.activateTab(tab.id)

            #expect(store.activeBlockID == blockID)
            #expect(store.activeSelection == selection)
            #expect(store.source == "Current block")
            #expect(store.snapshotDocument().source == "Current edited block")
        }
    }

    @Test
    func switchingBackToMarkdownTabRestoresTableAndFocusedCell() throws {
        try withTemporaryRoot { root in
            let manager = makeManager(root)
            manager.openTab(
                for: root.appendingPathComponent("table.md"),
                text: "| Name | Value |\n| --- | --- |\n| old | before |"
            )
            let tableTab = try #require(manager.activeTab)
            let store = manager.blockEditorStore(for: tableTab)
            let tableID = try #require(store.document.blocks.first?.id)
            let cell = MarkdownTableCell(row: 0, column: 1)
            store.beginTableEditing(blockID: tableID, cell: cell)
            store.setTableCell(cell, value: "after")

            manager.openTab(
                for: root.appendingPathComponent("other.md"),
                text: "Other"
            )

            #expect(store.activeTableID == nil)
            #expect(store.activeTableCell == nil)

            manager.activateTab(tableTab.id)

            #expect(store.activeTableID == tableID)
            #expect(store.activeTableCell == cell)
            #expect(store.tableDraft?.rows.first?[1] == "after")
        }
    }

    @Test
    func cleanCloseUsesRightThenLeftAdjacency() throws {
        try withTemporaryRoot { root in
            let manager = makeManager(root)
            for name in ["a.md", "b.md", "c.md"] {
                manager.openTab(for: root.appendingPathComponent(name), text: name)
            }
            let middle = manager.tabs[1]
            manager.activateTab(middle.id)

            manager.requestClose(middle)
            #expect(manager.activeTab?.name == "c.md")
            #expect(manager.confirmingCloseTabID == nil)

            let last = try #require(manager.activeTab)
            manager.requestClose(last)
            #expect(manager.activeTab?.name == "a.md")
        }
    }

    @Test
    func blockMutationsPublishDirtyOnlyOnceAndSnapshotsKeepStableIDs() throws {
        try withTemporaryRoot { root in
            let sessionURL = root.appendingPathComponent("session.json")
            let manager = makeManager(root, sessionURL: sessionURL)
            let source = "- [ ] task\n\n# Heading"
            manager.openTab(for: root.appendingPathComponent("tasks.md"), text: source)
            let tab = try #require(manager.activeTab)
            let store = manager.blockEditorStore(for: tab)
            let originalIDs = store.document.blocks.map(\.id)
            var tabPublications = 0
            let observation = manager.$tabs.dropFirst().sink { _ in
                tabPublications += 1
            }

            store.toggleTask(blockID: originalIDs[0], itemIndex: 0)
            store.toggleTask(blockID: originalIDs[0], itemIndex: 0)
            store.toggleTask(blockID: originalIDs[0], itemIndex: 0)

            #expect(tabPublications == 1)
            #expect(manager.activeTab?.text == source)
            #expect(manager.activeTab?.isDirty == true)
            #expect(store.source == "- [x] task\n\n# Heading")
            #expect(store.document.blocks.map(\.id) == originalIDs)

            let snapshot = manager.snapshotSession()
            let snapshotTab = try #require(snapshot.tabs.first)
            #expect(snapshotTab.text == store.source)
            #expect(snapshotTab.markdownDocument?.source == store.source)
            #expect(snapshotTab.markdownDocument?.blocks.map(\.id) == originalIDs)
            #expect(manager.activeTab?.text == source)

            manager.saveSession()
            let restored = try #require(SessionStore.load(from: sessionURL))
            #expect(restored.tabs.first?.text == store.source)
            #expect(restored.tabs.first?.markdownDocument?.blocks.map(\.id) == originalIDs)
            _ = observation
        }
    }

    @Test
    func saveAndSaveAsUpdateIdentityOnlyAfterSuccessfulWrite() throws {
        enum WriteFailure: Error { case expected }

        try withTemporaryRoot { root in
            let manager = makeManager(root)
            manager.newDocument(text: "# Draft")
            let originalID = try #require(manager.activeTabID)
            let mdxURL = root.appendingPathComponent("component.mdx")
            var writtenText: String?
            var writtenURL: URL?

            let saved = manager.saveActiveDocument(to: mdxURL) { text, url in
                writtenText = text
                writtenURL = url
                try Data(text.utf8).write(to: url)
            }

            #expect(saved)
            #expect(writtenText == "# Draft")
            #expect(writtenURL == mdxURL)
            #expect(manager.activeTab?.id == originalID)
            #expect(manager.activeTab?.url == mdxURL)
            #expect(manager.activeTab?.name == "component.mdx")
            #expect(manager.activeTab?.isDirty == false)
            #expect(manager.activeTab?.isMarkdown == true)
            #expect(manager.activeTab?.markdownDocument?.source == "# Draft")

            manager.markActiveDirty()
            let beforeFailure = try #require(manager.activeTab)
            let failedURL = root.appendingPathComponent("failed.txt")
            let failed = manager.saveActiveDocument(to: failedURL) { _, _ in
                throw WriteFailure.expected
            }

            #expect(!failed)
            expectSameLifecycleState(try #require(manager.activeTab), beforeFailure)

            let txtURL = root.appendingPathComponent("plain.txt")
            #expect(manager.saveActiveDocument(to: txtURL))
            #expect(manager.activeTab?.url == txtURL)
            #expect(manager.activeTab?.isMarkdown == false)
            #expect(manager.activeTab?.markdownDocument == nil)
            #expect(try String(contentsOf: txtURL, encoding: .utf8) == "# Draft")
        }
    }

    @Test("save as to a new private-tmp path records its post-write canonical baseline")
    func saveAsNewPathUsesStablePostWriteCanonicalBaseline() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("MarkdownViewerPostWriteCanonical", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = "| Name | Value |\n| --- | --- |\n| old | before |"
        let original = root.appendingPathComponent("table.md")
        let destination = root.appendingPathComponent("table-copy.md")
        try Data(source.utf8).write(to: original)
        let preWriteCanonical = destination.standardizedFileURL
            .resolvingSymlinksInPath().path
        let manager = makeManager(root)
        guard case .openedFile = manager.openSelection(original, admission: .system) else {
            Issue.record("fixture did not open")
            return
        }
        let tab = try #require(manager.activeTab)
        let store = manager.blockEditorStore(for: tab)
        let tableID = try #require(store.document.blocks.first?.id)
        let cell = MarkdownTableCell(row: 0, column: 1)
        store.beginTableEditing(blockID: tableID, cell: cell)

        #expect(manager.saveActiveDocument(to: destination))

        let postWriteCanonical = destination.standardizedFileURL
            .resolvingSymlinksInPath().path
        #expect(preWriteCanonical != postWriteCanonical)
        #expect(manager.activeTab?.diskBaseline?.canonicalPath == postWriteCanonical)
        #expect(manager.activeTab?.isDirty == false)

        store.setTableCell(cell, value: "TABLE_AFTER_SAVE_AS")
        #expect(manager.activeTab?.isDirty == true)
        #expect(manager.saveActiveDocument())
        #expect(manager.lastSaveFailure == nil)
        #expect(manager.activeTab?.isDirty == false)
        #expect(try String(contentsOf: destination, encoding: .utf8)
            .contains("TABLE_AFTER_SAVE_AS") == true)
    }

    @Test("cross-format save ignores the removed Markdown store's disappear flush")
    func crossFormatSaveRemainsCleanAfterStaleMarkdownStoreFlush() throws {
        try withTemporaryRoot { root in
            let source = "# Before\n\nBody"
            let original = root.appendingPathComponent("source.md")
            let destination = root.appendingPathComponent("source.txt")
            try Data(source.utf8).write(to: original)
            let manager = makeManager(root)
            guard case .openedFile = manager.openSelection(original, admission: .system) else {
                Issue.record("fixture did not open")
                return
            }
            let tab = try #require(manager.activeTab)
            let store = manager.blockEditorStore(for: tab)
            let blockID = try #require(store.document.blocks.first?.id)
            store.beginSourceEditing(blockID: blockID)
            store.updateActiveDraft("# CROSS_FORMAT")

            #expect(manager.saveActiveDocument(to: destination))
            #expect(manager.activeTab?.isMarkdown == false)
            #expect(manager.activeTab?.isDirty == false)

            store.flushActiveEditingForLifecycleBoundary()

            #expect(manager.activeTab?.isDirty == false)
            #expect(manager.activeTab?.text == "# CROSS_FORMAT\n\nBody")
            #expect(try String(contentsOf: destination, encoding: .utf8)
                == "# CROSS_FORMAT\n\nBody")
        }
    }

    @Test
    func saveAsRejectsAnotherTabsCanonicalTargetWithoutWriting() throws {
        try withTemporaryRoot { root in
            let manager = makeManager(root)
            let target = root.appendingPathComponent("existing.md")
            manager.openTab(for: target, text: "existing")
            manager.newDocument(text: "draft")
            var writeCount = 0

            let saved = manager.saveActiveDocument(to: target) { _, _ in
                writeCount += 1
            }

            #expect(!saved)
            #expect(writeCount == 0)
            #expect(manager.tabs.count == 2)
            #expect(manager.activeTab?.url == nil)
            #expect(manager.activeTab?.text == "draft")
            #expect(manager.activeTab?.isDirty == true)
        }
    }

    @Test("ordinary save rejects external byte changes and preserves the live block draft")
    func ordinarySaveRejectsExternalChangeWithoutEndingBlockEditing() throws {
        try withTemporaryRoot { root in
            let url = root.appendingPathComponent("conflict.md")
            try Data("before\r\n".utf8).write(to: url)
            let manager = makeManager(root)
            guard case .openedFile = manager.openSelection(url, admission: .system) else {
                Issue.record("fixture did not open")
                return
            }
            let tab = try #require(manager.activeTab)
            let store = manager.blockEditorStore(for: tab)
            let blockID = try #require(store.document.blocks.first?.id)
            store.beginSourceEditing(blockID: blockID)
            store.updateActiveDraft("local draft", selection: NSRange(location: 5, length: 0))
            try Data("external\nchange".utf8).write(to: url)

            #expect(!manager.saveActiveDocument())

            #expect(manager.lastSaveFailure == .conflict(.modified))
            #expect(manager.activeTab?.text == "local draft\r\n")
            #expect(manager.activeTab?.isDirty == true)
            #expect(store.activeBlockID == blockID)
            #expect(store.snapshotSelection == NSRange(location: 5, length: 0))
            #expect(store.snapshotDocument().source == "local draft\r\n")
            #expect(try Data(contentsOf: url) == Data("external\nchange".utf8))
        }
    }

    @Test("deleted and unreadable current files reject ordinary save before the writer")
    func unavailableCurrentFileRejectsOrdinarySave() throws {
        try withTemporaryRoot { root in
            for unavailable in [ExternalFileConflict.deleted, .unreadable] {
                let url = root.appendingPathComponent(unavailable == .deleted ? "deleted.md" : "unreadable.md")
                try Data("baseline".utf8).write(to: url)
                let manager = makeManager(root)
                guard case .openedFile = manager.openSelection(url, admission: .system) else {
                    Issue.record("fixture did not open")
                    return
                }
                manager.pullActiveText = { "draft" }
                manager.markActiveDirty()
                if unavailable == .deleted {
                    try FileManager.default.removeItem(at: url)
                } else {
                    try FileManager.default.removeItem(at: url)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                }
                var writeCount = 0

                #expect(!manager.saveActiveDocument { _, _ in writeCount += 1 })
                #expect(manager.lastSaveFailure == .conflict(unavailable))
                #expect(manager.activeTab?.text == "draft")
                #expect(manager.activeTab?.isDirty == true)
                #expect(writeCount == 0)
            }
        }
    }

    @Test("save as through a symlink to the current file cannot bypass conflict detection")
    func saveAsCurrentSymlinkStillChecksBaseline() throws {
        try withTemporaryRoot { root in
            let url = root.appendingPathComponent("current.md")
            let alias = root.appendingPathComponent("alias.md")
            try Data("baseline".utf8).write(to: url)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
            let manager = makeManager(root)
            guard case .openedFile = manager.openSelection(url, admission: .system) else {
                Issue.record("fixture did not open")
                return
            }
            manager.pullActiveText = { "local draft" }
            manager.markActiveDirty()
            try Data("external".utf8).write(to: url)
            var writeCount = 0

            #expect(!manager.saveActiveDocument(to: alias) { _, _ in writeCount += 1 })

            #expect(manager.lastSaveFailure == .conflict(.modified))
            #expect(writeCount == 0)
            #expect(manager.activeTab?.url == url)
            #expect(manager.activeTab?.text == "local draft")
            #expect(try Data(contentsOf: url) == Data("external".utf8))
        }
    }

    @Test("save as to a different canonical path succeeds despite a current-file conflict")
    func saveAsNewPathEscapesConflictWithoutChangingOriginal() throws {
        try withTemporaryRoot { root in
            let original = root.appendingPathComponent("original.md")
            let destination = root.appendingPathComponent("copy.md")
            try Data("baseline".utf8).write(to: original)
            let manager = makeManager(root)
            guard case .openedFile = manager.openSelection(original, admission: .system) else {
                Issue.record("fixture did not open")
                return
            }
            manager.pullActiveText = { "local draft\r\n" }
            manager.markActiveDirty()
            try Data("external".utf8).write(to: original)

            #expect(manager.saveActiveDocument(to: destination))

            #expect(manager.lastSaveFailure == nil)
            #expect(manager.activeTab?.url == destination)
            #expect(manager.activeTab?.text == "local draft\r\n")
            #expect(manager.activeTab?.isDirty == false)
            #expect(try Data(contentsOf: original) == Data("external".utf8))
            #expect(try Data(contentsOf: destination) == Data("local draft\r\n".utf8))
        }
    }

    @Test("dirty session keeps its byte baseline while a legacy dirty session fails safely")
    func dirtyAndLegacySessionBaselineSafety() throws {
        try withTemporaryRoot { root in
            let url = root.appendingPathComponent("session.md")
            try Data("baseline".utf8).write(to: url)
            let first = makeManager(root)
            guard case .openedFile = first.openSelection(url, admission: .system) else {
                Issue.record("fixture did not open")
                return
            }
            first.pullActiveText = { "session draft" }
            first.markActiveDirty()
            let dirtySession = first.snapshotSession()
            try Data("external".utf8).write(to: url)

            let restored = makeManager(root)
            restored.restore(from: dirtySession)
            #expect(!restored.saveActiveDocument())
            #expect(restored.lastSaveFailure == .conflict(.modified))
            #expect(restored.activeTab?.text == "session draft")
            #expect(restored.activeTab?.isDirty == true)

            var legacy = try #require(dirtySession.tabs.first)
            legacy.diskBaseline = nil
            let legacySession = Session(
                tabs: [legacy],
                activeTabID: legacy.id,
                fontIndex: 1,
                sidebarWidth: 216,
                sidebarOpen: true,
                directoryPath: nil
            )
            let legacyRestored = makeManager(root)
            legacyRestored.restore(from: legacySession)

            #expect(!legacyRestored.saveActiveDocument())
            #expect(legacyRestored.lastSaveFailure == .conflict(.baselineUnknown))
            let copy = root.appendingPathComponent("legacy-copy.md")
            #expect(legacyRestored.saveActiveDocument(to: copy))
            #expect(try Data(contentsOf: copy) == Data("session draft".utf8))
            #expect(try Data(contentsOf: url) == Data("external".utf8))
        }
    }

    @Test("clean session reload adopts a fresh byte baseline")
    func cleanSessionRestoreAdoptsFreshDiskBaseline() throws {
        try withTemporaryRoot { root in
            let url = root.appendingPathComponent("clean-baseline.md")
            try Data("first\n".utf8).write(to: url)
            let first = makeManager(root)
            guard case .openedFile = first.openSelection(url, admission: .system) else {
                Issue.record("fixture did not open")
                return
            }
            let session = first.snapshotSession()
            try Data("second\r\n".utf8).write(to: url)

            let restored = makeManager(root)
            restored.restore(from: session)
            #expect(restored.activeTab?.text == "second\r\n")
            restored.pullActiveText = { "third\r\n" }
            restored.markActiveDirty()

            #expect(restored.saveActiveDocument())
            #expect(try Data(contentsOf: url) == Data("third\r\n".utf8))
            #expect(restored.activeTab?.isDirty == false)
        }
    }

    @Test
    func restoreKeepsDirtyBlockStateAndRecoversFromMissingWorkspace() throws {
        try withTemporaryRoot { root in
            var document = MarkdownDocument(source: "# One\n\nBody")
            let headingID = try #require(document.blocks.first?.id)
            _ = try document.replaceBlock(id: headingID, with: "# Edited")
            let tab = DocumentTab(
                url: nil,
                name: "未命名.md",
                text: document.source,
                isDirty: true,
                scrollY: 722.25,
                markdownDocument: document
            )
            let session = Session(
                tabs: [tab],
                activeTabID: UUID(),
                fontIndex: 99,
                sidebarWidth: 999,
                sidebarOpen: false,
                directoryPath: root.appendingPathComponent("missing").path,
                expandedFolderPaths: ["stale"]
            )
            let manager = makeManager(root)
            manager.directoryURL = root
            manager.fileTree = [FileNode(
                url: root,
                name: root.lastPathComponent,
                isDirectory: true
            )]
            manager.expandedFolders = [root.path]
            manager.lastClosedTab = tab
            manager.confirmingCloseTabID = tab.id

            manager.restore(from: session)

            #expect(manager.activeTabID == tab.id)
            #expect(manager.activeTab?.isDirty == true)
            #expect(manager.activeTab?.scrollY == 722.25)
            #expect(manager.activeTab?.markdownDocument?.blocks.map(\.id)
                    == document.blocks.map(\.id))
            #expect(manager.fontIndex == DesignTokens.bodyFontSizes.count - 1)
            #expect(manager.sidebarWidth == DesignTokens.sidebarMaxWidth)
            #expect(manager.sidebarOpen == false)
            #expect(manager.directoryURL == nil)
            #expect(manager.fileTree.isEmpty)
            #expect(manager.expandedFolders.isEmpty)
            #expect(manager.lastClosedTab == nil)
            #expect(manager.confirmingCloseTabID == nil)
        }
    }

    @Test
    func restoreKeepsDirtySessionTextAndReloadsCleanTabsFromDisk() throws {
        try withTemporaryRoot { root in
            let cleanURL = root.appendingPathComponent("clean.md")
            let dirtyURL = root.appendingPathComponent("dirty.md")
            try Data("external clean\r\nchange".utf8).write(to: cleanURL)
            try Data("disk dirty baseline".utf8).write(to: dirtyURL)
            let clean = DocumentTab(
                url: cleanURL,
                name: cleanURL.lastPathComponent,
                text: "stale clean session",
                isDirty: false
            )
            let dirty = DocumentTab(
                url: dirtyURL,
                name: dirtyURL.lastPathComponent,
                text: "unsaved dirty session",
                isDirty: true
            )
            let session = Session(
                tabs: [clean, dirty],
                activeTabID: clean.id,
                fontIndex: 1,
                sidebarWidth: 216,
                sidebarOpen: true,
                directoryPath: nil
            )
            let manager = makeManager(root)

            manager.restore(from: session)

            #expect(manager.tabs[0].text == "external clean\r\nchange")
            #expect(manager.tabs[0].isDirty == false)
            #expect(manager.tabs[1].text == "unsaved dirty session")
            #expect(manager.tabs[1].isDirty == true)
            #expect(try String(contentsOf: dirtyURL, encoding: .utf8) == "disk dirty baseline")
        }
    }

    @Test
    func finderOpenBeforeStartupRestoreWinsTheRace() throws {
        try withTemporaryRoot { root in
            let finderURL = root.appendingPathComponent("finder.md")
            try Data("finder document".utf8).write(to: finderURL)
            let stale = DocumentTab(
                url: nil,
                name: "stale.md",
                text: "stale session",
                isDirty: true
            )
            let session = Session(
                tabs: [stale],
                activeTabID: stale.id,
                fontIndex: 1,
                sidebarWidth: 216,
                sidebarOpen: true,
                directoryPath: nil
            )
            let manager = makeManager(root)

            guard case .openedFile = manager.openSelection(
                finderURL,
                admission: .system
            ) else {
                Issue.record("Finder document did not open")
                return
            }
            manager.restore(from: session)

            #expect(manager.tabs.contains { $0.id == stale.id })
            #expect(manager.activeTab?.url == finderURL)
            #expect(manager.activeTab?.text == "finder document")
        }
    }

    @Test
    func finderOpenActivatesMatchingDirtySessionWithoutLosingUnsavedText() throws {
        try withTemporaryRoot { root in
            let url = root.appendingPathComponent("same.md")
            try Data("disk version".utf8).write(to: url)
            let dirty = DocumentTab(
                url: url,
                name: url.lastPathComponent,
                text: "unsaved session version",
                isDirty: true
            )
            let session = Session(
                tabs: [dirty],
                activeTabID: dirty.id,
                fontIndex: 1,
                sidebarWidth: 216,
                sidebarOpen: true,
                directoryPath: nil
            )
            let manager = makeManager(root)

            guard case .openedFile = manager.openSelection(url, admission: .system) else {
                Issue.record("Finder document did not open")
                return
            }
            manager.restore(from: session)

            #expect(manager.tabs.count == 1)
            #expect(manager.activeTabID == dirty.id)
            #expect(manager.activeTab?.text == "unsaved session version")
            #expect(manager.activeTab?.isDirty == true)
            #expect(try String(contentsOf: url, encoding: .utf8) == "disk version")
        }
    }

    @Test
    func defaultOpenAndSavePreserveUTF8BOMAndCRLF() throws {
        try withTemporaryRoot { root in
            let url = root.appendingPathComponent("bom-crlf.md")
            let bytes = Data([0xEF, 0xBB, 0xBF] + Array("first\r\nsecond\r\n".utf8))
            try bytes.write(to: url)
            let manager = makeManager(root)

            guard case .openedFile = manager.openSelection(url, admission: .system) else {
                Issue.record("BOM fixture did not open")
                return
            }
            #expect(manager.activeTab?.text == "first\r\nsecond\r\n")
            let tab = try #require(manager.activeTab)
            let store = manager.blockEditorStore(for: tab)
            let blockID = try #require(store.document.blocks.first?.id)
            store.beginSourceEditing(blockID: blockID)
            store.updateActiveDraft("changed\r\nsecond")
            store.commitActiveEditing()
            #expect(manager.saveActiveDocument())
            let editedBytes = Data(
                [0xEF, 0xBB, 0xBF] + Array("changed\r\nsecond\r\n".utf8)
            )
            #expect(try Data(contentsOf: url) == editedBytes)
        }
    }

    @Test("save preserves LF, mixed line endings, and final-newline presence")
    func savePreservesLineEndingBytesAndFinalNewline() throws {
        try withTemporaryRoot { root in
            let fixtures: [(String, String)] = [
                ("first\n\nsecond", "changed\n\nsecond"),
                ("first\n\nsecond\n", "changed\n\nsecond\n"),
                ("first\r\n\r\nsecond\n", "changed\r\n\r\nsecond\n"),
            ]
            for (index, fixture) in fixtures.enumerated() {
                let url = root.appendingPathComponent("line-endings-\(index).md")
                try Data(fixture.0.utf8).write(to: url)
                let manager = makeManager(root)
                guard case .openedFile = manager.openSelection(url, admission: .system) else {
                    Issue.record("line-ending fixture did not open")
                    continue
                }
                let tab = try #require(manager.activeTab)
                let store = manager.blockEditorStore(for: tab)
                let blockID = try #require(store.document.blocks.first?.id)
                store.beginSourceEditing(blockID: blockID)
                store.updateActiveDraft("changed")

                #expect(manager.saveActiveDocument())
                #expect(try Data(contentsOf: url) == Data(fixture.1.utf8))
            }
        }
    }

    @Test
    func undoAndRedoUseBlockStoreWhenFirstResponderDoesNotHandleAction() throws {
        try withTemporaryRoot { root in
            let manager = makeManager(root)
            manager.openTab(
                for: root.appendingPathComponent("task.md"),
                text: "- [ ] task"
            )
            let store = manager.blockEditorStore(for: try #require(manager.activeTab))
            let taskID = try #require(store.document.blocks.first?.id)
            store.toggleTask(blockID: taskID, itemIndex: 0)
            #expect(store.source == "- [x] task")

            var selectors: [String] = []
            #expect(manager.undoActiveEdit { selector in
                selectors.append(NSStringFromSelector(selector))
                return false
            })
            #expect(store.source == "- [ ] task")
            #expect(selectors == ["undo:"])

            #expect(manager.redoActiveEdit { selector in
                selectors.append(NSStringFromSelector(selector))
                return false
            })
            #expect(store.source == "- [x] task")
            #expect(selectors == ["undo:", "redo:"])

            #expect(manager.undoActiveEdit { _ in true })
            #expect(store.source == "- [x] task")
        }
    }

    private func makeManager(
        _ root: URL,
        sessionURL: URL? = nil
    ) -> DocumentManager {
        DocumentManager(
            sessionURL: sessionURL ?? root.appendingPathComponent("session.json"),
            sessionSaveDelay: 3_600
        )
    }

    private func expectSameLifecycleState(
        _ actual: DocumentTab,
        _ expected: DocumentTab
    ) {
        #expect(actual.id == expected.id)
        #expect(actual.url == expected.url)
        #expect(actual.name == expected.name)
        #expect(actual.text == expected.text)
        #expect(actual.isDirty == expected.isDirty)
        #expect(actual.hasUTF8BOM == expected.hasUTF8BOM)
        #expect(actual.diskBaseline == expected.diskBaseline)
        #expect(actual.isMarkdown == expected.isMarkdown)
        #expect(actual.markdownDocument == expected.markdownDocument)
        #expect(actual.scrollY == expected.scrollY)
        #expect(actual.selectionRange == expected.selectionRange)
    }

    private func withTemporaryRoot(
        _ body: (URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownViewerLifecycleTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
