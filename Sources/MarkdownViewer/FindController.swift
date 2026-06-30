import AppKit

/// Find/replace engine for NSTextView. Owns search state (matches, index),
/// applies/clears temporary highlights, and coordinates navigation.
final class FindController {
    weak var textView: NSTextView?
    var matches: [NSTextCheckingResult] = []
    var currentIndex = 0

    /// True when the last search used regex mode and the pattern failed to compile.
    private(set) var lastPatternInvalid = false

    /// Ranges we wrote temporary `.backgroundColor` to on the previous
    /// `applyHighlights()`. We clear ONLY these (not the whole document) on the
    /// next search, which avoids the full-document attribute sweep that made the
    /// document "flash white" on every keystroke.
    private var highlightedRanges: [NSRange] = []

    /// The options that produced the current `matches`. Lets us skip the regex
    /// re-scan when `search` is re-fired with an unchanged query/options (e.g. a
    /// duplicate `onSearch` from SwiftUI) — pure redundant work.
    private var lastSearchedOptions: Options?

    struct Options: Equatable {
        var query = ""
        var caseSensitive = false
        var wholeWord = false
        var useRegex = false
    }

    var isEmpty: Bool { matches.isEmpty }

    func search(_ opts: Options) {
        // Skip the re-scan entirely when nothing relevant changed. Navigation
        // and toggles route through their own paths; this only guards a redundant
        // same-query `onSearch` re-fire.
        if opts == lastSearchedOptions { return }

        clearHighlights()
        matches = []
        currentIndex = 0
        lastPatternInvalid = false
        lastSearchedOptions = opts

        guard !opts.query.isEmpty, let tv = textView else {
            MVLog.info("find search query=\"\(opts.query)\" matches=0", category: "find")
            return
        }

        var pattern = opts.query
        if !opts.useRegex {
            pattern = NSRegularExpression.escapedPattern(for: pattern)
            if opts.wholeWord { pattern = "\\b\(pattern)\\b" }
        }
        var regOpts: NSRegularExpression.Options = []
        if !opts.caseSensitive { regOpts.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: regOpts) else {
            // Only an illegal user-supplied regex is reportable; escaped patterns never fail.
            if opts.useRegex { lastPatternInvalid = true }
            MVLog.warn("find search invalid regex query=\"\(opts.query)\"", category: "find")
            return
        }

        let ns = tv.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        matches = regex.matches(in: tv.string, range: full).filter { $0.range.length > 0 }
        currentIndex = 0
        MVLog.info("find search query=\"\(opts.query)\" matches=\(matches.count)", category: "find")
        applyHighlights()
        scrollToCurrent()
    }

    func navigate(_ delta: Int) {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex + delta + matches.count) % matches.count
        MVLog.info("find navigate delta=\(delta) index=\(currentIndex)/\(matches.count)", category: "find")
        applyHighlights()
        scrollToCurrent()
    }

    func replaceCurrent(with text: String, restyle: () -> Void, redo: () -> Void) {
        guard matches.indices.contains(currentIndex),
              let tv = textView, let storage = tv.textStorage else { return }
        let range = matches[currentIndex].range
        // Bounds-safety: a stale match range (e.g. document mutated out from
        // under us) would make replaceCharacters throw. Skip instead.
        guard NSMaxRange(range) <= storage.length else {
            MVLog.warn("find replace skipped stale range \(NSStringFromRange(range)) len=\(storage.length)", category: "find")
            return
        }
        guard tv.shouldChangeText(in: range, replacementString: text) else { return }
        MVLog.info("find replace 1 at index=\(currentIndex) range=\(NSStringFromRange(range))", category: "find")
        // The document is about to change; force the upcoming re-search to re-scan.
        lastSearchedOptions = nil
        storage.replaceCharacters(in: range, with: text)
        tv.didChangeText()
        restyle()
        redo()  // re-search after mutation
        Task { @MainActor in Toaster.shared.flash("已替换 1 处") }
    }

    func replaceAll(with text: String, restyle: () -> Void) {
        guard !matches.isEmpty, let tv = textView, let storage = tv.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        guard tv.shouldChangeText(in: full, replacementString: nil) else { return }
        let count = matches.count
        MVLog.info("find replaceAll count=\(count)", category: "find")
        // We're rewriting ranges out from under our highlights; drop the cache so
        // a later same-query search re-scans, and don't try to clear stale spans.
        lastSearchedOptions = nil
        highlightedRanges = []
        // Reversed so each replacement doesn't shift the offsets of the ones still
        // to come; still bounds-guard each range against the live storage length.
        for m in matches.reversed() where NSMaxRange(m.range) <= storage.length {
            storage.replaceCharacters(in: m.range, with: text)
        }
        tv.didChangeText()
        restyle()
        matches = []
        currentIndex = 0
        Task { @MainActor in Toaster.shared.flash("已替换 " + String(count) + " 处") }
    }

    /// Incremental clear: drop the temporary `.backgroundColor` ONLY over the
    /// ranges we highlighted last time — never the whole document. The previous
    /// whole-document `removeTemporaryAttribute(0..length)` on every keystroke was
    /// the cause of the "flash white" + jank. Each previous range is bounds-clamped
    /// against the live storage length so a stale range can't make AppKit throw.
    private func clearHighlights() {
        guard let lm = textView?.layoutManager else { highlightedRanges = []; return }
        let length = lm.textStorage?.length ?? 0
        for r in highlightedRanges {
            guard let safe = clamped(r, max: length) else { continue }
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: safe)
        }
        highlightedRanges = []
    }

    private func applyHighlights() {
        guard let lm = textView?.layoutManager else { return }
        clearHighlights()
        let length = lm.textStorage?.length ?? 0
        var applied: [NSRange] = []
        applied.reserveCapacity(matches.count)
        for (i, m) in matches.enumerated() {
            // Bounds-safety: skip any range that doesn't fit the live storage.
            guard let safe = clamped(m.range, max: length) else { continue }
            let c = i == currentIndex ? DesignTokens.accentStrong : DesignTokens.accentSoft
            lm.addTemporaryAttributes([.backgroundColor: c], forCharacterRange: safe)
            applied.append(safe)
        }
        // Remember exactly what we wrote so the next clear is incremental.
        highlightedRanges = applied
    }

    private func scrollToCurrent() {
        guard matches.indices.contains(currentIndex) else { return }
        let length = textView?.textStorage?.length ?? 0
        guard let safe = clamped(matches[currentIndex].range, max: length) else { return }
        textView?.scrollRangeToVisible(safe)
    }

    /// Clamp a range into `0..<max` (its tail trimmed to fit). Returns nil if the
    /// range starts past the end or has zero usable length — callers skip those.
    private func clamped(_ range: NSRange, max length: Int) -> NSRange? {
        guard range.location >= 0, range.location <= length else { return nil }
        let end = min(NSMaxRange(range), length)
        guard end > range.location else { return nil }
        return NSRange(location: range.location, length: end - range.location)
    }
}
