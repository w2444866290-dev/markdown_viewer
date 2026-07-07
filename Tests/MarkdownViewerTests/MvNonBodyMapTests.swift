import AppKit
import Testing
@testable import MarkdownViewer

extension StylerSuites {

    /// Case 15a (crown): the `.mvNonBody` "所见即所搜" invariant. Over one document
    /// containing every construct, body reading text must carry NO `.mvNonBody`, while
    /// every hidden-syntax or dimmed-non-body run must carry it. This is the invariant
    /// `FindController` relies on to build its body-only search map.
    @Suite(.serialized)
    struct MvNonBodyMapTests {
        init() { pinBodyPointSize() }

        private let fence = "```"

        @Test func globalMvNonBodyMap() {
            let md = [
                "# Heading One",
                "",
                "Plain paragraph with **bold** and *italic* and `inline` text.",
                "",
                "> A quoted line here.",
                "",
                "- list item alpha",
                "1. numbered beta",
                "",
                "| Col | Val |",
                "|-----|-----|",
                "| aaa | bbb |",
                "",
                "\(fence)lang",
                "code body line",
                fence,
                "",
                "---",
                "",
                "[label](http://example.com) and ![alt](img.png) done.",
            ].joined(separator: "\n")
            let ts = StylerProbe.styled(md)

            // ---- BODY: reading text, must be mvNonBody == false everywhere. ----
            for phrase in [
                "Heading One",                     // heading text
                "Plain paragraph with", "text.",   // paragraph text
                "bold",                            // bold content
                "italic",                          // italic content
                "inline",                          // inline-code content
                "A quoted line here",              // blockquote text
                "list item alpha",                 // list item text
                "numbered beta",                   // ordered list item text
                "Col", "Val",                      // table header cells
                "aaa", "bbb",                      // table body cells
                "code body line",                  // fenced-code content
                "label",                           // link label
                "done.",                           // trailing paragraph text
            ] {
                expectNonBody(ts, substring: phrase, false)
            }

            // ---- NON-BODY: dimmed non-body reading text, must be mvNonBody == true. ----
            for phrase in [
                "http://example.com",   // link URL (address)
                "alt",                  // image alt text
                "img.png",              // image path
            ] {
                expectNonBody(ts, substring: phrase, true)
            }

            // Heading `#`.
            if let h = requireIndex(ts, of: "# Heading") { expectChar(ts, h, "heading #") }

            // Emphasis delimiters `**bold**`, `*italic*`, and inline `` `inline` `` backticks.
            expectDelimiters(ts, around: "**bold**", left: 2, right: 2)
            expectDelimiters(ts, around: "*italic*", left: 1, right: 1)
            expectDelimiters(ts, around: "`inline`", left: 1, right: 1)

            // Blockquote marker `>`.
            if let q = requireIndex(ts, of: "> A quoted") { expectChar(ts, q, "quote >") }

            // List markers `- ` and `1. `.
            if let dash = requireIndex(ts, of: "- list item alpha") {
                expectChar(ts, dash, "list dash")
                expectChar(ts, dash + 1, "list marker space")
            }
            if let num = requireIndex(ts, of: "1. numbered beta") {
                expectChar(ts, num, "ordered 1")
                expectChar(ts, num + 1, "ordered dot")
            }

            // Table pipe + separator.
            if let pipe = requireIndex(ts, of: "| Col") { expectChar(ts, pipe, "table pipe") }
            expectNonBody(ts, substring: "|-----|-----|", true)

            // Fence markers + language label.
            if let open = requireIndex(ts, of: "\(fence)lang") {
                for i in open..<(open + 3) { expectChar(ts, i, "open fence backtick \(i)") }
            }
            expectNonBody(ts, substring: "lang", true)   // language label token

            // Horizontal rule `---` (the standalone line, not the table separator).
            if let hrLine = requireIndex(ts, of: "\n---\n") {
                let hr = hrLine + 1
                for i in hr..<(hr + 3) { expectChar(ts, i, "hr dash \(i)") }
            }

            // Link/image bracket syntax.
            if let lb = requireIndex(ts, of: "[label]") { expectChar(ts, lb, "link [") }
            if let img = requireIndex(ts, of: "![alt]") { expectChar(ts, img, "image !") }
        }

        /// #6: bounds-guarded; on out-of-range index it fails with a clear message
        /// instead of reading an attribute at `NSNotFound`.
        private func expectChar(_ ts: NSTextStorage, _ i: Int, _ what: String,
                                sourceLocation: SourceLocation = #_sourceLocation) {
            guard i >= 0, i < ts.length else {
                fail("\(what): index \(i) out of bounds (len \(ts.length)) - substring likely not found",
                     sourceLocation: sourceLocation)
                return
            }
            if !StylerProbe.isNonBody(ts, i) {
                fail("\(what): expected mvNonBody==true at char \(i), got false", sourceLocation: sourceLocation)
            }
        }

        /// The `left`/`right` delimiter chars around a construct are non-body; interior body.
        private func expectDelimiters(_ ts: NSTextStorage, around sub: String, left: Int, right: Int,
                                      sourceLocation: SourceLocation = #_sourceLocation) {
            guard let r = requireRange(ts, of: sub, sourceLocation: sourceLocation) else { return }
            for i in 0..<left where !StylerProbe.isNonBody(ts, r.location + i) {
                fail("\(sub): left delim char \(i) should be non-body", sourceLocation: sourceLocation)
            }
            for i in 0..<right where !StylerProbe.isNonBody(ts, r.location + r.length - 1 - i) {
                fail("\(sub): right delim char \(i) should be non-body", sourceLocation: sourceLocation)
            }
            for i in left..<(r.length - right) where StylerProbe.isNonBody(ts, r.location + i) {
                fail("\(sub): interior char \(i) should be body", sourceLocation: sourceLocation)
            }
        }
    }
}
