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

    /// Regex-mode replace context, kept in lockstep with `matches` (same count and
    /// order). EMPTY in literal mode. Retained so a `$1`-style replacement TEMPLATE
    /// can be expanded against each match's capture groups. The groups live in BODY
    /// space (find runs over `BodyMap.bodyString`, not the raw storage), so we hold
    /// the body string + the compiled regex alongside the per-match results and let
    /// `NSRegularExpression.replacementString(for:in:offset:template:)` do the exact
    /// ICU `$n` expansion. All three are refreshed on every `search()`.
    private var matchResults: [NSTextCheckingResult] = []
    private var searchBody = ""
    private var searchRegex: NSRegularExpression?
    /// Exact raw source used to produce `matches`.
    /// Replacement is allowed only while both this source and the body projection
    /// still match the live text storage.
    private var searchStorageSnapshot: String?

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

    /// Marks cached ranges stale as soon as NSTextStorage reports a character edit.
    /// The options remain available so the next search or replacement can rebuild a
    /// fresh snapshot without depending on another UI callback.
    func invalidateForTextMutation() {
        searchStorageSnapshot = nil
    }

    func search(_ opts: Options) {
        // Skip the re-scan entirely when nothing relevant changed. Navigation
        // and toggles route through their own paths; this only guards a redundant
        // same-query `onSearch` re-fire.
        if opts == lastSearchedOptions,
           let storage = textView?.textStorage,
           searchSnapshotIsCurrent(in: storage) {
            return
        }

        clearHighlights()
        matches = []
        matchResults = []
        searchBody = ""
        searchRegex = nil
        searchStorageSnapshot = nil
        currentIndex = 0
        lastPatternInvalid = false
        lastSearchedOptions = opts

        guard !opts.query.isEmpty, let tv = textView else {
            MVLog.info("find search query=\"\(opts.query)\" matches=0", category: "find")
            return
        }

        var pattern = opts.useRegex
            ? opts.query
            : NSRegularExpression.escapedPattern(for: opts.query)
        if opts.wholeWord {
            pattern = "(?<![\\p{L}\\p{N}_])(?:\(pattern))(?![\\p{L}\\p{N}_])"
        }
        var regOpts: NSRegularExpression.Options = [.useUnicodeWordBoundaries]
        if !opts.caseSensitive { regOpts.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: regOpts) else {
            // Only an illegal user-supplied regex is reportable; escaped patterns never fail.
            if opts.useRegex { lastPatternInvalid = true }
            MVLog.warn("find search invalid regex query=\"\(opts.query)\"", category: "find")
            return
        }

        // "所见即所搜": search the clean body/reading text only. Build the body ↔ raw
        // map from the live storage right before matching so it always reflects the
        // current styling. Query changes, text mutations, and replacements all
        // invalidate the snapshot before this scan. Then run the same regex over the
        // body string and map every body-space match back to a raw storage range.
        guard let storage = tv.textStorage else {
            MVLog.info("find search query=\"\(opts.query)\" matches=0 (no storage)", category: "find")
            return
        }
        let bodyMap = BodyMap(storage: storage)
        let body = bodyMap.bodyString
        searchStorageSnapshot = storage.string
        searchBody = body
        let full = NSRange(location: 0, length: (body as NSString).length)
        // One pass, keeping raw ranges and (regex mode only) the body-space match
        // results in lockstep: a body match whose `rawRange` maps to nil is dropped
        // from BOTH, so `matchResults[i]` always describes `matches[i]`. The results
        // carry the capture groups `$1` replace needs; literal mode stores none.
        var raws: [NSRange] = []
        var results: [NSTextCheckingResult] = []
        for result in regex.matches(in: body, range: full) where result.range.length > 0 {
            guard let raw = bodyMap.rawRange(for: result.range) else { continue }
            raws.append(raw)
            if opts.useRegex { results.append(result) }
        }
        matches = raws
        if opts.useRegex {
            matchResults = results
            searchRegex = regex
        }
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

    func replaceCurrent(with text: String, restyle: () -> Void) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        refreshSearchIfSnapshotIsStale(in: storage)
        guard searchSnapshotIsCurrent(in: storage),
              matches.indices.contains(currentIndex) else {
            Task { @MainActor in Toaster.shared.flash("没有可替换的匹配") }
            return
        }
        let range = matches[currentIndex]
        // Expand `$1`/`$0`/… against this match's groups in regex mode (verbatim in
        // literal mode). Computed BEFORE the edit, while the stored body-space
        // groups still correspond to `currentIndex`.
        let replacement = expandedReplacement(at: currentIndex, template: text)
        guard tv.shouldChangeText(in: range, replacementString: replacement) else { return }
        MVLog.info("find replace 1 at index=\(currentIndex) range=\(NSStringFromRange(range))", category: "find")
        // The document is about to change, so this snapshot cannot authorize another
        // replacement even if the delegate callback is delayed.
        invalidateForTextMutation()
        storage.replaceCharacters(in: range, with: replacement)
        tv.didChangeText()
        restyle()
        refreshLastSearch()
        // Advance the cursor PAST the text we just inserted, so the next "替换" lands
        // on the following real occurrence - NOT on a match the replacement itself
        // introduced. Without this, searching e.g. `\d+` and replacing with text that
        // also contains a digit would re-match the just-inserted digit and keep
        // replacing the same spot forever (reported bug). Pick the first match at/after
        // the end of the replacement; wrap to 0 (cycle through any earlier remaining
        // matches) when nothing follows.
        let afterEnd = range.location + (replacement as NSString).length
        currentIndex = matches.firstIndex { $0.location >= afterEnd } ?? 0
        applyHighlights()
        scrollToCurrent()
        Task { @MainActor in Toaster.shared.flash("已替换 1 处") }
    }

    func replaceAll(with text: String, restyle: () -> Void) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        refreshSearchIfSnapshotIsStale(in: storage)
        guard searchSnapshotIsCurrent(in: storage), !matches.isEmpty else {
            Task { @MainActor in Toaster.shared.flash("没有可替换的匹配") }
            return
        }
        let full = NSRange(location: 0, length: storage.length)
        guard tv.shouldChangeText(in: full, replacementString: nil) else { return }
        let snapshotMatches = matches
        let replacements = snapshotMatches.indices.map {
            expandedReplacement(at: $0, template: text)
        }
        let count = snapshotMatches.count
        MVLog.info("find replaceAll count=\(count)", category: "find")
        // We're rewriting ranges out from under our highlights; drop the cache so
        // a later same-query search re-scans, and don't try to clear stale spans.
        invalidateForTextMutation()
        highlightedRanges = []
        // Reversed so each replacement does not shift the offsets of the ones still
        // to come. Every range was validated against the exact source snapshot above.
        // Iterate by index so each match can expand its own `$1` groups in regex mode.
        // Literal mode inserts the template verbatim.
        for i in snapshotMatches.indices.reversed() {
            storage.replaceCharacters(in: snapshotMatches[i], with: replacements[i])
        }
        tv.didChangeText()
        restyle()
        refreshLastSearch()
        Task { @MainActor in Toaster.shared.flash("已替换 " + String(count) + " 处") }
    }

    /// Rebuilds stale ranges before a replace operation can use them.
    /// Comparing the full raw source catches same-length edits whose old ranges still
    /// fit inside storage but now point at unrelated text.
    private func refreshSearchIfSnapshotIsStale(in storage: NSTextStorage) {
        guard !searchSnapshotIsCurrent(in: storage) else { return }
        MVLog.warn("find replacement requested with stale search snapshot", category: "find")
        refreshLastSearch()
    }

    private func refreshLastSearch() {
        guard let options = lastSearchedOptions else {
            clearSearchResults()
            return
        }
        search(options)
    }

    private func clearSearchResults() {
        clearHighlights()
        matches = []
        matchResults = []
        searchBody = ""
        searchRegex = nil
        searchStorageSnapshot = nil
        currentIndex = 0
    }

    private func searchSnapshotIsCurrent(in storage: NSTextStorage) -> Bool {
        guard let searchStorageSnapshot,
              searchStorageSnapshot == storage.string,
              searchBody == BodyMap(storage: storage).bodyString,
              matches.allSatisfy({ range in
                  range.location >= 0 && NSMaxRange(range) <= storage.length
              }) else {
            return false
        }
        return searchRegex == nil || matchResults.count == matches.count
    }

    /// Concrete replacement for the match at `index`, given the user's replace-field
    /// `template`. LITERAL mode returns the template verbatim (a `$` there is a
    /// literal `$`). REGEX mode expands `$0`/`$1`/… against that match's captured
    /// groups via ICU's own template engine (so `(\w+) (\w+)` → `$2 $1` swaps the
    /// words). The regex context is set only in regex mode, so the guard doubles as
    /// the mode check and falls back to verbatim if it is ever missing.
    private func expandedReplacement(at index: Int, template: String) -> String {
        guard let regex = searchRegex, matchResults.indices.contains(index) else { return template }
        return regex.replacementString(for: matchResults[index], in: searchBody, offset: 0, template: template)
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

    /// Debug-only (AppEnv.debug): the scroll math for the last navigation, so a
    /// "it didn't scroll" report can be diagnosed from actual before/after numbers.
    private(set) var lastScrollDiagnostic = ""

    private func scrollToCurrent() {
        guard matches.indices.contains(currentIndex), let tv = textView else { return }
        let length = tv.textStorage?.length ?? 0
        guard let safe = clamped(matches[currentIndex], max: length) else { return }
        // `NSTextView.scrollRangeToVisible` was a no-op for matches deep in this
        // custom ResponsiveScrollView, so scroll the clip view directly - the SAME
        // reliable mechanism the per-tab scroll-restore uses (EditorView makeNSView).
        // Center the match in the viewport so every navigation visibly moves, even
        // when the match was already partly on-screen.
        guard let lm = tv.layoutManager, let container = tv.textContainer,
              let sv = tv.enclosingScrollView else {
            tv.scrollRangeToVisible(safe)
            return
        }
        lm.ensureLayout(for: container)
        let glyphRange = lm.glyphRange(forCharacterRange: safe, actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyphRange, in: container)
        let clip = sv.contentView
        let viewportH = clip.bounds.height
        let beforeY = clip.bounds.origin.y
        // boundingRect is in text-container coords; the container sits at the text
        // view's inset, so the glyph's document-space mid-Y adds the top inset.
        let glyphMidDocY = rect.midY + tv.textContainerInset.height
        let docH = tv.frame.height + sv.contentInsets.top + sv.contentInsets.bottom
        let maxY = max(0, docH - viewportH)
        let targetY = min(max(0, glyphMidDocY - viewportH / 2), maxY)
        clip.scroll(to: CGPoint(x: clip.bounds.origin.x, y: targetY))
        sv.reflectScrolledClipView(clip)
        if AppEnv.debug {
            lastScrollDiagnostic = "SCROLL idx=\(currentIndex) midY=\(Int(glyphMidDocY)) target=\(Int(targetY)) before=\(Int(beforeY)) after=\(Int(clip.bounds.origin.y)) vH=\(Int(viewportH)) docH=\(Int(docH)) maxY=\(Int(maxY))"
        }
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
