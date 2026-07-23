import Foundation
import Testing
@testable import MarkdownViewer

@Suite("Markdown source metrics")
struct MarkdownDisplayMetricsTests {
    @Test("authoritative fixture keeps source lines and matches rendered status")
    func authoritativeFixtureLineCount() throws {
        let fixture = try String(
            contentsOf: repositoryURL("ui/格式示例.md"),
            encoding: .utf8
        )
        #expect(fixture.components(separatedBy: "\n").count == 113)
        #expect(DocMetricsModel.sourceLineCount(in: fixture) == 113)
        #expect(DocMetricsModel.renderedBlockLineCount(
            in: MarkdownDocument(source: fixture)
        ) == 126)
        #expect(DocMetricsModel.nonWhitespaceCharacterCount(in: fixture) == 1_599)
    }

    @Test("list display separators do not change exact source line count")
    func listAndFenceSourceLines() {
        let document = MarkdownDocument(source: """
        Before

        1. First
        2. Second
           ```bash
           echo ok
           ```
        3. Third

        After
        """)

        #expect(document.source.components(separatedBy: "\n").count == 10)
        #expect(DocMetricsModel.sourceLineCount(in: document.source) == 10)
        #expect(DocMetricsModel.renderedBlockLineCount(in: document) == 13)
    }

    @Test("plain paragraphs and mixed line endings keep logical source lines")
    func ordinarySourceLines() {
        let document = MarkdownDocument(source: "one\r\n\r\ntwo\rthree")

        #expect(DocMetricsModel.sourceLineCount(in: document.source) == 4)
        #expect(DocMetricsModel.sourceLineCount(in: "line\n") == 2)
        #expect(DocMetricsModel.sourceLineCount(in: "") == 0)
    }

    @Test("document bottom whitespace follows the full window viewport")
    func viewportRelativeBottomWhitespace() {
        #expect(abs(DesignTokens.editorBottomPadding(contentHeight: 716) - 258.4) < 0.001)
        #expect(abs(DesignTokens.editorBottomPadding(contentHeight: 516) - 190.4) < 0.001)
        #expect(abs(DesignTokens.editorBottomPadding(contentHeight: 856) - 306) < 0.001)
    }

    @Test("adjacent block margins collapse instead of adding")
    func blockMarginCollapse() {
        #expect(MarkdownVerticalLayout.collapsedTopMargin(32, after: 20) == 12)
        #expect(MarkdownVerticalLayout.collapsedTopMargin(16, after: 18) == 0)
        #expect(MarkdownVerticalLayout.collapsedTopMargin(24, after: 18) == 6)
    }

    @Test("block bottom margins and heading line boxes follow the reference")
    func referenceVerticalMetrics() {
        let document = MarkdownDocument(source: """
        # H1

        ## H2

        paragraph

        ```swift
        let value = 1
        ```

        ---
        """)

        #expect(MarkdownVerticalLayout.bottomMargin(for: document.blocks[0]) == 16)
        #expect(MarkdownVerticalLayout.bottomMargin(for: document.blocks[1]) == 14)
        #expect(MarkdownVerticalLayout.bottomMargin(for: document.blocks[2]) == 18)
        #expect(MarkdownVerticalLayout.bottomMargin(for: document.blocks[3]) == 20)
        #expect(MarkdownVerticalLayout.bottomMargin(for: document.blocks[4]) == 16)
        #expect(MarkdownVerticalLayout.headingTopMargin(level: 1) == 34)
        #expect(MarkdownVerticalLayout.headingTopMargin(level: 6) == 18)
        #expect(MarkdownVerticalLayout.headingLineHeight(level: 1) == 33)
        #expect(MarkdownVerticalLayout.headingLineHeight(level: 6) == 16)
    }

    @Test("hover wash excludes outer block spacing")
    func hoverWashContentBounds() {
        let document = MarkdownDocument(source: """
        # H1

        paragraph

        ## H2

        ---

        | A |
        | --- |
        | B |
        """)

        let firstHeading = MarkdownHoverLayout.outerSpacing(
            for: document.blocks[0],
            isFirstBlock: true,
            previousBottomMargin: 0
        )
        let paragraph = MarkdownHoverLayout.outerSpacing(
            for: document.blocks[1],
            isFirstBlock: false,
            previousBottomMargin: 16
        )
        let secondHeading = MarkdownHoverLayout.outerSpacing(
            for: document.blocks[2],
            isFirstBlock: false,
            previousBottomMargin: 18
        )
        let rule = MarkdownHoverLayout.outerSpacing(
            for: document.blocks[3],
            isFirstBlock: false,
            previousBottomMargin: 14
        )

        #expect(firstHeading?.top == 0)
        #expect(firstHeading?.bottom == 16)
        #expect(paragraph?.top == 0)
        #expect(paragraph?.bottom == 18)
        #expect(secondHeading?.top == 14)
        #expect(secondHeading?.bottom == 14)
        #expect(rule?.top == 2)
        #expect(rule?.bottom == 16)
        #expect(MarkdownHoverLayout.outerSpacing(
            for: document.blocks[4],
            isFirstBlock: false,
            previousBottomMargin: 16
        ) == nil)
        #expect(MarkdownHoverLayout.horizontalOutset == 14)
        #expect(MarkdownHoverLayout.verticalOutset == 5)
        #expect(MarkdownHoverLayout.alignedBlockWidth(paperWidth: 640) == 640)
        #expect(MarkdownHoverLayout.backgroundWidth(paperWidth: 640) == 668)
        #expect(MarkdownHoverLayout.alignedBlockWidth(paperWidth: 506) == 506)
        #expect(MarkdownHoverLayout.backgroundWidth(paperWidth: 506) == 534)
    }

    @Test("preview header controls use the authoritative label widths")
    func previewHeaderControlWidths() {
        #expect(EditorHeaderLayout.previewModeControlWidth(isPreviewMode: false) == 41)
        #expect(EditorHeaderLayout.previewModeControlWidth(isPreviewMode: true) == 51)
    }

    @Test("active source editor matches the authoritative overflow and line box")
    func activeSourceEditorFrameMetrics() {
        #expect(BlockSourceEditorLayout.leadingOverflow == 14)
        #expect(BlockSourceEditorLayout.headingLineHeight(
            level: 1,
            bodyFontSize: 16.5
        ) == 41)
        #expect(BlockSourceEditorLayout.headingLineHeight(
            level: 2,
            bodyFontSize: 16.5
        ) == 32)
    }

    @Test("horizontal scroller gutter follows the authoritative window breakpoint")
    func horizontalScrollerGutterBreakpoint() {
        #expect(MarkdownHorizontalScrollerLayout.reservedGutterHeight(
            paperWidth: 640,
            windowWidth: 993,
            overflows: true
        ) == 6)
        #expect(MarkdownHorizontalScrollerLayout.reservedGutterHeight(
            paperWidth: 640,
            windowWidth: 994,
            overflows: true
        ) == 0)
        #expect(MarkdownHorizontalScrollerLayout.reservedGutterHeight(
            paperWidth: 506,
            windowWidth: 1_180,
            overflows: true
        ) == 6)
        #expect(MarkdownHorizontalScrollerLayout.reservedGutterHeight(
            paperWidth: 640,
            windowWidth: 860,
            overflows: false
        ) == 0)
    }

    private func repositoryURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }
}
