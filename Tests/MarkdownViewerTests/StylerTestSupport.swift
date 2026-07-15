import AppKit
import Testing
@testable import MarkdownViewer

// NOTE ON TEST FRAMEWORK:
// These are CHARACTERIZATION tests: they pin the CURRENT observable behaviour of
// `LiveMarkdownStyler.apply(to:)` / `applyIncremental(to:editedCharRange:)` by
// reading back the attributes actually written into an `NSTextStorage`. They read
// the REAL values, not any spec "expected" value.
//
// The spec asked for XCTest, but this environment ships only the Command Line Tools
// (no Xcode), so `XCTest.framework` is absent and cannot be built or run here. The
// bundled Swift Testing framework (`import Testing`) is the modern equivalent and is
// verifiable green under `./scripts/test.sh`, so the suite is written against it. The
// assertions and coverage are identical to the XCTest form.
//
// RUN THEM WITH:  ./scripts/test.sh   (derives the Testing.framework search paths
// from `xcode-select -p`, so it works on both a CLT-only and a full-Xcode machine).

// MARK: - Serialized parent suite (#5: body-point-size isolation)

/// #5 (harden): the single `.serialized` PARENT suite every styler characterization
/// suite nests under (each file declares `extension StylerSuites { @Suite … struct … }`).
///
/// WHY: `LiveMarkdownStyler.bodyPointSize` is a PROCESS-WIDE mutable global. Swift
/// Testing runs suites in parallel by default, so a future test that changes the body
/// size could be observed mid-change by a DIFFERENT suite reading the font - a silent
/// cross-suite pollution. `.serialized` is inherited by all descendant suites, so
/// collecting every styler suite under this one parent makes it IMPOSSIBLE for two
/// styler tests to run concurrently. Combined with `withBodyPointSize` (scoped
/// set + restore), any future "change the font size" test is fully contained.
@Suite(.serialized) enum StylerSuites {}

/// The default body point size every characterization test pins (matches the app's
/// `LiveMarkdownStyler.bodyPointSize` default of 15.5).
let defaultBodyPointSize: CGFloat = 16.5

/// Pin the process-wide body font size to the default. Called from every suite's
/// `init()` so a suite always starts from a known size. Safe because all styler
/// suites are serialized under `StylerSuites` (see above), so nothing races this.
func pinBodyPointSize() {
    LiveMarkdownStyler.bodyPointSize = defaultBodyPointSize
}

/// #5 (harden): scoped set + restore of `LiveMarkdownStyler.bodyPointSize`.
/// Saves the prior value, sets `size`, runs `body`, and ALWAYS restores on exit
/// (even if `body` records a failure). ANY future test that needs a NON-default body
/// size MUST route through this so it can never leak the global to another test.
func withBodyPointSize(_ size: CGFloat, _ body: () -> Void) {
    let previous = LiveMarkdownStyler.bodyPointSize
    LiveMarkdownStyler.bodyPointSize = size
    defer { LiveMarkdownStyler.bodyPointSize = previous }
    body()
}

// MARK: - Read helpers over a styled NSTextStorage

/// Pure read helpers over a styled `NSTextStorage` (all UTF-16 / NSString indexed).
enum StylerProbe {

    /// Build an `NSTextStorage` from `md` and run the full styler pass over it.
    static func styled(_ md: String) -> NSTextStorage {
        let ts = NSTextStorage(string: md)
        LiveMarkdownStyler.apply(to: ts)
        return ts
    }

    /// #6 (harden): NEVER read an attribute at an out-of-range / `NSNotFound` index.
    /// Returns `nil` for any index outside `[0, length)` so a stray probe can only
    /// produce a clear assertion failure upstream, never an out-of-bounds trap.
    static func attr(_ ts: NSTextStorage, _ key: NSAttributedString.Key, _ i: Int) -> Any? {
        guard i >= 0, i < ts.length else { return nil }
        return ts.attribute(key, at: i, effectiveRange: nil)
    }

    static func font(_ ts: NSTextStorage, _ i: Int) -> NSFont? {
        attr(ts, .font, i) as? NSFont
    }

    static func color(_ ts: NSTextStorage, _ i: Int) -> NSColor? {
        attr(ts, .foregroundColor, i) as? NSColor
    }

    static func pointSize(_ ts: NSTextStorage, _ i: Int) -> CGFloat? {
        font(ts, i)?.pointSize
    }

    static func cgFloat(_ ts: NSTextStorage, _ key: NSAttributedString.Key, _ i: Int) -> CGFloat? {
        (attr(ts, key, i) as? NSNumber).map { CGFloat(truncating: $0) }
    }

    /// `.mvNonBody == true`? (absent → false). This is the "所见即所搜" body-only flag.
    static func isNonBody(_ ts: NSTextStorage, _ i: Int) -> Bool {
        (attr(ts, .mvNonBody, i) as? Bool) == true
    }

    static func boolAttr(_ ts: NSTextStorage, _ key: NSAttributedString.Key, _ i: Int) -> Bool {
        (attr(ts, key, i) as? Bool) == true
    }

    /// A run is "hidden" when the styler renders it invisible: clear text at a
    /// ~1pt font (`hiddenMarkupAttributes`).
    static func isHidden(_ ts: NSTextStorage, _ i: Int) -> Bool {
        isClear(color(ts, i)) && (pointSize(ts, i).map { $0 <= 1.5 } ?? false)
    }

