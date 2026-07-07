import AppKit
import Testing
@testable import MarkdownViewer

extension StylerSuites {

    /// Case 12: table header/body rules, alignment font, hidden separator + pipes.
    @Suite(.serialized)
    struct TableTests {
        init() { pinBodyPointSize() }

        @Test func table() {
            let md = "| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |"
            let ts = StylerProbe.styled(md)

            // Header cell `A`: header rule + 11px semibold sans + tertiaryText.
            guard let a = requireIndex(ts, of: "A") else { return }
            #expect(StylerProbe.boolAttr(ts, .mvTableHeaderRule, a))
            #expect(StylerProbe.pointSize(ts, a) == 11)
            #expect(StylerProbe.color(ts, a) == DesignTokens.tertiaryText)

            // First body row cell `1`: body rule present; table body font 13.5.
            guard let one = requireIndex(ts, of: "1") else { return }
            #expect(StylerProbe.boolAttr(ts, .mvTableBodyRule, one))
            #expect(StylerProbe.pointSize(ts, one) == 13.5)

            // Last body row cell `3`: NO body rule (final row omits the hairline).
            guard let three = requireIndex(ts, of: "3") else { return }
            #expect(!StylerProbe.boolAttr(ts, .mvTableBodyRule, three))
            #expect(StylerProbe.attr(ts, .mvTableBodyRule, three) == nil)

            // Separator line `|---|---|`: non-body, clear, collapsed to size 1.
            guard let sep = requireRange(ts, of: "|---|---|") else { return }
            let dash = sep.location + 1
            #expect(StylerProbe.isNonBody(ts, dash))
            #expect(StylerProbe.isClear(StylerProbe.color(ts, dash)))
            #expect(StylerProbe.pointSize(ts, dash) == 1)

            // Header leading pipe (idx 0): folded to hidden + non-body.
            #expect(StylerProbe.isNonBody(ts, 0))
            #expect(StylerProbe.isClear(StylerProbe.color(ts, 0)))
        }
    }
}
