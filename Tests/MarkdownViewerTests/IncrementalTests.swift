import AppKit
import Testing
@testable import MarkdownViewer

/// Case 15b (crown): `applyIncremental` must produce byte-for-byte the same
/// attributes as a full `apply` of the resulting text (differential oracle), and
/// must honour its documented full-restyle fallback contract (return value).
@Suite(.serialized)
struct IncrementalTests {
    init() { pinBodyPointSize() }

    private let sample = [
        "# Title",
        "",
        "Some paragraph text here.",
        "",
        "- item one",
        "- item two",
        "",
        "More text.",
    ].joined(separator: "\n")

    // Differential oracle: incremental restyle of a plain-char insertion == full.
    @Test func incrementalEqualsFullOnPlainInsert() {
        let original = sample as NSString
        let insertLoc = original.range(of: "paragraph").location
        #expect(insertLoc != NSNotFound)

        // B: full-style the original, then insert a plain char and restyle scoped.
        let b = NSTextStorage(string: original as String)
        LiveMarkdownStyler.apply(to: b)
        b.replaceCharacters(in: NSRange(location: insertLoc, length: 0), with: "Z")
        let didIncremental = LiveMarkdownStyler.applyIncremental(
            to: b, editedCharRange: NSRange(location: insertLoc, length: 1))
        #expect(didIncremental, "plain-char insertion should stay incremental")

        // A: full-style the resulting text from scratch.
        let finalText = original.replacingCharacters(in: NSRange(location: insertLoc, length: 0), with: "Z")
        let a = NSTextStorage(string: finalText)
        LiveMarkdownStyler.apply(to: a)

        expectSameAttributes(a, b)
    }

    // Fallback contract: structural edits fall back to a full restyle (return false).
    @Test func newlineInsertFallsBack()   { expectFallback(insert: "\n") }
    @Test func fenceEditFallsBack()       { expectFallback(insert: "```") }
    @Test func pipeInsertFallsBack()      { expectFallback(insert: "|") }

    // Marker-run fallback. CHARACTERIZATION FINDING: `regionHasMarkerRun` undercounts
    // by one — a marker run whose first char is preceded (within the ±2 window) by a
    // NON-marker char is counted one short. So inserting exactly "---" (3) after a
    // space stays INCREMENTAL, while "----" (4) trips the >=3 threshold and falls back.
    // We pin BOTH the real threshold and the undercount below.
    @Test func markerRun4InsertFallsBack() { expectFallback(insert: "----") }

    // The off-by-one: a plain "---" pasted mid-paragraph is NOT treated as structural
    // (returns true / incremental). It is still styled correctly (incremental == full),
    // because a mid-line "---" is literal paragraph text, so the quirk is benign here.
    @Test func markerRun3MidTextStaysIncremental() {
        let original = sample as NSString
        let insertLoc = original.range(of: "here").location
        let b = NSTextStorage(string: original as String)
        LiveMarkdownStyler.apply(to: b)
        b.replaceCharacters(in: NSRange(location: insertLoc, length: 0), with: "---")
        let didIncremental = LiveMarkdownStyler.applyIncremental(
            to: b, editedCharRange: NSRange(location: insertLoc, length: 3))
        #expect(didIncremental, "3-dash mid-text insert is undercounted, stays incremental")

        let finalText = original.replacingCharacters(in: NSRange(location: insertLoc, length: 0), with: "---")
        let a = NSTextStorage(string: finalText)
        LiveMarkdownStyler.apply(to: a)
        expectSameAttributes(a, b)   // benign: incremental result equals full
    }

    // After a fallback the storage still equals a full apply of its final text.
    @Test func fallbackStillEqualsFull() {
        let original = sample as NSString
        let insertLoc = original.range(of: "here").location
        let b = NSTextStorage(string: original as String)
        LiveMarkdownStyler.apply(to: b)
        b.replaceCharacters(in: NSRange(location: insertLoc, length: 0), with: "\n\n")
        let didIncremental = LiveMarkdownStyler.applyIncremental(
            to: b, editedCharRange: NSRange(location: insertLoc, length: 2))
        #expect(!didIncremental)

        let finalText = original.replacingCharacters(in: NSRange(location: insertLoc, length: 0), with: "\n\n")
        let a = NSTextStorage(string: finalText)
        LiveMarkdownStyler.apply(to: a)
        expectSameAttributes(a, b)
    }

    // MARK: helpers

    /// Insert `insert` into a paragraph word and assert `applyIncremental` returns
    /// `false` (fell back to a full restyle).
    private func expectFallback(insert: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let original = sample as NSString
        let insertLoc = original.range(of: "here").location
        let b = NSTextStorage(string: original as String)
        LiveMarkdownStyler.apply(to: b)
        b.replaceCharacters(in: NSRange(location: insertLoc, length: 0), with: insert)
        let didIncremental = LiveMarkdownStyler.applyIncremental(
            to: b, editedCharRange: NSRange(location: insertLoc, length: (insert as NSString).length))
        if didIncremental {
            fail("inserting \"\(insert)\" should force a full restyle", sourceLocation: sourceLocation)
        }
    }

    /// Assert two storages carry identical attributes at every character.
    private func expectSameAttributes(_ a: NSTextStorage, _ b: NSTextStorage,
                                      sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(a.length == b.length, "length mismatch", sourceLocation: sourceLocation)
        #expect(a.string == b.string, "string mismatch", sourceLocation: sourceLocation)
        let n = min(a.length, b.length)
        for i in 0..<n {
            let da = a.attributes(at: i, effectiveRange: nil) as NSDictionary
            let db = b.attributes(at: i, effectiveRange: nil) as NSDictionary
            if !da.isEqual(db) {
                fail("attribute mismatch at \(i): full=\(da) incremental=\(db)", sourceLocation: sourceLocation)
                return
            }
        }
    }
}
