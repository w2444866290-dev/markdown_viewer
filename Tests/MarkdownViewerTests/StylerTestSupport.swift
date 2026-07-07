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
// verifiable green under `swift test`, so the suite is written against it. The
// assertions and coverage are identical to the XCTest form.

/// Pure read helpers over a styled `NSTextStorage` (all UTF-16 / NSString indexed).
enum StylerProbe {

    /// Build an `NSTextStorage` from `md` and run the full styler pass over it.
    static func styled(_ md: String) -> NSTextStorage {
        let ts = NSTextStorage(string: md)
        LiveMarkdownStyler.apply(to: ts)
        return ts
    }

    static func attr(_ ts: NSTextStorage, _ key: NSAttributedString.Key, _ i: Int) -> Any? {
        ts.attribute(key, at: i, effectiveRange: nil)
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

    /// The UTF-16 range of the first occurrence of `sub`.
    static func range(of sub: String, in ts: NSTextStorage) -> NSRange {
        (ts.string as NSString).range(of: sub)
    }

    /// UTF-16 index of the first occurrence of `sub`.
    static func index(of sub: String, in ts: NSTextStorage) -> Int {
        range(of: sub, in: ts).location
    }
}

/// Pin the process-wide body font size. Called from every suite's `init()` so the
/// hidden static `LiveMarkdownStyler.bodyPointSize` can't pollute across tests.
/// Every test pins the SAME 15.5, so parallel execution never observes a drift.
func pinBodyPointSize() {
    LiveMarkdownStyler.bodyPointSize = 15.5
}

/// Record a failure with a runtime-built message at the caller's source location.
func fail(_ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
    Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
}

/// Assert every UTF-16 char in `range` has `mvNonBody == expected`.
func expectNonBody(_ ts: NSTextStorage, _ range: NSRange, _ expected: Bool, _ what: String,
                   sourceLocation: SourceLocation = #_sourceLocation) {
    guard range.length > 0 else {
        fail("\(what): empty range (substring not found?)", sourceLocation: sourceLocation)
        return
    }
    for i in range.location..<(range.location + range.length) where StylerProbe.isNonBody(ts, i) != expected {
        fail("\(what): mvNonBody at \(i) expected \(expected)", sourceLocation: sourceLocation)
    }
}

/// Assert every char of the first occurrence of `sub` has `mvNonBody == expected`.
func expectNonBody(_ ts: NSTextStorage, substring sub: String, _ expected: Bool,
                   sourceLocation: SourceLocation = #_sourceLocation) {
    expectNonBody(ts, StylerProbe.range(of: sub, in: ts), expected, "\"\(sub)\"", sourceLocation: sourceLocation)
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
