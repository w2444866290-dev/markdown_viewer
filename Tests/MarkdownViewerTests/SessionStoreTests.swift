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

    @Test("schema two virtual container paragraphs migrate to durable source boundaries")
    func virtualContainerParagraphMigration() throws {
        let trailingTabID = UUID()
        let trailingListID = UUID()
        let trailingParagraphID = UUID()
        let middleTabID = UUID()
        let firstListID = UUID()
        let middleParagraphID = UUID()
        let finalListID = UUID()
        let legacyJSON = """
        {
          "schemaVersion": 2,
          "tabs": [
            {
              "id": "\(trailingTabID.uuidString)",
              "url": "/tmp/trailing.md",
              "name": "trailing.md",
              "text": "- last item\\n",
              "isDirty": false,
              "isMarkdown": true,
              "scrollY": 0,
              "markdownDocument": {
                "blocks": [
                  {"id":"\(trailingListID.uuidString)","kind":"list","source":"- last item","leadingTrivia":""},
                  {"id":"\(trailingParagraphID.uuidString)","kind":"paragraph","source":"","leadingTrivia":"\\n"}
                ],
                "trailingTrivia": ""
              }
            },
            {
              "id": "\(middleTabID.uuidString)",
              "url": null,
              "name": "middle.md",
              "text": "- one\\n\\n- three",
              "isDirty": true,
              "isMarkdown": true,
              "scrollY": 0,
              "markdownDocument": {
                "blocks": [
                  {"id":"\(firstListID.uuidString)","kind":"list","source":"- one","leadingTrivia":""},
                  {"id":"\(middleParagraphID.uuidString)","kind":"paragraph","source":"","leadingTrivia":"\\n\\n"},
                  {"id":"\(finalListID.uuidString)","kind":"list","source":"- three","leadingTrivia":""}
                ],
                "trailingTrivia": ""
              }
            }
          ],
          "activeTabID": "\(middleTabID.uuidString)",
          "fontIndex": 1,
          "sidebarWidth": 216,
          "sidebarOpen": true,
          "directoryPath": null
        }
        """
        let url = try temporarySessionURL()
        defer { removeTemporaryRoot(for: url) }
        try Data(legacyJSON.utf8).write(to: url)

        let session = try #require(SessionStore.load(from: url))
        let trailing = session.tabs[0]
        let middle = session.tabs[1]

        #expect(session.schemaVersion == Session.currentSchemaVersion)
        #expect(trailing.text == "- last item\n\n")
        #expect(trailing.markdownDocument?.source == trailing.text)
        #expect(trailing.isDirty)
        #expect(trailing.markdownDocument?.blocks.map(\.id) == [
            trailingListID,
            trailingParagraphID,
        ])
        #expect(MarkdownDocument(source: trailing.text).blocks.map(\.kind) == [.list, .paragraph])

        #expect(middle.text == "- one\n\n\n\n- three")
        #expect(middle.markdownDocument?.source == middle.text)
        #expect(middle.isDirty)
        #expect(middle.markdownDocument?.blocks.map(\.id) == [
            firstListID,
            middleParagraphID,
            finalListID,
        ])
        #expect(MarkdownDocument(source: middle.text).blocks.map(\.kind) == [
            .list,
            .paragraph,
            .list,
        ])

        #expect(SessionStore.save(session, to: url))
        let reopened = try #require(SessionStore.load(from: url))
        #expect(reopened.tabs[0].markdownDocument?.blocks.map(\.id) == [
            trailingListID,
            trailingParagraphID,
        ])
        #expect(reopened.tabs[1].markdownDocument?.blocks.map(\.id) == [
            firstListID,
            middleParagraphID,
            finalListID,
        ])
        #expect(reopened.tabs.map(\.text) == [trailing.text, middle.text])
    }

    @Test("quote virtual paragraphs migrate without treating ordinary trivia as virtual")
    func quoteVirtualParagraphMigration() throws {
        let trailingTabID = UUID()
        let trailingQuoteID = UUID()
        let trailingParagraphID = UUID()
        let middleTabID = UUID()
        let firstQuoteID = UUID()
        let middleParagraphID = UUID()
        let finalQuoteID = UUID()
        let ordinaryTabID = UUID()
        let ordinaryQuoteID = UUID()
        let tabs: [[String: Any]] = [
            [
                "id": trailingTabID.uuidString,
                "url": "/tmp/trailing-quote.md",
                "name": "trailing-quote.md",
                "text": "> last quote\r\n",
                "isDirty": false,
                "isMarkdown": true,
                "scrollY": 84.5,
                "selectionLocation": 3,
                "selectionLength": 1,
                "markdownDocument": [
                    "blocks": [
                        [
                            "id": trailingQuoteID.uuidString,
                            "kind": "quote",
                            "source": "> last quote",
                            "leadingTrivia": "",
                        ],
                        [
                            "id": trailingParagraphID.uuidString,
                            "kind": "paragraph",
                            "source": "",
                            "leadingTrivia": "\r\n",
                        ],
                    ],
                    "trailingTrivia": "",
                ],
            ],
            [
                "id": middleTabID.uuidString,
                "url": NSNull(),
                "name": "middle-quote.md",
                "text": "> one\n\n> three",
                "isDirty": true,
                "isMarkdown": true,
                "scrollY": 19.25,
                "selectionLocation": 0,
                "selectionLength": 0,
                "markdownDocument": [
                    "blocks": [
                        [
                            "id": firstQuoteID.uuidString,
                            "kind": "quote",
                            "source": "> one",
                            "leadingTrivia": "",
                        ],
                        [
                            "id": middleParagraphID.uuidString,
                            "kind": "paragraph",
                            "source": "",
                            "leadingTrivia": "\n\n",
                        ],
                        [
                            "id": finalQuoteID.uuidString,
                            "kind": "quote",
                            "source": "> three",
                            "leadingTrivia": "",
                        ],
                    ],
                    "trailingTrivia": "",
                ],
            ],
            [
                "id": ordinaryTabID.uuidString,
                "url": "/tmp/ordinary-quote.md",
                "name": "ordinary-quote.md",
                "text": "> ordinary\n\n",
                "isDirty": false,
                "isMarkdown": true,
                "scrollY": 7.5,
                "selectionLocation": 2,
                "selectionLength": 0,
                "markdownDocument": [
                    "blocks": [[
                        "id": ordinaryQuoteID.uuidString,
                        "kind": "quote",
                        "source": "> ordinary",
                        "leadingTrivia": "",
                    ]],
                    "trailingTrivia": "\n\n",
                ],
            ],
        ]
        let object: [String: Any] = [
            "schemaVersion": 2,
            "tabs": tabs,
            "activeTabID": middleTabID.uuidString,
            "fontIndex": 1,
            "sidebarWidth": 216,
            "sidebarOpen": true,
            "directoryPath": NSNull(),
        ]
        let url = try temporarySessionURL()
        defer { removeTemporaryRoot(for: url) }
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let migrated = try #require(SessionStore.load(from: url))
        let trailing = migrated.tabs[0]
        let middle = migrated.tabs[1]
        let ordinary = migrated.tabs[2]

        #expect(trailing.text == "> last quote\r\n\r\n")
        #expect(trailing.markdownDocument?.source == trailing.text)
        #expect(trailing.markdownDocument?.blocks.map(\.id) == [
            trailingQuoteID,
            trailingParagraphID,
        ])
        #expect(trailing.isDirty)
        #expect(trailing.url?.path == "/tmp/trailing-quote.md")
        #expect(trailing.scrollY == 84.5)
        #expect(trailing.selectionRange == NSRange(location: 3, length: 1))

        #expect(middle.text == "> one\n\n\n\n> three")
        #expect(middle.markdownDocument?.source == middle.text)
        #expect(middle.markdownDocument?.blocks.map(\.id) == [
            firstQuoteID,
            middleParagraphID,
            finalQuoteID,
        ])
        #expect(middle.isDirty)
        #expect(middle.scrollY == 19.25)

        #expect(ordinary.text == "> ordinary\n\n")
        #expect(ordinary.markdownDocument?.source == ordinary.text)
        #expect(ordinary.markdownDocument?.blocks.map(\.id) == [ordinaryQuoteID])
        #expect(!ordinary.isDirty)
        #expect(ordinary.scrollY == 7.5)
        #expect(ordinary.selectionRange == NSRange(location: 2, length: 0))
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
