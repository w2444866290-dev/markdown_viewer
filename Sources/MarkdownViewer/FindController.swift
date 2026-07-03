import AppKit

/// Find/replace engine for NSTextView. Owns search state (matches, index),
/// applies/clears temporary highlights, and coordinates navigation.
final class FindController {
    weak var textView: NSTextView?
    /// RAW storage ranges of the current matches. "所见即所搜": we run the regex
    /// over the clean BODY text (see `BodyMap`), then map each body-space match
    /// back to the raw NSRange it occupies in the live storage, so highlight /
    /// scroll / replace all keep operating on real storage coordinates as before.
    var matches: [NSRange] = []
    var currentIndex = 0

    /// Debug-only (AppEnv.debug): one-line summary of the last search shown on the
    /// DIAG HUD (raw vs body-filtered counts + independent zeroRect/inCode health
    /// counters). Empty in USER mode. The Coordinator pushes it into the DiagModel.
    private(set) var lastDebugDiagnostic = ""

    /// Debug-only: the full per-match dump (summary + one line per match) copied to
    /// the pasteboard when the HUD is clicked, so the readout can be pasted whole.
    private(set) var lastDebugDetail = ""

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

        // "所见即所搜": search the clean body/reading text only. Build the body ↔ raw
        // map from the live storage right before matching so it always reflects the
        // current styling (search() already re-scans on any query/option change and
        // after a replace, so no observer is needed). Then run the SAME regex over
        // the body string and map every body-space match back to a raw storage range.
        guard let storage = tv.textStorage else {
            MVLog.info("find search query=\"\(opts.query)\" matches=0 (no storage)", category: "find")
            return
        }
        let bodyMap = BodyMap(storage: storage)
        let body = bodyMap.bodyString
        let full = NSRange(location: 0, length: (body as NSString).length)
        matches = regex.matches(in: body, range: full)
            .filter { $0.range.length > 0 }
            .compactMap { bodyMap.rawRange(for: $0.range) }
        currentIndex = 0
        MVLog.info("find search query=\"\(opts.query)\" matches=\(matches.count)", category: "find")
        if AppEnv.debug { recordDebugDiagnostic(query: opts.query, regex: regex, storage: storage) }
        applyHighlights()
        scrollToCurrent()
    }

    /// DEBUG only: build the DIAG-HUD summary + a click-to-copy per-match dump.
    ///
    /// The summary compares RAW occurrences (regex over the whole storage string)
    /// against the body-filtered `matches` (`filtered` = raw hits dropped as
    /// non-body). The two health counters are deliberately INDEPENDENT of the body
    /// map's own exclusion rule, so they can actually catch a problem the filter
    /// missed (a self-referential check that reused the size rule could not):
    ///   - `zeroRect` = shown matches whose ACTUAL rendered glyph rect (measured by
    ///     the layout manager) is degenerate. That is ground-truth invisibility -
    ///     it catches any hiding mechanism (size, clear color, collapsed line
    ///     height), not just the font-size heuristic the body map uses.
    ///   - `inCode` = shown matches sitting inside a code block / inline-code pill,
    ///     where the find highlight is re-stamped over an opaque card fill.
    /// The detail dump lists each match's offset, code flag, font size, foreground
    /// alpha, measured rect height, and context - everything needed to see WHY a
    /// match may look unhighlighted or unreachable, without more screenshots.
    private func recordDebugDiagnostic(query: String, regex: NSRegularExpression, storage: NSTextStorage) {
        let raw = storage.string as NSString
        let rawCount = regex.matches(in: storage.string, range: NSRange(location: 0, length: raw.length))
            .filter { $0.range.length > 0 }.count
        let lm = textView?.layoutManager
        let container = textView?.textContainer
        var zeroRect = 0, inCode = 0
        var lines: [String] = []
        for (i, r) in matches.enumerated() where r.location < storage.length {
            let a = storage.attributes(at: r.location, effectiveRange: nil)
            let size = (a[.font] as? NSFont)?.pointSize ?? -1
            let fgA = (a[.foregroundColor] as? NSColor)?.alphaComponent ?? -1
            let code = (a[.mvCodeBlock] as? Bool) == true || (a[.mvInlineCode] as? Bool) == true
            var rectH: CGFloat = -1
            if let lm, let container {
                let g = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
                rectH = lm.boundingRect(forGlyphRange: g, in: container).height
            }
            if rectH >= 0, rectH < 3 { zeroRect += 1 }
            if code { inCode += 1 }
            if lines.count < 40 {
                let cs = max(0, r.location - 10), ce = min(raw.length, NSMaxRange(r) + 10)
                let ctx = raw.substring(with: NSRange(location: cs, length: ce - cs))
                    .replacingOccurrences(of: "\n", with: "\\n")
                lines.append("#\(i) @\(r.location) code=\(code ? "Y" : "n") sz=\(String(format: "%.1f", size)) fgA=\(String(format: "%.2f", fgA)) rectH=\(String(format: "%.1f", rectH)) '\(ctx)'")
            }
        }
        lastDebugDiagnostic = "FIND \"\(query)\": \(matches.count) shown · \(rawCount) raw · \(rawCount - matches.count) filtered · zeroRect \(zeroRect) · inCode \(inCode)"
        var detail = lastDebugDiagnostic + "\n" + lines.joined(separator: "\n")
        if matches.count > 40 { detail += "\n… (\(matches.count - 40) more)" }
        lastDebugDetail = detail
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
        let range = matches[currentIndex]
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
        for m in matches.reversed() where NSMaxRange(m) <= storage.length {
            storage.replaceCharacters(in: m, with: text)
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
    ///
    /// #search-flash (delete/empty query): `removeTemporaryAttribute` alone does
    /// NOT repaint (same AppKit quirk OutlineController.washHeading documents), so
    /// the cleared tint lingered until some *other* event forced a full-viewport
    /// redraw — which then flashed every previously-highlighted glyph at once. That
    /// is why TYPING (query grows → `applyHighlights` immediately re-paints via
    /// `addTemporaryAttributes`) looked clean but DELETING/EMPTYING (clear-only,
    /// nothing re-paints) flashed. Fix: commit the removal immediately by
    /// invalidating exactly the cleared ranges — incremental, never whole-document.
    private func clearHighlights() {
        guard let lm = textView?.layoutManager else { highlightedRanges = []; return }
        let length = lm.textStorage?.length ?? 0
        for r in highlightedRanges {
            guard let safe = clamped(r, max: length) else { continue }
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: safe)
            lm.invalidateDisplay(forCharacterRange: safe)
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
            guard let safe = clamped(m, max: length) else { continue }
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
        guard let safe = clamped(matches[currentIndex], max: length) else { return }
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

/// Body-text ↔ raw-storage map for "所见即所搜" find. Walks the live NSTextStorage
/// once and concatenates only the characters the styler did NOT mark `.mvNonBody`
/// (see MarkdownStyling) into `bodyString` - the clean reading text. `rawLocations`
/// runs parallel to `bodyString`'s UTF-16 units: `rawLocations[k]` is the raw
/// storage offset of the k-th body unit. That lets a body-space match range be
/// mapped back to the raw NSRange it occupies, so highlight / scroll / replace keep
/// working in real storage coordinates. Everything stays in UTF-16 / NSRange space,
/// so surrogate pairs (2 units) map correctly - each unit carries its own location.
private struct BodyMap {
    let bodyString: String
    /// Raw storage offset of each UTF-16 unit in `bodyString` (same count/order).
    private let rawLocations: [Int]

    init(storage: NSTextStorage) {
        let ns = storage.string as NSString
        let length = ns.length
        guard length > 0 else {
            bodyString = ""
            rawLocations = []
            return
        }
        // Read the whole backing store once (character(at:) in a tight loop can be
        // O(n) per call on some string backings); then keep only body units.
        var all = [unichar](repeating: 0, count: length)
        ns.getCharacters(&all, range: NSRange(location: 0, length: length))
        var chars: [unichar] = []
        chars.reserveCapacity(length)
        var locs: [Int] = []
        locs.reserveCapacity(length)
        // A character counts as searchable body text iff BOTH hold:
        //   1. it is NOT stamped `.mvNonBody` - that marks VISIBLE-but-structural
        //      runs (list/quote markers, link URLs, image alt, code-fence language
        //      label) the styler wants excluded even though they render, AND
        //   2. it is actually VISIBLE. This second guard is a robust safety net:
        //      every truly-hidden markup run is collapsed to a ~zero-width glyph
        //      (font size ~1) and/or painted clear, so we skip anything that tiny
        //      or transparent EVEN IF some styling site forgot to stamp `.mvNonBody`.
        //      Without it an invisible marker could be "matched" yet show no visible
        //      highlight and refuse to scroll (find hit a glyph the user can't see).
        storage.enumerateAttributes(in: NSRange(location: 0, length: length), options: []) { attrs, range, _ in
            if (attrs[.mvNonBody] as? Bool) == true { return }
            let size = (attrs[.font] as? NSFont)?.pointSize ?? 12
            if size <= 1.5 { return }
            if let fg = attrs[.foregroundColor] as? NSColor, fg.alphaComponent < 0.02 { return }
            for i in range.location..<(range.location + range.length) {
                chars.append(all[i])
                locs.append(i)
            }
        }
        bodyString = String(utf16CodeUnits: chars, count: chars.count)
        rawLocations = locs
    }

    /// Map a body-space NSRange (into `bodyString`) back to the raw storage NSRange
    /// it spans. `[a, b)` → `[rawLocations[a], rawLocations[b-1] + 1)`. The mapped
    /// span may include interleaved hidden markup (e.g. matching "hello world" in
    /// raw `**hello** world` covers the hidden `**`) - that's intended ("replace
    /// what you see"). Returns nil for an empty or out-of-range body range.
    func rawRange(for bodyRange: NSRange) -> NSRange? {
        guard bodyRange.length > 0 else { return nil }
        let start = bodyRange.location
        let lastUnit = NSMaxRange(bodyRange) - 1
        guard start >= 0, lastUnit < rawLocations.count else { return nil }
        let rawStart = rawLocations[start]
        let rawEnd = rawLocations[lastUnit] + 1   // exclusive end just past the last unit
        guard rawEnd > rawStart else { return nil }
        return NSRange(location: rawStart, length: rawEnd - rawStart)
    }
}
