import AppKit
import Testing
@testable import MarkdownViewer

extension StylerSuites {

    /// Cases 3, 4, 5, 6, 14: bold, italic, strikethrough, inline code, link vs image.
    @Suite(.serialized)
    struct InlineTests {
        init() { pinBodyPointSize() }

        // Case 3: Bold `a **b** c`.
        @Test func bold() {
            let ts = StylerProbe.styled("a **b** c")
            guard let b = requireIndex(ts, of: "b") else { return }   // idx 4
            #expect(StylerProbe.isBold(ts, b))
            #expect(!StylerProbe.isNonBody(ts, b))
            // Leading `**` (idx 2,3) hidden + non-body.
            #expect(StylerProbe.isNonBody(ts, 2))
            #expect(StylerProbe.isHidden(ts, 2))
            // Trailing `**` (idx 5,6) hidden + non-body.
            #expect(StylerProbe.isNonBody(ts, 5))
            #expect(StylerProbe.isHidden(ts, 5))
        }

        // Case 4: Italic `*x*`.
        @Test func italic() {
            let ts = StylerProbe.styled("*x*")
            #expect(StylerProbe.isItalic(ts, 1))
            expectClose(StylerProbe.cgFloat(ts, .obliqueness, 1), 0.15, "italic obliqueness")
            #expect(!StylerProbe.isNonBody(ts, 1))
            // `*` delimiters hidden + non-body.
            #expect(StylerProbe.isNonBody(ts, 0))
            #expect(StylerProbe.isHidden(ts, 0))
            #expect(StylerProbe.isNonBody(ts, 2))
        }

        // Case 5: Strikethrough `~~y~~`.
        @Test func strikethrough() {
            let ts = StylerProbe.styled("~~y~~")
            guard let y = requireIndex(ts, of: "y") else { return }   // idx 2
            #expect(StylerProbe.cgFloat(ts, .strikethroughStyle, y) == CGFloat(NSUnderlineStyle.single.rawValue))
            #expect(StylerProbe.color(ts, y) == DesignTokens.secondaryText)
            #expect(!StylerProbe.isNonBody(ts, y))
            // `~~` hidden + non-body.
            #expect(StylerProbe.isNonBody(ts, 0))
            #expect(StylerProbe.isHidden(ts, 0))
        }

        // Case 6: Inline code `a `code` b`.
        @Test func inlineCode() {
            let ts = StylerProbe.styled("a `code` b")
            guard let c = requireIndex(ts, of: "code") else { return }   // idx 3
            #expect(StylerProbe.boolAttr(ts, .mvInlineCode, c))
            #expect(StylerProbe.font(ts, c)?.isFixedPitch == true)
            #expect(StylerProbe.pointSize(ts, c) == 13)
            #expect(StylerProbe.color(ts, c) == DesignTokens.titleText)
            // Content is searchable body text: NOT non-body.
            #expect(!StylerProbe.isNonBody(ts, c))
            // Backticks (idx 2 and 7) hidden + non-body.
            #expect(StylerProbe.isNonBody(ts, 2))
            #expect(StylerProbe.isHidden(ts, 2))
            #expect(StylerProbe.isNonBody(ts, 7))
        }

        // Case 14: Link — label styled + searchable; URL treated as markup.
        @Test func link() {
            let ts = StylerProbe.styled("[label](http://x)")
            guard let label = requireRange(ts, of: "label") else { return }   // idx 1..5
            let l = label.location
            #expect(StylerProbe.cgFloat(ts, .underlineStyle, l) == CGFloat(NSUnderlineStyle.single.rawValue))
            #expect(StylerProbe.attr(ts, .underlineColor, l) as? NSColor == NSColor(hex: 0xC7C7CC))
            #expect(StylerProbe.color(ts, l) == NSColor(hex: 0x1D1D1F))
            // Label is body reading text.
            expectNonBody(ts, label, false, "link label")
            // URL is non-body (excluded from find).
            guard let url = requireRange(ts, of: "http://x") else { return }
            expectNonBody(ts, url, true, "link url")
            // CHARACTERIZATION FINDING: `dimMarkup(contentIndex: 1)` hides the whole
            // `](url)` tail, OVERWRITING the mutedColor/markerFont set just before it
            // (LiveMarkdownStyler.swift:753-755 is dead code). So the URL renders HIDDEN
            // (clear + ~1pt), NOT dimmed grey as the spec's case 14 states. It surfaces
            // on hover via `linkDestination` instead. Pin the actual hidden rendering:
            #expect(StylerProbe.isHidden(ts, url.location))
            // `[` (idx 0) hidden + non-body.
            #expect(StylerProbe.isNonBody(ts, 0))
            #expect(StylerProbe.isHidden(ts, 0))
        }

        // Case 14: Image — alt is non-body italic; `!` prevents link treatment.
        @Test func image() {
            let ts = StylerProbe.styled("![alt](p.png)")
            guard let alt = requireRange(ts, of: "alt") else { return }
            let a = alt.location
            #expect(StylerProbe.isItalic(ts, a))
            expectClose(StylerProbe.cgFloat(ts, .obliqueness, a), 0.15, "image alt obliqueness")
            #expect(StylerProbe.color(ts, a) == DesignTokens.secondaryText)
            // Image alt is NOT body reading text.
            expectNonBody(ts, alt, true, "image alt")
            // Not treated as a link: no underline on the alt text.
            #expect(StylerProbe.attr(ts, .underlineStyle, a) == nil)
            // `![` hidden.
            #expect(StylerProbe.isNonBody(ts, 0))
            #expect(StylerProbe.isHidden(ts, 0))
        }
    }
}
