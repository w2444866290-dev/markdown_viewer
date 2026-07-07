import AppKit
import Testing
@testable import MarkdownViewer

extension StylerSuites {

    /// #4 (harden): test what a user can ACTUALLY find, not the `.mvNonBody` proxy.
    ///
    /// `FindController` runs its regex over a CLEAN "body only" string built by
    /// `BodyMap` (FindController.swift). A character is searchable body iff a
    /// THREE-fold predicate holds (FindController.swift:394-397):
    ///   1. NOT `.mvNonBody`         (line 394)
    ///   2. font point size  > 1.5   (line 396; missing font defaults to 12)
    ///   3. foreground alpha ≥ 0.02  (line 397)
    /// Only testing `.mvNonBody` (guards 1) misses guards 2/3, so a run that "forgot"
    /// its `.mvNonBody` stamp but is invisible would look searchable to a mvNonBody-only
    /// test yet be correctly excluded by the real code, or vice-versa.
    ///
    /// WHY WE REPLICATE THE PREDICATE INSTEAD OF CALLING THE REAL BUILDER:
    /// `BodyMap` is a `private struct` (FindController.swift:362), so `@testable import`
    /// cannot reach it. The only public entry, `FindController.search(_:)`, requires a
    /// live `NSTextView` and additionally calls `applyHighlights()` + `scrollToCurrent()`
    /// (layout-manager / scroll work) at the end (FindController.swift:123-124), which is
    /// not headless-safe under `swift test`. Making `BodyMap` internal or extracting the
    /// builder would be a Sources change, which this task forbids. So we REPLICATE the
    /// exact three-fold predicate here, anchored to lines 394-397, and assert on the
    /// resulting searchable string. See the alignment guard below.
    @Suite(.serialized)
    struct FindBodySearchTests {
        init() { pinBodyPointSize() }

        // PREDICATE ALIGNMENT GUARD. These constants mirror FindController.swift:394-397
        // (BodyMap.init). If that predicate ever changes, THESE must change in lockstep
        // or this test silently stops reflecting real find behaviour.
        private static let defaultSize: CGFloat = 12     // FindController.swift:395 (missing font → 12)
        private static let sizeFloor: CGFloat = 1.5      // FindController.swift:396 (size <= 1.5 → excluded)
        private static let alphaFloor: CGFloat = 0.02    // FindController.swift:397 (alpha < 0.02 → excluded)

        /// Faithful clone of `BodyMap`'s body-string construction (FindController.swift
        /// 393-403): concatenate exactly the UTF-16 units that pass the three-fold
        /// predicate. This is the string the user's find query actually runs against.
        private func searchableBody(_ ts: NSTextStorage) -> String {
            let ns = ts.string as NSString
            let length = ns.length
            guard length > 0 else { return "" }
            var all = [unichar](repeating: 0, count: length)
            ns.getCharacters(&all, range: NSRange(location: 0, length: length))
            var units: [unichar] = []
            units.reserveCapacity(length)
            ts.enumerateAttributes(in: NSRange(location: 0, length: length), options: []) { attrs, range, _ in
                // ---- MIRRORS FindController.swift:394-397 - keep in lockstep. ----
                if (attrs[.mvNonBody] as? Bool) == true { return }                        // :394
                let size = (attrs[.font] as? NSFont)?.pointSize ?? Self.defaultSize        // :395
                if size <= Self.sizeFloor { return }                                       // :396
                if let fg = attrs[.foregroundColor] as? NSColor, fg.alphaComponent < Self.alphaFloor { return }  // :397
                for i in range.location..<NSMaxRange(range) { units.append(all[i]) }
            }
            return String(utf16CodeUnits: units, count: units.count)
        }

        /// A comprehensive document whose READING TEXT uses only plain words (no stray
        /// punctuation), so asserting the syntax tokens are absent is meaningful.
        private let doc: String = [
            "# Heading One",
            "",
            "Plain paragraph with **boldword** and *italicword* and `inlineword` and ~~strikeword~~ here.",
            "",
            "> Quoted reading line.",
            "",
            "- listalpha entry",
            "1. numberedbeta entry",
            "",
            "| ColHead | ValHead |",
            "|---------|---------|",
            "| bodyone | bodytwo |",
            "",
            "```swift",
            "codebodyline value",
            "```",
            "",
            "---",
            "",
            "[label](http://example.com) then ![altpic](pic.png) end.",
        ].joined(separator: "\n")

        @Test func bodyWordsAreSearchableAndSyntaxIsNot() {
            let ts = StylerProbe.styled(doc)
            let body = searchableBody(ts)

            // ---- Every BODY (reading) token the user should be able to find. ----
            for word in [
                "Heading One",           // heading text
                "Plain paragraph with",  // paragraph text
                "boldword",              // bold content
                "italicword",            // italic content
                "inlineword",            // inline-code content
                "strikeword",            // strikethrough content
                "Quoted reading line",   // blockquote text
                "listalpha entry",       // unordered list item
                "numberedbeta entry",    // ordered list item
                "ColHead", "ValHead",    // table header cells
                "bodyone", "bodytwo",    // table body cells
                "codebodyline value",    // fenced-code content
                "label",                 // link label
                "end.",                  // trailing paragraph text
            ] where !body.contains(word) {
                fail("find would MISS body word '\(word)' - not present in the searchable body string")
            }

            // ---- Every SYNTAX / DECORATION token that must NOT be searchable. ----
            for token in [
                "#",                 // heading marker
                "**",                // bold delimiters
                "~~",                // strikethrough delimiters
                "`",                 // inline-code backticks
                "```",               // code-fence markers
                "swift",             // fence language label
                "[", "]", "(", ")",  // link / image bracket syntax
                "http", "example.com",  // link URL (address)
                "altpic",            // image alt text
                "pic.png",           // image path
                "|",                 // table pipes
                ">",                 // blockquote marker
                "-",                 // list dash marker + hr + table separator dashes
                "1.",                // ordered-list marker
            ] where body.contains(token) {
                fail("find would WRONGLY match syntax token '\(token)' - it leaked into the searchable body string")
            }
        }
    }
}