    static func isClear(_ c: NSColor?) -> Bool {
        guard let c else { return false }
        if c == NSColor.clear { return true }
        return c.alphaComponent == 0
    }

    static func isBold(_ ts: NSTextStorage, _ i: Int) -> Bool {
        font(ts, i)?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
    }

    static func isItalic(_ ts: NSTextStorage, _ i: Int) -> Bool {
        font(ts, i)?.fontDescriptor.symbolicTraits.contains(.italic) ?? false
    }

    /// The UTF-16 range of the first occurrence of `sub` (`{NSNotFound, 0}` if absent).
    static func range(of sub: String, in ts: NSTextStorage) -> NSRange {
        (ts.string as NSString).range(of: sub)
    }

    /// UTF-16 index of the first occurrence of `sub` (`NSNotFound` if absent).
    static func index(of sub: String, in ts: NSTextStorage) -> Int {
        range(of: sub, in: ts).location
    }
}

// MARK: - Substring resolvers (#6: guard NSNotFound before reading attributes)

/// #6 (harden): resolve `sub` to its first UTF-16 index, or record a CLEAR failure
/// (naming the missing substring) and return `nil`. Callers `guard let … else { return }`
/// so an attribute is NEVER read at `NSNotFound`.
@discardableResult
func requireIndex(_ ts: NSTextStorage, of sub: String,
                  sourceLocation: SourceLocation = #_sourceLocation) -> Int? {
    let i = StylerProbe.index(of: sub, in: ts)
    if i == NSNotFound {
        fail("substring '\(sub)' not found in styled text", sourceLocation: sourceLocation)
        return nil
    }
    return i
}

/// #6 (harden): like `requireIndex`, but returns the whole first-occurrence range.
func requireRange(_ ts: NSTextStorage, of sub: String,
                  sourceLocation: SourceLocation = #_sourceLocation) -> NSRange? {
    let r = StylerProbe.range(of: sub, in: ts)
    if r.location == NSNotFound || r.length == 0 {
        fail("substring '\(sub)' not found in styled text", sourceLocation: sourceLocation)
        return nil
    }
    return r
}

// MARK: - Assertions

/// Record a failure with a runtime-built message at the caller's source location.
func fail(_ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
    Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
}

/// Assert every UTF-16 char in `range` has `mvNonBody == expected`.
/// #6: reports the exact substring/index and the actual value on mismatch.
func expectNonBody(_ ts: NSTextStorage, _ range: NSRange, _ expected: Bool, _ what: String,
                   sourceLocation: SourceLocation = #_sourceLocation) {
    guard range.location != NSNotFound, range.length > 0 else {
        fail("\(what): substring not found (empty range) - cannot check mvNonBody", sourceLocation: sourceLocation)
        return
    }
    for i in range.location..<(range.location + range.length) where StylerProbe.isNonBody(ts, i) != expected {
        fail("\(what): mvNonBody at char \(i) expected \(expected), got \(StylerProbe.isNonBody(ts, i))",
             sourceLocation: sourceLocation)
    }
}

/// Assert every char of the first occurrence of `sub` has `mvNonBody == expected`.
func expectNonBody(_ ts: NSTextStorage, substring sub: String, _ expected: Bool,
                   sourceLocation: SourceLocation = #_sourceLocation) {
    let r = StylerProbe.range(of: sub, in: ts)
    guard r.location != NSNotFound, r.length > 0 else {
        fail("substring '\(sub)' not found in styled text - cannot check mvNonBody", sourceLocation: sourceLocation)
        return
    }
    expectNonBody(ts, r, expected, "\"\(sub)\"", sourceLocation: sourceLocation)
}

/// Approximate-equality assertion for CGFloat attribute values.
func expectClose(_ actual: CGFloat?, _ expected: CGFloat, _ what: String,
                 accuracy: CGFloat = 0.0001, sourceLocation: SourceLocation = #_sourceLocation) {
    guard let actual else {
        fail("\(what): value missing (expected \(expected))", sourceLocation: sourceLocation)
        return
    }
    if abs(actual - expected) > accuracy {
        fail("\(what): \(actual) not within \(accuracy) of \(expected)", sourceLocation: sourceLocation)
    }
}

/// Differential-oracle assertion: two storages must carry byte-for-byte identical
/// attributes at every character. Shared by the edit-matrix (#2), the fallback
/// result checks (#3), and the idempotency test. `note` tags the failure so a red
/// matrix case is instantly identifiable.
func expectSameAttributes(_ a: NSTextStorage, _ b: NSTextStorage, note: String = "",
                          sourceLocation: SourceLocation = #_sourceLocation) {
    let tag = note.isEmpty ? "" : " [\(note)]"
    guard a.length == b.length else {
        fail("length mismatch\(tag): full=\(a.length) other=\(b.length)", sourceLocation: sourceLocation)
        return
    }
    guard a.string == b.string else {
        fail("string mismatch\(tag): full=\"\(a.string)\" other=\"\(b.string)\"", sourceLocation: sourceLocation)
        return
    }
    for i in 0..<a.length {
        let da = a.attributes(at: i, effectiveRange: nil) as NSDictionary
        let db = b.attributes(at: i, effectiveRange: nil) as NSDictionary
        if !da.isEqual(db) {
            fail("attribute mismatch\(tag) at char \(i) of \(a.length): full=\(da) other=\(db)",
                 sourceLocation: sourceLocation)
            return
        }
    }
}
