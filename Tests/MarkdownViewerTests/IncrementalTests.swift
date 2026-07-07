import AppKit
import Testing
@testable import MarkdownViewer

// MARK: - Edit-matrix model (#2)

/// One `{operation × position}` cell of the differential-oracle edit matrix.
/// Anchored by a UNIQUE substring in `matrixDoc` (+ a char offset) so each case is
/// self-locating and independently named.
struct EditCase: Sendable, CustomTestStringConvertible {
    let name: String
    /// A substring occurring exactly once in `matrixDoc`; the edit lands relative to it.
    let anchor: String
    /// Chars added to the anchor's start to reach the edit location.
    let offset: Int
    let op: EditOp
    var testDescription: String { name }
}

/// The three edit kinds, mirroring how `NSTextStorage.replaceCharacters` reports its
/// post-edit `editedRange` to `NSTextStorageDelegate` (which is what the live editor
/// forwards to `applyIncremental`): insert/replace → `{loc, insertedLen}`; delete → `{loc, 0}`.
enum EditOp: Sendable {
    case insert(String)
    case delete(Int)
    case replace(Int, String)   // replace `Int` chars at loc with the string
}

/// A single comprehensive document exercised by the whole matrix: heading, paragraph,
/// blockquote, unordered list (first / middle / last items), ordered list, a table
/// (header + separator + two body rows), a fenced code block (multi-line body), a
/// horizontal rule, and a trailing paragraph. Anchor substrings below are all unique.
let matrixDoc: String = [
    "# Heading Alpha",                              // heading line
    "",
    "First paragraph sentence with several words inside.",   // paragraph
    "",
    "> A quoted blockquote line of prose.",         // blockquote
    "",
    "- bullet first",                               // list FIRST-item boundary
    "- bullet middle",                              // list item text
    "- bullet last",                                // list LAST-item boundary
    "",
    "1. ordered uno",                               // ordered list item
    "2. ordered dos",
    "",
    "| Head A | Head B |",                          // table header
    "|--------|--------|",                          // table separator
    "| cella | cellb |",                            // table body row 1
    "| cellc | celld |",                            // table body row 2
    "",
    "```lang",                                      // fence boundary line
    "code alpha line",                              // fence body
    "code beta line",
    "```",
    "",
    "Final closing paragraph.",
].joined(separator: "\n")

/// The `{operation × position}` matrix. Every case asserts the differential oracle:
/// after the edit + `applyIncremental`, the storage's per-char attributes equal a
/// full `apply` of the resulting text - whether or not the edit stayed incremental.
let editMatrixCases: [EditCase] = [
    // ── INSERT a plain char across every position ──────────────────────────────
    EditCase(name: "insert/paragraph-mid",         anchor: "several",           offset: 3, op: .insert("X")),
    EditCase(name: "insert/heading-line",          anchor: "Alpha",             offset: 2, op: .insert("X")),
    EditCase(name: "insert/list-item-text",        anchor: "bullet middle",     offset: 9, op: .insert("X")),
    EditCase(name: "insert/list-first-boundary",   anchor: "bullet first",      offset: 9, op: .insert("X")),
    EditCase(name: "insert/list-last-boundary",    anchor: "bullet last",       offset: 9, op: .insert("X")),
    EditCase(name: "insert/ordered-item",          anchor: "ordered uno",       offset: 9, op: .insert("X")),
    EditCase(name: "insert/quote-line",            anchor: "quoted blockquote", offset: 3, op: .insert("X")),
    EditCase(name: "insert/table-header-cell",     anchor: "Head A",            offset: 2, op: .insert("X")),
    EditCase(name: "insert/table-body-cell",       anchor: "cella",             offset: 2, op: .insert("X")),
    EditCase(name: "insert/fence-body",            anchor: "code alpha",        offset: 2, op: .insert("X")),
    EditCase(name: "insert/fence-boundary-line",   anchor: "lang",              offset: 1, op: .insert("X")),

    // ── DELETE a char across representative positions ──────────────────────────
    EditCase(name: "delete/paragraph-mid",         anchor: "several",           offset: 3, op: .delete(1)),
    EditCase(name: "delete/heading-line",          anchor: "Alpha",             offset: 2, op: .delete(1)),
    EditCase(name: "delete/list-item-text",        anchor: "bullet middle",     offset: 9, op: .delete(1)),
    EditCase(name: "delete/quote-line",            anchor: "quoted blockquote", offset: 3, op: .delete(1)),
    EditCase(name: "delete/table-body-cell",       anchor: "cella",             offset: 2, op: .delete(1)),
    EditCase(name: "delete/fence-body",            anchor: "code alpha",        offset: 2, op: .delete(1)),

    // ── REPLACE a selection across representative positions ────────────────────
    EditCase(name: "replace/paragraph-word",       anchor: "several",           offset: 0, op: .replace(7, "MANY")),
    EditCase(name: "replace/table-header-cell",    anchor: "Head A",            offset: 0, op: .replace(4, "Col")),
    EditCase(name: "replace/table-body-cell",      anchor: "cella",             offset: 0, op: .replace(5, "zz")),
    EditCase(name: "replace/list-item-word",       anchor: "bullet middle",     offset: 7, op: .replace(6, "mid")),
    EditCase(name: "replace/fence-body-word",      anchor: "code alpha",        offset: 5, op: .replace(5, "beta")),

    // ── STRUCTURE-BREAKING insert of a table pipe `|` ──────────────────────────
    EditCase(name: "structbreak/table-body-cell",  anchor: "cellb",             offset: 2, op: .insert("|")),
    EditCase(name: "structbreak/paragraph",        anchor: "several",           offset: 3, op: .insert("|")),
]

