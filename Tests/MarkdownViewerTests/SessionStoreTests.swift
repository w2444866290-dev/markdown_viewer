import Foundation
import Testing
@testable import MarkdownViewer

@Suite(.serialized)
struct SessionStoreTests {
    @Test
    func legacySessionMigratesWithoutLosingDirtyContentOrScroll() throws {
        let tabID = try #require(
            UUID(uuidString: "11111111-2222-3333-4444-555555555555")
        )
        let legacyJSON = """
        {
          "tabs": [
            {
              "id": "\(tabID.uuidString)",
              "url": null,
              "name": "未命名.md",
              "text": "unsaved\\ncontent",
              "isDirty": true,
              "isMarkdown": true,
              "scrollY": 417.25
            }
          ],
          "activeTabID": "\(tabID.uuidString)",
          "fontIndex": 2,
          "sidebarWidth": 318.5,
          "sidebarOpen": false,
          "directoryPath": "/tmp/legacy-notes"
        }
        """
        let url = try temporarySessionURL()
        defer { removeTemporaryRoot(for: url) }
        try Data(legacyJSON.utf8).write(to: url)

        let migrated = try #require(SessionStore.load(from: url))
        let tab = try #require(migrated.tabs.first)

        #expect(migrated.schemaVersion == Session.currentSchemaVersion)
        #expect(migrated.activeTabID == tabID)
        #expect(migrated.fontIndex == 2)
        #expect(migrated.sidebarWidth == 318.5)
        #expect(!migrated.sidebarOpen)
        #expect(migrated.directoryPath == "/tmp/legacy-notes")
        #expect(migrated.expandedFolderPaths == nil)
        #expect(tab.id == tabID)
        #expect(tab.url == nil)
        #expect(tab.name == "未命名.md")
        #expect(tab.text == "unsaved\ncontent")
        #expect(tab.isDirty)
        #expect(tab.isMarkdown)
        #expect(tab.scrollY == 417.25)
        #expect(tab.markdownDocument?.source == tab.text)
    }

    @Test
    func currentSchemaRoundTripsEveryPersistedField() throws {
        let firstID = try #require(
            UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        )
        let secondID = try #require(
            UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")
        )
        let first = DocumentTab(
            id: firstID,
            url: URL(fileURLWithPath: "/tmp/README.mdx"),
            name: "README.mdx",
            text: "# Saved",
            isDirty: false,
            isMarkdown: true,
            scrollY: 12.75
        )
        let second = DocumentTab(
            id: secondID,
            url: nil,
            name: "未命名.md",
            text: "dirty draft",
            isDirty: true,
            isMarkdown: true,
            scrollY: 901.5
        )
        let original = Session(
            tabs: [first, second],
            activeTabID: second.id,
            fontIndex: 1,
            sidebarWidth: 264,
            sidebarOpen: true,
            directoryPath: "/tmp/project",
            expandedFolderPaths: ["/tmp/project/docs", "/tmp/project/examples"]
        )
        let url = try temporarySessionURL()
        defer { removeTemporaryRoot(for: url) }

        #expect(SessionStore.save(original, to: url))
        let restored = try #require(SessionStore.load(from: url))

        #expect(restored.schemaVersion == Session.currentSchemaVersion)
        #expect(restored.activeTabID == original.activeTabID)
        #expect(restored.fontIndex == original.fontIndex)
        #expect(restored.sidebarWidth == original.sidebarWidth)
        #expect(restored.sidebarOpen == original.sidebarOpen)
        #expect(restored.directoryPath == original.directoryPath)
        #expect(restored.expandedFolderPaths == original.expandedFolderPaths)
        #expect(restored.tabs.count == 2)
        expectEqual(restored.tabs[0], first)
        expectEqual(restored.tabs[1], second)

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        #expect(object["schemaVersion"] as? Int == Session.currentSchemaVersion)
    }

    @Test
    func missingEmptyAndCorruptFilesFallBackToNil() throws {
        let url = try temporarySessionURL()
        defer { removeTemporaryRoot(for: url) }

        #expect(SessionStore.load(from: url) == nil)

        try Data().write(to: url)
        #expect(SessionStore.load(from: url) == nil)

        try Data("{ definitely-not-json".utf8).write(to: url)
        #expect(SessionStore.load(from: url) == nil)
    }

    @Test
    func legacyFileURLsAndMissingFormatFlagsMigrateByExtension() throws {
        let txtID = UUID()
        let mdxID = UUID()
        let legacyJSON = """
        {
          "tabs": [
            {
              "id": "\(txtID.uuidString)",
              "url": "file:///tmp/legacy%20note.txt",
              "name": "legacy note.txt",
              "text": "plain source",
              "isDirty": false,
              "scrollY": 0
            },
            {
              "id": "\(mdxID.uuidString)",
              "url": "/tmp/component.mdx",
              "name": "component.mdx",
              "text": "# Component",
              "isDirty": true,
              "isMarkdown": false,
              "scrollY": 11
            }
          ],
          "activeTabID": "\(mdxID.uuidString)",
          "fontIndex": 1,
          "sidebarWidth": 216,
          "sidebarOpen": true,
          "directoryPath": null
        }
        """
        let url = try temporarySessionURL()
        defer { removeTemporaryRoot(for: url) }
        try Data(legacyJSON.utf8).write(to: url)

        let migrated = try #require(SessionStore.load(from: url))
        #expect(migrated.tabs[0].url?.path == "/tmp/legacy note.txt")
        #expect(migrated.tabs[0].isMarkdown == false)
        #expect(migrated.tabs[0].markdownDocument == nil)
        #expect(migrated.tabs[1].url?.path == "/tmp/component.mdx")
        #expect(migrated.tabs[1].isMarkdown == true)
        #expect(migrated.tabs[1].markdownDocument?.source == "# Component")
    }

    @Test
    func inconsistentPersistedBlockModelIsRebuiltFromAuthoritativeText() throws {
        let staleDocument = MarkdownDocument(source: "# Stale")
        let tab = DocumentTab(
            url: nil,
            name: "draft.md",
            text: staleDocument.source,
            isDirty: true,
            markdownDocument: staleDocument
        )
        let session = Session(
            tabs: [tab],
            activeTabID: tab.id,
            fontIndex: 1,
            sidebarWidth: 216,
            sidebarOpen: true,
            directoryPath: nil
        )
        let url = try temporarySessionURL()
        defer { removeTemporaryRoot(for: url) }
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(session))
                as? [String: Any]
        )
        var tabs = try #require(object["tabs"] as? [[String: Any]])
        tabs[0]["text"] = "# Recovered"
        object["tabs"] = tabs
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let restored = try #require(SessionStore.load(from: url)?.tabs.first)
        #expect(restored.text == "# Recovered")
        #expect(restored.markdownDocument?.source == "# Recovered")
        #expect(restored.markdownDocument?.blocks.first?.source == "# Recovered")
    }

    @Test
    func unsupportedSchemaVersionsRecoverAsNoSession() throws {
        let url = try temporarySessionURL()
        defer { removeTemporaryRoot(for: url) }
        for version in [-1, Session.currentSchemaVersion + 1] {
            let json = """
            {
              "schemaVersion": \(version),
              "tabs": [],
              "activeTabID": null,
              "fontIndex": 1,
              "sidebarWidth": 216,
              "sidebarOpen": true,
              "directoryPath": null
            }
            """
            try Data(json.utf8).write(to: url)
            #expect(SessionStore.load(from: url) == nil)
        }
    }

    @Test
    func injectedSaveWritesOnlyItsTargetURL() throws {
        let target = try temporarySessionURL()
        defer { removeTemporaryRoot(for: target) }
        let sibling = target
            .deletingLastPathComponent()
            .appendingPathComponent("untouched.json")
        let sentinel = Data("do not replace".utf8)
        try sentinel.write(to: sibling)
        let session = Session(
            tabs: [],
            activeTabID: nil,
            fontIndex: 0,
            sidebarWidth: 216,
            sidebarOpen: true,
            directoryPath: nil
        )

        #expect(SessionStore.save(session, to: target))
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(try Data(contentsOf: sibling) == sentinel)
        #expect(SessionStore.load(from: target)?.schemaVersion == Session.currentSchemaVersion)
    }

    @Test
    func injectedSaveFailureIsReportedWithoutReplacingExistingData() throws {
        let target = try temporarySessionURL()
        defer { removeTemporaryRoot(for: target) }
        let directoryTarget = target.deletingLastPathComponent()
        let session = Session(
            tabs: [],
            activeTabID: nil,
            fontIndex: 1,
            sidebarWidth: 216,
            sidebarOpen: true,
            directoryPath: nil
        )

        #expect(!SessionStore.save(session, to: directoryTarget))
        #expect(FileManager.default.fileExists(atPath: directoryTarget.path))
        #expect(SessionStore.load(from: target) == nil)
    }

    private func expectEqual(_ actual: DocumentTab, _ expected: DocumentTab) {
        #expect(actual.id == expected.id)
        #expect(actual.url == expected.url)
        #expect(actual.name == expected.name)
        #expect(actual.text == expected.text)
        #expect(actual.isDirty == expected.isDirty)
        #expect(actual.isMarkdown == expected.isMarkdown)
        #expect(actual.markdownDocument == expected.markdownDocument)
        #expect(actual.scrollY == expected.scrollY)
    }

    private func temporarySessionURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownViewerSessionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let url = root.appendingPathComponent("nested/session.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return url
    }

    private func removeTemporaryRoot(for url: URL) {
        let root = url
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try? FileManager.default.removeItem(at: root)
    }
}
