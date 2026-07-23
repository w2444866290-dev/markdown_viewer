import AppKit
import Testing
@testable import MarkdownViewer

@MainActor
@Suite(.serialized)
struct BlockSourceChromeTests {
    @Test
    func entryBackgroundUsesPrototypeTransitionDuration() {
        #expect(BlockSourceEditorHostView.backgroundTransitionDuration == 0.13)
    }

    @Test
    func plainAndCardSourceUseTheirPrototypeInsetsAndLeadingEdges() {
        let host = BlockSourceEditorHostView(textView: BlockSourceTextView(frame: .zero))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 80)

        host.configureChrome(for: .paragraph)
        host.layoutSubtreeIfNeeded()
        #expect(host.scrollView.frame.minX == 11)
        #expect(host.textView.textContainerInset == NSSize(width: 3, height: 1))

        for kind in [MarkdownBlockKind.code, .table] {
            host.configureChrome(for: kind)
            host.layoutSubtreeIfNeeded()
            #expect(host.scrollView.frame.minX == 14)
            #expect(host.textView.textContainerInset == NSSize(width: 14, height: 12))
        }
    }

    @Test
    func codeAndTableSourceUseThePrototypeCardForeground() throws {
        for kind in [MarkdownBlockKind.code, .table] {
            let source = kind == .code ? "let value = 1" : "| value |"
            let highlighted = BlockSourceHighlighter.highlightedSource(source, kind: kind)
            let contentIndex = kind == .code ? 0 : 2
            let color = try #require(
                highlighted.attribute(.foregroundColor, at: contentIndex, effectiveRange: nil) as? NSColor
            )
            let srgb = try #require(color.usingColorSpace(.sRGB))

            let expected = 68.0 / 255.0
            #expect(abs(srgb.redComponent - expected) < 0.0001)
            #expect(abs(srgb.greenComponent - expected) < 0.0001)
            #expect(abs(srgb.blueComponent - expected) < 0.0001)
        }
    }

    @Test
    func nativeTextAreaRetainsItsStableAccessibilitySurface() {
        let editor = BlockSourceEditor(
            initialSource: "body",
            blockKind: .paragraph,
            focusToken: SourceEditingSessionToken(
                blockID: UUID(),
                generation: 1
            ),
            accessibilityIdentifier: "source-editor-accessibility-test",
            onChange: { _, _, _ in },
            onCommit: { _, _, _ in }
        )
        let coordinator = editor.makeCoordinator()
        let host = BlockSourceEditorHostView(textView: BlockSourceTextView(frame: .zero))
        coordinator.attach(host: host)
        coordinator.load(
            source: editor.initialSource,
            kind: editor.blockKind,
            token: editor.focusToken,
            selection: nil
        )
        defer { coordinator.teardown() }

        #expect(host.textView.identifier?.rawValue == "source-editor-accessibility-test")
        #expect(host.textView.accessibilityLabel() == "Markdown 源代码编辑器")
        #expect(host.textView.isEditable)
        #expect(host.textView.isSelectable)
    }
}