extension StylerSuites {

    /// Case 15b (crown): `applyIncremental` must produce byte-for-byte the same
    /// attributes as a full `apply` of the resulting text (the differential oracle),
    /// and must honour its documented full-restyle fallback contract (return value).
    /// #2 expands the oracle into an edit matrix; #3 makes each fallback also prove
    /// its result equals a full apply.
    @Suite(.serialized)
    struct IncrementalTests {
        init() { pinBodyPointSize() }

        // MARK: #2 - differential-oracle edit matrix

        /// {insert, delete, replace} × {paragraph, heading, list item, list first/last
        /// boundary, quote, table header cell, table body cell, structure-break pipe,
        /// fence body, fence boundary line}. Each case: full-apply the original, do the
        /// edit, run `applyIncremental`, then assert every char's attributes equal a
        /// full apply of the final text. We do NOT presume incremental vs fallback -
        /// the oracle is the FINAL styling, either way.
        @Test(arguments: editMatrixCases)
        func editMatrixEqualsFull(_ c: EditCase) {
            let original = matrixDoc as NSString
            let base = original.range(of: c.anchor)
            guard base.location != NSNotFound else {
                fail("edit '\(c.name)': anchor '\(c.anchor)' not found in matrix doc")
                return
            }
            let loc = base.location + c.offset

            // Translate the op into (rangeToReplace, replacementString, postEditLen).
            let editRange: NSRange
            let replacement: String
            let editedLen: Int
            switch c.op {
            case .insert(let s):
                editRange = NSRange(location: loc, length: 0)
                replacement = s
                editedLen = (s as NSString).length
            case .delete(let n):
                editRange = NSRange(location: loc, length: n)
                replacement = ""
                editedLen = 0
            case .replace(let n, let s):
                editRange = NSRange(location: loc, length: n)
                replacement = s
                editedLen = (s as NSString).length
            }
            guard loc >= 0, NSMaxRange(editRange) <= original.length else {
                fail("edit '\(c.name)': edit range \(editRange) out of bounds (doc len \(original.length))")
                return
            }

            // B: full-style the original, apply the edit, then incremental restyle
            // with the SAME post-edit range NSTextStorage would report to the editor.
            let b = NSTextStorage(string: original as String)
            LiveMarkdownStyler.apply(to: b)
            b.replaceCharacters(in: editRange, with: replacement)
            LiveMarkdownStyler.applyIncremental(
                to: b, editedCharRange: NSRange(location: loc, length: editedLen))

            // A: full-style the resulting text from scratch.
            let finalText = original.replacingCharacters(in: editRange, with: replacement)
            let a = NSTextStorage(string: finalText)
            LiveMarkdownStyler.apply(to: a)

            expectSameAttributes(a, b, note: "edit \(c.name)")
        }

