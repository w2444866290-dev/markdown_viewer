import AppKit
import Testing
@testable import MarkdownViewer

/// Cases 1, 2, 10, 11, 13: headings, blockquote, list/task markers, horizontal rule.
@Suite(.serialized)
struct BlockTests {
    init() { pinBodyPointSize() }

    // Case 1: H1 `# Title`
    @Test func h1() {
        let ts = StylerProbe.styled("# Title")
        // `#` (idx 0) hidden + non-body.
        #expect(StylerProbe.isNonBody(ts, 0))
        #expect(StylerProbe.isHidden(ts, 0))
        #expect(StylerProbe.pointSize(ts, 0) == 1)
        // `Title` starts at idx 2 (idx1 is the space).
        let t = StylerProbe.index(of: "Title", in: ts)
        #expect(t == 2)
        #expect(StylerProbe.pointSize(ts, t) == 26)
        #expect(StylerProbe.color(ts, t) == DesignTokens.headingText)
        expectClose(StylerProbe.cgFloat(ts, .kern, t), -0.2, "H1 kern")
        #expect(!StylerProbe.isNonBody(ts, t))
    }

    // Case 2: H2 font + non-CJK kern.
    @Test func h2FontAndKern() {
        let ts = StylerProbe.styled("## A")
        let a = StylerProbe.index(of: "A", in: ts)
        #expect(StylerProbe.pointSize(ts, a) == 18)
        expectClose(StylerProbe.cgFloat(ts, .kern, a), 0.3, "H2 kern")
    }

    // Case 2: H3 font, no kern.
    @Test func h3Font() {
        let ts = StylerProbe.styled("### B")
        let b = StylerProbe.index(of: "B", in: ts)
        #expect(StylerProbe.pointSize(ts, b) == 16)
        #expect(StylerProbe.attr(ts, .kern, b) == nil)
    }

    // Case 10: Blockquote `> quote`
    @Test func blockquote() {
        let ts = StylerProbe.styled("> quote")
        let q = StylerProbe.index(of: "quote", in: ts)
        #expect(StylerProbe.pointSize(ts, q) == 14.5)
        #expect(StylerProbe.color(ts, q) == NSColor(hex: 0x767676))
        #expect(!StylerProbe.isNonBody(ts, q))
        // `>` marker (idx 0) hidden + non-body.
        #expect(StylerProbe.isNonBody(ts, 0))
        #expect(StylerProbe.isHidden(ts, 0))
    }

    // Case 11: unordered list marker.
    @Test func unorderedListMarker() {
        let ts = StylerProbe.styled("- item")
        // `- ` marker (idx 0..1) non-body + placeholder color + markerFont (14, fixed).
        #expect(StylerProbe.isNonBody(ts, 0))
        #expect(StylerProbe.color(ts, 0) == DesignTokens.placeholderText)
        #expect(StylerProbe.pointSize(ts, 0) == 14)
        #expect(StylerProbe.font(ts, 0)?.isFixedPitch == true)
        // Paragraph indent 20.
        let ps = StylerProbe.attr(ts, .paragraphStyle, 0) as? NSParagraphStyle
        #expect(ps?.firstLineHeadIndent == 20)
        // Content not non-body.
        #expect(!StylerProbe.isNonBody(ts, StylerProbe.index(of: "item", in: ts)))
    }

    // Case 11: ordered list marker.
    @Test func orderedListMarker() {
        let ts = StylerProbe.styled("1. item")
        #expect(StylerProbe.isNonBody(ts, 0))       // `1` of `1. `
        #expect(StylerProbe.color(ts, 0) == DesignTokens.placeholderText)
        #expect(!StylerProbe.isNonBody(ts, StylerProbe.index(of: "item", in: ts)))
    }

    // Case 11: task marker uses boldCodeFont (monospaced 12.5 semibold).
    @Test func taskMarker() {
        let ts = StylerProbe.styled("- [ ] x")
        #expect(StylerProbe.isNonBody(ts, 0))
        #expect(StylerProbe.pointSize(ts, 0) == 12.5)
        #expect(StylerProbe.font(ts, 0)?.isFixedPitch == true)
        #expect(!StylerProbe.isNonBody(ts, StylerProbe.index(of: "x", in: ts)))
    }

    // Case 13: horizontal rule `---` / `***` / `___`.
    @Test(arguments: ["---", "***", "___"])
    func horizontalRule(_ rule: String) {
        let ts = StylerProbe.styled(rule)
        #expect(StylerProbe.boolAttr(ts, .mvHorizontalRule, 0))
        #expect(StylerProbe.isNonBody(ts, 0))
        #expect(StylerProbe.isClear(StylerProbe.color(ts, 0)))
        #expect(StylerProbe.pointSize(ts, 0) == 1)
    }
}
