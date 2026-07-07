import AppKit
import Testing
@testable import MarkdownViewer

/// Cases 7, 8, 9: fenced code block styling, card continuity, `fencedCodeBlocks` fn.
@Suite(.serialized)
struct CodeFenceTests {
    init() { pinBodyPointSize() }

    private let fence = "```"

    // Case 7: fence + language label.
    @Test func codeFenceAndLanguageLabel() {
        let ts = StylerProbe.styled("\(fence)swift\nlet x = 1\n\(fence)")

        // Body line: mvCodeBlock, NOT non-body, monospaced 12.5, #444444.
        let body = StylerProbe.index(of: "let x = 1", in: ts)
        #expect(StylerProbe.boolAttr(ts, .mvCodeBlock, body))
        #expect(!StylerProbe.isNonBody(ts, body))
        #expect(StylerProbe.font(ts, body)?.isFixedPitch == true)
        #expect(StylerProbe.pointSize(ts, body) == 12.5)
        #expect(StylerProbe.color(ts, body) == NSColor(hex: 0x444444))

        // Language token `swift`: mvCodeBlock + non-body, monospaced 10.5, kern 0.6.
        let lang = StylerProbe.index(of: "swift", in: ts)
        #expect(StylerProbe.boolAttr(ts, .mvCodeBlock, lang))
        #expect(StylerProbe.isNonBody(ts, lang))
        #expect(StylerProbe.font(ts, lang)?.isFixedPitch == true)
        #expect(StylerProbe.pointSize(ts, lang) == 10.5)
        expectClose(StylerProbe.cgFloat(ts, .kern, lang), 0.6, "lang label kern")

        // Opening-fence markers (idx 0): hidden.
        #expect(StylerProbe.isNonBody(ts, 0))
        #expect(StylerProbe.isHidden(ts, 0))
    }

    // Case 8: card continuity across a blank line — mvCodeBlock is one contiguous run.
    @Test func cardContinuityAcrossBlankLine() {
        let ts = StylerProbe.styled("\(fence)py\na\n\nb\n\(fence)")
        let n = (ts.string as NSString).length
        for i in 0..<n where !StylerProbe.boolAttr(ts, .mvCodeBlock, i) {
            fail("mvCodeBlock must be contiguous; missing at \(i)")
        }
    }

    // Case 9: `fencedCodeBlocks(in:)` pure function.
    @Test func fencedCodeBlocksFunction() throws {
        let ns = "\(fence)py\na\n\nb\n\(fence)" as NSString
        let blocks = LiveMarkdownStyler.fencedCodeBlocks(in: ns)
        #expect(blocks.count == 1)
        let block = try #require(blocks.first)

        // Body starts at "a" and ends before the closing fence line.
        let aStart = ns.range(of: "a").location
        let closeStart = ns.range(of: fence, options: .backwards).location
        #expect(block.bodyRange.location == aStart)
        #expect(NSMaxRange(block.bodyRange) == closeStart)
        // Body excludes the opening fence line + language token.
        #expect(block.bodyRange.location > ns.range(of: "py").location)
        // Container spans open fence through close fence.
        #expect(block.containerRange.location == 0)
        #expect(NSMaxRange(block.containerRange) == ns.length)
    }

    // Case 9: an unterminated trailing fence is ignored.
    @Test func unterminatedFenceIgnored() {
        let blocks = LiveMarkdownStyler.fencedCodeBlocks(in: "\(fence)swift\nlet x = 1" as NSString)
        #expect(blocks.count == 0)
    }
}
