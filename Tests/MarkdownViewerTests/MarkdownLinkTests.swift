import AppKit
import Testing
@testable import MarkdownViewer

@Suite("Markdown links", .serialized)
struct MarkdownLinkTests {
    @Test
    func webURLsPreserveQueryAndFragment() {
        let destination = "https://example.com/docs?q=a%20b&lang=zh#intro"
        #expect(MarkdownLinkResolver.resolve(destination, documentURL: nil)?.absoluteString == destination)
    }

    @Test
    func localPathsResolveWithoutAnOpenDocument() {
        #expect(MarkdownLinkResolver.resolve("/tmp/中文 文件.txt", documentURL: nil)?.path == "/tmp/中文 文件.txt")
        #expect(MarkdownLinkResolver.resolve("file:///tmp/a%20b/", documentURL: nil)?.path == "/tmp/a b")
        #expect(MarkdownLinkResolver.resolve("~/Documents/中文%20文件.md", documentURL: nil)?.path ==
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/中文 文件.md").path)
        #expect(MarkdownLinkResolver.resolve("~", documentURL: nil)?.path ==
            FileManager.default.homeDirectoryForCurrentUser.path)
        #expect(MarkdownLinkResolver.resolve("docs/guide.md", documentURL: nil) == nil)
        #expect(MarkdownLinkResolver.resolve("", documentURL: nil) == nil)
    }

    @Test
    @MainActor
    func relativeFilesAndFoldersUseDocumentDirectory() {
        let document = URL(fileURLWithPath: "/tmp/项目 space/notes/current.md")
        for (destination, path) in [
            ("guide.md", "/tmp/项目 space/notes/guide.md"),
            ("../assets/", "/tmp/项目 space/assets"),
            ("./中文%20文件.txt", "/tmp/项目 space/notes/中文 文件.txt"),
            ("../assets/a%23b.txt", "/tmp/项目 space/assets/a#b.txt"),
        ] {
            let resolved = MarkdownLinkResolver.resolve(destination, documentURL: document)
            #expect(resolved?.isFileURL == true)
            #expect(resolved?.path == path)
            let rendered = PassiveMarkdownInlineRenderer.render(
                "[Open](\(destination))",
                style: PassiveMarkdownInlineStyle(font: .systemFont(ofSize: 15), color: .textColor)
            )
            let renderedDestination = PassiveMarkdownInlineRenderer.linkDestination(
                atUTF16Index: 0, in: rendered
            )
            #expect(renderedDestination == destination)
            #expect(MarkdownLinkResolver.resolve(renderedDestination ?? "", documentURL: document)?.path == path)
        }
    }

    @Test
    @MainActor
    func controlClickOpensOnlyTheHitLinkAndKeepsSecondaryClickSeparate() throws {
        _ = NSApplication.shared
        let rendered = PassiveMarkdownInlineRenderer.render(
            "[Website](https://example.com) and [Folder](/tmp/folder/)",
            style: PassiveMarkdownInlineStyle(
                font: NSFont.systemFont(ofSize: 15), color: .textColor
            )
        )
        var opened: [String] = []
        let tracker = PassiveInlineLinkTrackingView(
            attributed: rendered,
            onHoverURL: { _ in },
            onOpenURL: { opened.append($0) }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        window.contentView = container
        container.addSubview(tracker)
        tracker.frame = NSRect(x: 40, y: 20, width: 350, height: 50)
        tracker.layoutSubtreeIfNeeded()
        let links = try #require(tracker.accessibilityChildren() as? [PassiveInlineAccessibilityLink])
        #expect(links.count == 2)

        for link in links {
            let screen = link.accessibilityFrame()
            let point = window.convertPoint(fromScreen: NSPoint(x: screen.midX, y: screen.midY))
            #expect(tracker.hitTest(container.convert(point, from: nil)) === tracker)
            let event = try #require(NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: .control,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            ))
            #expect(!MarkdownBlockInteractionPolicy.allowsPointerEditing(event: event))
            tracker.rightMouseDown(with: event)
            let mouseUp = try #require(NSEvent.mouseEvent(
                with: .leftMouseUp, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0
            ))
            #expect(!MarkdownBlockInteractionPolicy.allowsPointerEditing(event: mouseUp))
        }
        #expect(opened == ["https://example.com", "/tmp/folder/"])

        let outside = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 390, y: 50), modifierFlags: .control,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1
        ))
        tracker.rightMouseDown(with: outside)
        let secondary = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: outside.locationInWindow, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 2, clickCount: 1, pressure: 1
        ))
        tracker.rightMouseDown(with: secondary)
        #expect(opened.count == 2)
    }
}