        /// #2 (cross-blank position): a REPLACE whose range spans a blank-line
        /// separator (merging the paragraph and the blockquote below it). The oracle
        /// must still hold after the block merge.
        @Test func crossBlankLineReplaceEqualsFull() {
            let original = matrixDoc as NSString
            let startR = original.range(of: "words inside")
            let endR = original.range(of: "quoted blockquote")
            guard startR.location != NSNotFound, endR.location != NSNotFound else {
                fail("cross-blank: anchors not found in matrix doc"); return
            }
            let start = startR.location
            let end = endR.location + endR.length   // spans across the "\n\n" between blocks
            let editRange = NSRange(location: start, length: end - start)
            let replacement = "MERGED"

            let b = NSTextStorage(string: original as String)
            LiveMarkdownStyler.apply(to: b)
            b.replaceCharacters(in: editRange, with: replacement)
            LiveMarkdownStyler.applyIncremental(
                to: b, editedCharRange: NSRange(location: start, length: (replacement as NSString).length))

            let finalText = original.replacingCharacters(in: editRange, with: replacement)
            let a = NSTextStorage(string: finalText)
            LiveMarkdownStyler.apply(to: a)

            expectSameAttributes(a, b, note: "cross-blank replace")
        }

        /// #2 (two consecutive edits): two adjacent single-char inserts, each followed
        /// by its own `applyIncremental` (the second range abuts the first). Verifies
        /// the merged/back-to-back scope still equals a full apply of the final text.
        @Test func consecutiveEditsEqualFull() {
            let original = matrixDoc as NSString
            let anchor = original.range(of: "several")
            guard anchor.location != NSNotFound else {
                fail("consecutive: anchor 'several' not found"); return
            }
            let loc = anchor.location + 3

            let b = NSTextStorage(string: original as String)
            LiveMarkdownStyler.apply(to: b)
            // Edit 1: insert "Q".
            b.replaceCharacters(in: NSRange(location: loc, length: 0), with: "Q")
            LiveMarkdownStyler.applyIncremental(to: b, editedCharRange: NSRange(location: loc, length: 1))
            // Edit 2: insert "W" immediately after (adjacent range).
            b.replaceCharacters(in: NSRange(location: loc + 1, length: 0), with: "W")
            LiveMarkdownStyler.applyIncremental(to: b, editedCharRange: NSRange(location: loc + 1, length: 1))

            let finalText = original.replacingCharacters(in: NSRange(location: loc, length: 0), with: "QW")
            let a = NSTextStorage(string: finalText)
            LiveMarkdownStyler.apply(to: a)

            expectSameAttributes(a, b, note: "two consecutive inserts")
        }

        /// #2 (idempotency): running the FULL styler twice over the same text must
        /// produce the same attributes as running it once - the pass must not
        /// accumulate/compound state on re-application.
        @Test func idempotentDoubleApply() {
            let once = NSTextStorage(string: matrixDoc)
            LiveMarkdownStyler.apply(to: once)

            let twice = NSTextStorage(string: matrixDoc)
            LiveMarkdownStyler.apply(to: twice)
            LiveMarkdownStyler.apply(to: twice)

            expectSameAttributes(once, twice, note: "apply twice == once")
        }

        /// A plain-char insertion in a paragraph must stay on the INCREMENTAL path
        /// (return true) AND match a full apply - pins that the fast path is actually
        /// exercised, not silently always falling back.
        @Test func plainParagraphInsertStaysIncremental() {
            let original = matrixDoc as NSString
            let anchor = original.range(of: "several")
            guard anchor.location != NSNotFound else { fail("anchor 'several' not found"); return }
            let loc = anchor.location + 3

            let b = NSTextStorage(string: original as String)
            LiveMarkdownStyler.apply(to: b)
            b.replaceCharacters(in: NSRange(location: loc, length: 0), with: "Z")
            let didIncremental = LiveMarkdownStyler.applyIncremental(
                to: b, editedCharRange: NSRange(location: loc, length: 1))
            #expect(didIncremental, "plain-char insertion should stay incremental")

            let finalText = original.replacingCharacters(in: NSRange(location: loc, length: 0), with: "Z")
            let a = NSTextStorage(string: finalText)
            LiveMarkdownStyler.apply(to: a)
            expectSameAttributes(a, b, note: "plain paragraph insert stays incremental")
        }

        // MARK: #3 - fallback contract: return value AND resulting attributes

        // Structural edits fall back to a full restyle (return false) AND the storage
        // must equal a full apply of the final text (proved inside `expectFallback`).
        @Test func newlineInsertFallsBack()   { expectFallback(insert: "\n") }
        @Test func fenceEditFallsBack()       { expectFallback(insert: "```") }
        @Test func pipeInsertFallsBack()      { expectFallback(insert: "|") }

        // Marker-run fallback. CHARACTERIZATION FINDING: `regionHasMarkerRun` undercounts
        // by one - a marker run whose first char is preceded (within the ±2 window) by a
        // NON-marker char is counted one short. So inserting exactly "---" (3) after a
        // space stays INCREMENTAL, while "----" (4) trips the >=3 threshold and falls back.
        // We pin BOTH the real threshold and the undercount below.
        @Test func markerRun4InsertFallsBack() { expectFallback(insert: "----") }

