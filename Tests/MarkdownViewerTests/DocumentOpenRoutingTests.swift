import Foundation
import Testing
@testable import MarkdownViewer

@MainActor
@Suite(.serialized)
struct DocumentOpenRoutingTests {
    @Test
    func appBundleDeclaresEverySystemOpenableExtensionExactly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
        let documentTypes = try #require(
            plist["CFBundleDocumentTypes"] as? [[String: Any]]
        )
        let declared = Set(documentTypes.flatMap { documentType in
            documentType["CFBundleTypeExtensions"] as? [String] ?? []
        })
        let importedTypes = try #require(
            plist["UTImportedTypeDeclarations"] as? [[String: Any]]
        )

        #expect(declared == DocumentFormat.openableExtensions)
        #expect(
            documentTypes.allSatisfy {
                ($0["CFBundleTypeRole"] as? String) == "Editor"
            }
        )
        #expect(
            importedTypes.contains {
                ($0["UTTypeIdentifier"] as? String)
                    == "local.codex.markdownviewer.mdx"
            }
        )
    }

    @Test
    func dropAdmissionAcceptsExactlyTheFourProductFormats() throws {
        try withTemporaryRoot { root in
            let manager = makeManager(root)
            #expect(
                DocumentFormat.dropExtensions
                    == Set(["md", "markdown", "mdx", "txt"])
            )
            let accepted = [
                ("one.md", true),
                ("two.MARKDOWN", true),
                ("three.mdx", true),
                ("four.TXT", false),
            ]

            for (filename, rendersMarkdown) in accepted {
                let url = root.appendingPathComponent(filename)
                try Data("source for \(filename)".utf8).write(to: url)

                let result = manager.openSelection(url, admission: .drop)

                guard case .openedFile(let tabID) = result else {
                    Issue.record("expected dropped file to open: \(filename)")
                    continue
                }
                #expect(manager.activeTabID == tabID)
                #expect(manager.activeTab?.isMarkdown == rendersMarkdown)
                #expect((manager.activeTab?.markdownDocument != nil) == rendersMarkdown)
            }

            #expect(manager.tabs.count == accepted.count)
        }
    }

    @Test
    func dropRejectsBroaderSourceFormatsThatRemainSystemOpenable() throws {
        try withTemporaryRoot { root in
            let manager = makeManager(root)
            let yaml = root.appendingPathComponent("config.yaml")
            try Data("enabled: true".utf8).write(to: yaml)

            #expect(manager.openSelection(yaml, admission: .drop) == .rejectedUnsupported)
            #expect(manager.tabs.isEmpty)

            let result = manager.openSelection(yaml, admission: .system)
            guard case .openedFile = result else {
                Issue.record("system open should preserve supported source formats")
                return
            }
            #expect(manager.activeTab?.isMarkdown == false)
            #expect(manager.activeTab?.text == "enabled: true")
        }
    }

    @Test
    func openPanelHandlesCancellationFilesFoldersAndCanonicalDuplicates() throws {
        try withTemporaryRoot { root in
            let manager = makeManager(root)

            #expect(manager.openSelection(nil, admission: .openPanel) == .cancelled)
            #expect(manager.tabs.isEmpty)

            let docs = root.appendingPathComponent("docs", isDirectory: true)
            try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            let file = docs.appendingPathComponent("notes.md")
            try Data("disk source".utf8).write(to: file)

            #expect(manager.openSelection(docs, admission: .openPanel) == .openedDirectory(docs))
            let originalID = try #require(manager.activeTabID)
            #expect(manager.directoryURL == docs)
            #expect(manager.tabs.count == 1)

            let alias = root.appendingPathComponent("notes-alias.md")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
            var duplicateReadCount = 0
            let duplicate = manager.openSelection(
                alias,
                admission: .openPanel,
                reader: { _ in
                    duplicateReadCount += 1
                    return "must not replace the open tab"
                }
            )

            #expect(duplicate == .activatedExisting(originalID))
            #expect(duplicateReadCount == 0)
            #expect(manager.tabs.count == 1)
            #expect(manager.activeTab?.text == "disk source")
            #expect(
                manager.activeTab?.url?.standardizedFileURL.resolvingSymlinksInPath().path
                    == file.standardizedFileURL.resolvingSymlinksInPath().path
            )
        }
    }

    @Test
    func systemOpenClassifiesMarkdownAndExistingSourceFormats() throws {
        try withTemporaryRoot { root in
            let cases = [
                ("readme.md", true),
                ("component.mdx", true),
                ("notes.txt", false),
                ("config.json", false),
                ("Package.swift", false),
                ("script.sh", false),
                ("settings.toml", false),
            ]
            let manager = makeManager(root)

            for (filename, rendersMarkdown) in cases {
                let url = root.appendingPathComponent(filename)
                try Data("content: \(filename)".utf8).write(to: url)
                guard case .openedFile = manager.openSelection(url, admission: .system) else {
                    Issue.record("system open failed for \(filename)")
                    continue
                }
                #expect(manager.activeTab?.isMarkdown == rendersMarkdown)
            }

            #expect(manager.tabs.count == cases.count)
        }
    }

    @Test
    func unsupportedAndUnreadableSelectionsDoNotCreateTabs() throws {
        try withTemporaryRoot { root in
            let manager = makeManager(root)
            let image = root.appendingPathComponent("image.png")
            try Data([0, 1, 2]).write(to: image)
            let missing = root.appendingPathComponent("missing.md")

            #expect(manager.openSelection(image, admission: .system) == .rejectedUnsupported)
            #expect(manager.openSelection(missing, admission: .system) == .failedToRead)
            #expect(manager.tabs.isEmpty)
        }
    }

    @Test
    func oneProviderCanProduceAtMostOneDropDelivery() {
        let coordinator = DocumentDropCoordinator()
        let provider = NSObject()
        let firstURL = URL(fileURLWithPath: "/tmp/first.md")
        let secondURL = URL(fileURLWithPath: "/tmp/second.md")

        #expect(coordinator.claim(provider: provider))
        #expect(!coordinator.claim(provider: provider))
        #expect(
            coordinator.resolve(item: firstURL, provider: provider)
                == .fileURL(firstURL)
        )
        #expect(coordinator.resolve(item: secondURL, provider: provider) == nil)

        let nextProvider = NSObject()
        #expect(coordinator.claim(provider: nextProvider))
        #expect(
            coordinator.resolve(item: secondURL, provider: nextProvider)
                == .fileURL(secondURL)
        )
    }

    @Test
    func dropPayloadParsingAcceptsFileURLRepresentationsOnly() {
        let coordinator = DocumentDropCoordinator()
        let fileURL = URL(fileURLWithPath: "/tmp/格式 示例.mdx")

        for payload in [
            fileURL as Any,
            fileURL as NSURL,
            fileURL.absoluteString as NSString,
            Data(fileURL.absoluteString.utf8),
        ] {
            let provider = NSObject()
            #expect(coordinator.claim(provider: provider))
            #expect(
                coordinator.resolve(item: payload, provider: provider)
                    == .fileURL(fileURL)
            )
        }

        let webProvider = NSObject()
        #expect(coordinator.claim(provider: webProvider))
        #expect(
            coordinator.resolve(
                item: URL(string: "https://example.com/readme.md")!,
                provider: webProvider
            ) == .invalid
        )
    }

    @Test
    func plainSourceEditsSaveAndRestoreWithoutPreviewTransformation() throws {
        try withTemporaryRoot { root in
            let sessionURL = root.appendingPathComponent("session.json")
            let sourceURL = root.appendingPathComponent("config.json")
            try Data(#"{"before":true}"#.utf8).write(to: sourceURL)
            let manager = makeManager(root, sessionURL: sessionURL)

            guard case .openedFile = manager.openSelection(sourceURL, admission: .system) else {
                Issue.record("plain source did not open")
                return
            }
            let original = try #require(manager.activeTab)
            #expect(!original.isMarkdown)
            #expect(original.markdownDocument == nil)

            manager.togglePreviewMode()
            #expect(!manager.previewMode)
            #expect(manager.activeTab?.text == #"{"before":true}"#)

            manager.pullActiveText = { #"{"after":true}"# }
            manager.pullActiveScrollY = { 241.5 }
            manager.pullActiveSelection = { NSRange(location: 2, length: 7) }
            manager.markActiveDirty()
            manager.saveSession()

            let session = try #require(SessionStore.load(from: sessionURL))
            let persisted = try #require(session.tabs.first)
            #expect(persisted.text == #"{"after":true}"#)
            #expect(persisted.isDirty)
            #expect(persisted.scrollY == 241.5)
            #expect(persisted.selectionRange == NSRange(location: 2, length: 7))
            #expect(persisted.markdownDocument == nil)

            let restored = makeManager(root)
            restored.restore(from: session)
            #expect(restored.activeTab?.text == #"{"after":true}"#)
            #expect(restored.activeTab?.isDirty == true)
            #expect(restored.activeTab?.isMarkdown == false)
            #expect(restored.activeTab?.selectionRange == NSRange(location: 2, length: 7))

            var written = ""
            restored.pullActiveText = { #"{"saved":true}"# }
            #expect(restored.saveActiveDocument { text, url in
                written = text
                try Data(text.utf8).write(to: url)
            })
            #expect(written == #"{"saved":true}"#)
            #expect(restored.activeTab?.isDirty == false)
            #expect(restored.activeTab?.markdownDocument == nil)
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

    private func withTemporaryRoot(
        _ body: (URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownViewerOpenRoutingTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