        // The off-by-one: a plain "---" pasted mid-paragraph is NOT treated as structural
        // (returns true / incremental). It is still styled correctly (incremental == full),
        // because a mid-line "---" is literal paragraph text, so the quirk is benign here.
        @Test func markerRun3MidTextStaysIncremental() {
            let original = fallbackSample as NSString
            guard let insertLoc = firstLoc(original, "here") else { return }
            let b = NSTextStorage(string: original as String)
            LiveMarkdownStyler.apply(to: b)
            b.replaceCharacters(in: NSRange(location: insertLoc, length: 0), with: "---")
            let didIncremental = LiveMarkdownStyler.applyIncremental(
                to: b, editedCharRange: NSRange(location: insertLoc, length: 3))
            #expect(didIncremental, "3-dash mid-text insert is undercounted, stays incremental")

            let finalText = original.replacingCharacters(in: NSRange(location: insertLoc, length: 0), with: "---")
            let a = NSTextStorage(string: finalText)
            LiveMarkdownStyler.apply(to: a)
            expectSameAttributes(a, b, note: "3-dash mid-text (benign incremental)")   // benign: incremental == full
        }

        // After a fallback the storage still equals a full apply of its final text.
        @Test func fallbackStillEqualsFull() {
            let original = fallbackSample as NSString
            guard let insertLoc = firstLoc(original, "here") else { return }
            let b = NSTextStorage(string: original as String)
            LiveMarkdownStyler.apply(to: b)
            b.replaceCharacters(in: NSRange(location: insertLoc, length: 0), with: "\n\n")
            let didIncremental = LiveMarkdownStyler.applyIncremental(
                to: b, editedCharRange: NSRange(location: insertLoc, length: 2))
            #expect(!didIncremental)

            let finalText = original.replacingCharacters(in: NSRange(location: insertLoc, length: 0), with: "\n\n")
            let a = NSTextStorage(string: finalText)
            LiveMarkdownStyler.apply(to: a)
            expectSameAttributes(a, b, note: "fallback newline still equals full")
        }

        // MARK: helpers

        /// A small paragraph sample carrying the anchor word "here", used by the
        /// fallback/marker-run characterizations (kept separate from `matrixDoc` so the
        /// delicate off-by-one marker-run behaviour keeps its exact surrounding chars).
        private let fallbackSample = [
            "# Title",
            "",
            "Some paragraph text here.",
            "",
            "- item one",
            "- item two",
            "",
            "More text.",
        ].joined(separator: "\n")

        /// #6: resolve a substring in an NSString, failing clearly on `NSNotFound`.
        private func firstLoc(_ ns: NSString, _ sub: String,
                              sourceLocation: SourceLocation = #_sourceLocation) -> Int? {
            let loc = ns.range(of: sub).location
            if loc == NSNotFound {
                fail("substring '\(sub)' not found in test sample", sourceLocation: sourceLocation)
                return nil
            }
            return loc
        }

        /// #3: insert `insert` into a paragraph word and assert `applyIncremental`
        /// returns `false` (fell back to a full restyle) AND that the storage now
        /// equals a full apply of the final text - so a fallback that "returned false
        /// but forgot to re-style" would be caught, not passed.
        private func expectFallback(insert: String, sourceLocation: SourceLocation = #_sourceLocation) {
            let original = fallbackSample as NSString
            guard let insertLoc = firstLoc(original, "here", sourceLocation: sourceLocation) else { return }
            let b = NSTextStorage(string: original as String)
            LiveMarkdownStyler.apply(to: b)
            b.replaceCharacters(in: NSRange(location: insertLoc, length: 0), with: insert)
            let didIncremental = LiveMarkdownStyler.applyIncremental(
                to: b, editedCharRange: NSRange(location: insertLoc, length: (insert as NSString).length))
            if didIncremental {
                fail("inserting \"\(insert)\" should force a full restyle (returned true)",
                     sourceLocation: sourceLocation)
            }
            // The result must actually equal a full apply of the final text.
            let finalText = original.replacingCharacters(in: NSRange(location: insertLoc, length: 0), with: insert)
            let a = NSTextStorage(string: finalText)
            LiveMarkdownStyler.apply(to: a)
            expectSameAttributes(a, b, note: "fallback insert \"\(insert)\"", sourceLocation: sourceLocation)
        }
    }
}
