import AppKit
import UniformTypeIdentifiers

/// Custom icons drawn from the spec's exact SVG paths (ui/Markdown Viewer.dc.html),
/// replacing SF Sy

extension NSAttributedString.Key {
    /// Marks a run inside a fenced code block's body/header → grouped into one
    /// rounded #FAFAFA card with a hairline border (mockup `data-code` div,
    /// Markdown Viewer.dc.html ~294). Boolean `true`.
    static let mvCodeBlock = NSAttributedString.Key("mvCodeBlock")
    /// Marks an inline `code` content run → rounded #F0F0F1 pill (mockup inline
    /// `code` span, Markdown Viewer.dc.html ~292). Boolean `true`.
    static let mvInlineCode = NSAttributedString.Key("mvInlineCode")
    /// Marks a table HEADER row → draws a #ECECEE hairline along its bottom edge
    /// (mockup `th` border-bottom, Markdown Viewer.dc.html ~318). Boolean `true`.
    static let mvTableHeaderRule = NSAttributedString.Key("mvTableHeaderRule")
    /// Marks a table BODY row → draws a #F4F4F5 hairline along its bottom edge
    /// (mockup `td` border-bottom, Markdown Viewer.dc.html ~324). Boolean `true`.
    static let mvTableBodyRule = NSAttributedString.Key("mvTableBodyRule")
    /// Marks a thematic-break line (`---`/`***`/`___`) → draws a 1px #F0F0F1
    /// divider across the text measure (final mockup has no `<hr>` example, so
    /// this uses the Design System divider token, DesignTokens.divider).
    /// Boolean `true`.
    static let mvHorizontalRule = NSAttributedString.Key("mvHorizontalRule")
    /// Marks a run that is NOT clean body/reading text - i.e. everything "所见即所搜"
    /// (find) must EXCLUDE: truly-hidden syntax (heading `#`, emphasis `*`/`_`,
    /// backticks, ``` fence markers, link/image `[]()` syntax, `---` rules, table
    /// pipes/separator) AND dimmed-but-non-body bits (list/quote markers, link URLs,
    /// image alt/path, code-fence language label). Body text (heading/paragraph/
    /// list-item/blockquote/table-cell text, bold/italic text, inline-code AND
    /// fenced-code CONTENT, link label) carries NO `.mvNonBody`. Stamped INTO the
    /// shared non-body attribute dictionaries so it stays in sync with both the
    /// full `apply()` and the scoped `applyIncremental()`; the `setAttributes`
    /// reset at the top of each pass wipes any stale value before re-stamping.
    /// `FindController` walks this attribute to build its body-only search map.
    /// Boolean `true`.
    static let mvNonBody = NSAttributedString.Key("mvNonBody")
}

final class CardLayoutManager: NSLayoutManager {
    // Mockup tokens (Markdown Viewer.dc.html ~294-327).
    private let cardFill = DesignTokens.codeBackground            // #FAFAFA
    private let cardBorder = NSColor.black.withAlphaComponent(0.04) // box-shadow 0 0 0 1px rgba(0,0,0,0.04)
    private let cardRadius: CGFloat = 6
    private let cardPadX: CGFloat = 16   // mockup `pre` padding-left/right 16 (L299)
    private let cardPadTop: CGFloat = 9    // mockup pre padding-top (header 9px, L308)
    private let cardPadBottom: CGFloat = 16  // mockup pre padding-bottom 16px (L299)
    private let pillFill = DesignTokens.divider                   // #F0F0F1
    private let pillRadius: CGFloat = 4
    private let pillPadX: CGFloat = 6   // mockup inline code padding 2px 6px (L286)
    private let headerRule = NSColor(hex: 0xECECEE)
    private let bodyRule = DesignTokens.line                      // #F4F4F5
    private let hrRule = DesignTokens.divider                     // #F0F0F1

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        // Let the base class paint any residual per-glyph backgrounds (e.g. the
        // `.clear` markers tables/quotes still carry so their assertions pass).
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }

        drawInlineCodePills(glyphsToShow, at: origin, storage: storage)
        drawCodeCards(glyphsToShow, at: origin, storage: storage)
        drawTableRules(glyphsToShow, at: origin, storage: storage)
        drawHorizontalRules(glyphsToShow, at: origin, storage: storage)
    }

    /// Draw a 1px divider centered in each thematic-break (`---`) line fragment,
    /// spanning the text measure. Reuses the table-rule drawing pattern.
    private func drawHorizontalRules(_ glyphsToShow: NSRange, at origin: NSPoint, storage: NSTextStorage) {
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        guard charRange.length > 0, let container = textContainers.first else { return }
        let left = origin.x + container.lineFragmentPadding
        let width = container.size.width - container.lineFragmentPadding * 2

        storage.enumerateAttribute(.mvHorizontalRule, in: charRange, options: []) { value, runCharRange, _ in
            guard (value as? Bool) == true, runCharRange.length > 0 else { return }
            let runGlyphRange = self.glyphRange(forCharacterRange: runCharRange, actualCharacterRange: nil)
            var union = CGRect.null
            self.enumerateLineFragments(forGlyphRange: runGlyphRange) { _, usedRect, _, _, _ in
                union = union.union(usedRect)
            }
            guard !union.isNull else { return }
            let y = (origin.y + union.midY).rounded() - 0.5
            self.hrRule.setStroke()
            let line = NSBezierPath()
            line.lineWidth = 1
            line.move(to: NSPoint(x: left, y: y))
            line.line(to: NSPoint(x: left + width, y: y))
            line.stroke()
        }
    }

    /// Paint one rounded card+border per contiguous `mvCodeBlock` run, spanning
    /// the paper column width and expanded by padding so the code sits INSIDE.
    private func drawCodeCards(_ glyphsToShow: NSRange, at origin: NSPoint, storage: NSTextStorage) {
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        guard charRange.length > 0 else { return }
        guard let container = textContainers.first else { return }
        // Card spans the full paper column edge-to-edge (the code text is inset
        // from these edges by `cardPadX` via the styler's paragraph indents).
        let cardLeft = origin.x + container.lineFragmentPadding
        let columnWidth = container.size.width - container.lineFragmentPadding * 2

        // Draw each WHOLE block whose extent intersects the visible glyphs. We
        // expand every hit to its full contiguous `mvCodeBlock` extent (via
        // longestEffectiveRange) so a partial redraw still paints the complete
        // card — never a clipped-top fragment.
        let fullLen = storage.length
        var drawn = Set<Int>()
        storage.enumerateAttribute(.mvCodeBlock, in: charRange, options: []) { value, runCharRange, _ in
            guard (value as? Bool) == true, runCharRange.length > 0 else { return }
            var blockRange = NSRange(location: 0, length: 0)
            _ = storage.attribute(.mvCodeBlock, at: runCharRange.location,
                                  longestEffectiveRange: &blockRange,
                                  in: NSRange(location: 0, length: fullLen))
            guard blockRange.length > 0, !drawn.contains(blockRange.location) else { return }
            drawn.insert(blockRange.location)

            let runGlyphRange = self.glyphRange(forCharacterRange: blockRange, actualCharacterRange: nil)
            var union = CGRect.null
            self.enumerateLineFragments(forGlyphRange: runGlyphRange) { _, usedRect, _, _, _ in
                union = union.union(usedRect)
            }
            guard !union.isNull else { return }
            // Expand vertically by the padding; horizontally to the column edges.
            let card = CGRect(
                x: cardLeft,
                y: origin.y + union.minY - self.cardPadTop,
                width: columnWidth,
                height: union.height + self.cardPadTop + self.cardPadBottom
            )
            // Inset by half a point so the 1px hairline border stays crisp.
            let path = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: self.cardRadius, yRadius: self.cardRadius)
            self.cardFill.setFill()
            path.fill()
            self.cardBorder.setStroke()
            path.lineWidth = 1
            path.stroke()
            // The opaque card fill just covered any find/outline highlight inside
            // it (a semi-transparent temporary `.backgroundColor` painted by
            // `super.drawBackground`). Re-stamp those highlights on top so matches
            // inside a code block stay visible (paint-order fix).
            self.refillTemporaryBackgrounds(in: blockRange, at: origin)
        }
    }

    /// Re-paint any temporary `.backgroundColor` (the find/outline highlight,
    /// applied by `FindController`/`OutlineController` via `addTemporaryAttributes`)
    /// over the opaque inline-code pill or code card that `drawInlineCodePills` /
    /// `drawCodeCards` just filled on top of it. The base class already painted
    /// these once in `super.drawBackground`, so we mirror that geometry: walk the
    /// temp-bg sub-ranges of `charRange` and fill each one's glyph bounding rect
    /// (offset by the same `origin`) with its temp color. Because the find accent
    /// is semi-transparent (alpha 0.55/0.22) it reads correctly over the pill, and
    /// touching only temporary `.backgroundColor` leaves selection and the
    /// permanent quote/table `.backgroundColor` attributes untouched.
    private func refillTemporaryBackgrounds(in charRange: NSRange, at origin: NSPoint) {
        guard charRange.length > 0, let container = textContainers.first else { return }
        let full = NSRange(location: 0, length: (textStorage?.length ?? 0))
        var index = charRange.location
        let end = charRange.location + charRange.length
        while index < end {
            var effective = NSRange(location: 0, length: 0)
            let value = temporaryAttribute(.backgroundColor, atCharacterIndex: index,
                                           longestEffectiveRange: &effective, in: full)
            guard effective.length > 0 else { break }
            // Clip the run to the range we are re-filling.
            let runStart = max(effective.location, charRange.location)
            let runEnd = min(effective.location + effective.length, end)
            if let color = value as? NSColor, runEnd > runStart {
                let subRange = NSRange(location: runStart, length: runEnd - runStart)
                let glyphRange = self.glyphRange(forCharacterRange: subRange, actualCharacterRange: nil)
                color.setFill()
                self.enumerateEnclosingRects(forGlyphRange: glyphRange,
                                             withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                             in: container) { rect, _ in
                    rect.offsetBy(dx: origin.x, dy: origin.y).fill()
                }
            }
            index = max(index + 1, effective.location + effective.length)
        }
    }

    /// Paint a subtle rounded pill behind each contiguous inline-`code` run.
    private func drawInlineCodePills(_ glyphsToShow: NSRange, at origin: NSPoint, storage: NSTextStorage) {
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        guard charRange.length > 0 else { return }
        storage.enumerateAttribute(.mvInlineCode, in: charRange, options: []) { value, runCharRange, _ in
            guard (value as? Bool) == true, runCharRange.length > 0 else { return }
            let runGlyphRange = glyphRange(forCharacterRange: runCharRange, actualCharacterRange: nil)
            // Inline runs can wrap; draw a pill per line fragment slice.
            self.enumerateEnclosingRects(forGlyphRange: runGlyphRange,
                                         withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                         in: container(forGlyphAt: runGlyphRange.location)) { rect, _ in
                var pill = rect.offsetBy(dx: origin.x, dy: origin.y)
                pill = pill.insetBy(dx: -self.pillPadX, dy: 1.5)
                let path = NSBezierPath(roundedRect: pill, xRadius: self.pillRadius, yRadius: self.pillRadius)
                self.pillFill.setFill()
                path.fill()
            }
            // The opaque pill fill just covered any find/outline highlight inside
            // this inline-code run; re-stamp it on top (paint-order fix). See
            // `refillTemporaryBackgrounds`.
            self.refillTemporaryBackgrounds(in: runCharRange, at: origin)
        }
    }

    /// Draw hairline separators along the bottom edge of each table row instead
    /// of a filled block (header rule darker than body rule).
    private func drawTableRules(_ glyphsToShow: NSRange, at origin: NSPoint, storage: NSTextStorage) {
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        guard charRange.length > 0, let container = textContainers.first else { return }
        let left = origin.x + container.lineFragmentPadding
        let width = container.size.width - container.lineFragmentPadding * 2

        func rule(_ key: NSAttributedString.Key, color: NSColor) {
            storage.enumerateAttribute(key, in: charRange, options: []) { value, runCharRange, _ in
                guard (value as? Bool) == true, runCharRange.length > 0 else { return }
                let runGlyphRange = glyphRange(forCharacterRange: runCharRange, actualCharacterRange: nil)
                var maxY: CGFloat = -.greatestFiniteMagnitude
                enumerateLineFragments(forGlyphRange: runGlyphRange) { _, usedRect, _, _, _ in
                    maxY = max(maxY, usedRect.maxY)
                }
                guard maxY > -.greatestFiniteMagnitude else { return }
                let y = (origin.y + maxY).rounded() - 0.5
                color.setStroke()
                let line = NSBezierPath()
                line.lineWidth = 1
                line.move(to: NSPoint(x: left, y: y))
                line.line(to: NSPoint(x: left + width, y: y))
                line.stroke()
            }
        }
        rule(.mvTableHeaderRule, color: headerRule)
        rule(.mvTableBodyRule, color: bodyRule)
    }

    private func container(forGlyphAt glyphIndex: Int) -> NSTextContainer {
        textContainers.first ?? NSTextContainer()
    }
}

enum LiveMarkdownStyler {
    static var bodyPointSize: CGFloat = 15.5
    static var bodyFont: NSFont { NSFont.systemFont(ofSize: bodyPointSize) }

    private static let markerFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    private static let codeFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    // Inline `code` runs are 13px (mockup); the fenced code BLOCK stays 12.5.
    private static let inlineCodeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let boldCodeFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
    // Mockup table header `th` (L317): 11px semibold sans, #86868b, letter-spacing 0.4.
    private static let tableHeaderFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    // Mockup table body `td` (L323): 13.5px (table font-size, L314), body sans.
    private static let tableBodyFont = NSFont.systemFont(ofSize: 13.5)
    private static let markerColor = DesignTokens.placeholderText
    private static let mutedColor = DesignTokens.secondaryText
    private static let codeBackground = DesignTokens.codeBackground
    private static let quoteBackground = NSColor.clear

    private static let headingRegex = try! NSRegularExpression(pattern: "^(#{1,6})\\s+(.+)$", options: [.anchorsMatchLines])
    private static let cjkRegex = try! NSRegularExpression(pattern: "[\u{2E80}-\u{9FFF}\u{3040}-\u{30FF}\u{AC00}-\u{D7AF}\u{FF00}-\u{FFEF}\u{3000}-\u{303F}]")
    private static let listRegex = try! NSRegularExpression(pattern: "^(\\s*(?:[-*+] |\\d+\\. ))(.+)$", options: [.anchorsMatchLines])
    private static let taskRegex = try! NSRegularExpression(pattern: "^(\\s*[-*+] \\[[ xX]\\] )(.+)$", options: [.anchorsMatchLines])
    private static let strongStarRegex = try! NSRegularExpression(pattern: "\\*\\*([^\\n*]+)\\*\\*")
    private static let strongUnderscoreRegex = try! NSRegularExpression(pattern: "__([^\\n_]+)__")
    private static let italicStarRegex = try! NSRegularExpression(pattern: "(?<!\\*)\\*([^\\n*]+)\\*(?!\\*)")
    private static let strikeRegex = try! NSRegularExpression(pattern: "~~([^\\n~]+)~~")
    private static let inlineCodeRegex = try! NSRegularExpression(pattern: "`([^`\\n]+)`")
    private static let imageRegex = try! NSRegularExpression(pattern: "!\\[([^\\]\\n]*)\\]\\(([^)\\n]+)\\)")
    private static let linkRegex = try! NSRegularExpression(pattern: "\\[([^\\]\\n]+)\\]\\(([^)\\n]+)\\)")

    /// Source-parse the markdown for the link `[label](url)` whose full span (or
    /// label span) covers `index`, returning its destination URL. The styler
    /// never stores an `NSAttributedString.Key.link`, so the hover preview relies
    /// on this single shared `linkRegex` rather than reading attributes. Image
    /// links (`![...]`) are skipped, mirroring the linkRegex pass in
    /// applyInlineStyles which `continue`s when the char before `[` is `!`.
    static func linkDestination(in nsString: NSString, coveringIndex index: Int) -> String? {
        let fullRange = NSRange(location: 0, length: nsString.length)
        for match in linkRegex.matches(in: nsString as String, range: fullRange) {
            if match.range.location > 0,
               nsString.character(at: match.range.location - 1) == 33 { // '!' → image
                continue
            }
            if NSLocationInRange(index, match.range) {
                let urlRange = match.range(at: 2)
                guard urlRange.location != NSNotFound else { return nil }
                return nsString.substring(with: urlRange)
            }
        }
        return nil
    }

    /// All `[label](url)` link spans in `nsString` paired with their destination,
    /// computed with the SAME `linkRegex` + image-skip logic as `linkDestination`.
    /// Built once per text version so the hover path can do a cheap range lookup
    /// instead of re-scanning the whole document on every mouse move. `range` is
    /// the full match span (`[label](url)`), matching `linkDestination`'s hit test.
    static func linkRanges(in nsString: NSString) -> [(range: NSRange, url: String)] {
        let fullRange = NSRange(location: 0, length: nsString.length)
        var result: [(range: NSRange, url: String)] = []
        for match in linkRegex.matches(in: nsString as String, range: fullRange) {
            if match.range.location > 0,
               nsString.character(at: match.range.location - 1) == 33 { // '!' → image
                continue
            }
            let urlRange = match.range(at: 2)
            guard urlRange.location != NSNotFound else { continue }
            result.append((range: match.range, url: nsString.substring(with: urlRange)))
        }
        return result
    }

    /// One fenced code block recovered from the source. `containerRange` spans the
    /// opening fence line through the closing fence line (used to compute the
    /// block's on-screen rect for the top-right copy button). `bodyRange` covers
    /// ONLY the code lines between the fences — it EXCLUDES both ``` fence lines
    /// and the opening fence's language token, so copying yields the raw code body.
    struct FencedCodeBlock {
        let containerRange: NSRange
        let bodyRange: NSRange
    }

    /// Enumerate the fenced code blocks in `nsString`, reusing the SAME
    /// ``` -toggle line scan that `applyLineStyles` uses to style them (so the copy
    /// button targets exactly the blocks the styler colors — inline `code` is never
    /// matched). A block is only emitted once its closing fence is seen; an
    /// unterminated trailing fence is ignored.
    static func fencedCodeBlocks(in nsString: NSString) -> [FencedCodeBlock] {
        let fullRange = NSRange(location: 0, length: nsString.length)
        let lines = markdownLines(in: nsString, fullRange: fullRange)
        var blocks: [FencedCodeBlock] = []
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].text.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("```") else { index += 1; continue }
            let openRange = lines[index].range
            var j = index + 1
            while j < lines.count {
                let inner = lines[j].text.trimmingCharacters(in: .whitespaces)
                if inner.hasPrefix("```") { break }
                j += 1
            }
            guard j < lines.count else {
                // Unterminated fence: stop (no closing ``` → not a real block).
                break
            }
            let closeRange = lines[j].range
            // Body spans from the first body line's start to the END of the last
            // body line (line ranges exclude the terminator, so we extend to the
            // closing fence line's start to capture the trailing newlines, then the
            // copy path trims a single trailing newline). For an empty block
            // (```lang immediately followed by ```), this collapses to length 0.
            let bodyStart: Int
            let bodyLength: Int
            if j == index + 1 {
                bodyStart = closeRange.location
                bodyLength = 0
            } else {
                bodyStart = lines[index + 1].range.location
                bodyLength = max(0, closeRange.location - bodyStart)
            }
            let containerLength = (closeRange.location + closeRange.length) - openRange.location
            blocks.append(FencedCodeBlock(
                containerRange: NSRange(location: openRange.location, length: containerLength),
                bodyRange: NSRange(location: bodyStart, length: bodyLength)
            ))
            index = j + 1
        }
        return blocks
    }

    static func apply(to textStorage: NSTextStorage) {
        let fullRange = NSRange(location: 0, length: textStorage.length)
        guard fullRange.length > 0 else { return }

        textStorage.beginEditing()
        textStorage.setAttributes(baseAttributes(), range: fullRange)
        applyLineStyles(to: textStorage, scope: fullRange)
        applyInlineStyles(to: textStorage, scope: fullRange)
        textStorage.endEditing()
    }

    /// Re-style ONLY the block(s) affected by an edit, avoiding a whole-document
    /// re-style (and its full re-layout = white flash) on every keystroke.
    ///
    /// `editedCharRange` is the POST-edit character range that actually changed
    /// (insertion/deletion), as reported by `NSTextStorageDelegate`. We expand it
    /// to a safe enclosing block scope, reset that scope's attributes to base, and
    /// re-run the SAME line + inline passes over just that scope.
    ///
    /// CORRECTNESS-FIRST: when the edit could change block boundaries *downstream*
    /// (open/close a fence, add/remove a blank line, change a table/list shape) we
    /// fall back to a FULL `apply`, because a scoped pass cannot see those ripple
    /// effects. A rare extra full restyle is acceptable; stale styling is not.
    ///
    /// Returns `true` if it performed an incremental restyle, `false` if it fell
    /// back to (and performed) a full restyle.
    @discardableResult
    static func applyIncremental(to textStorage: NSTextStorage, editedCharRange: NSRange) -> Bool {
        let length = textStorage.length
        guard length > 0 else { return false }

        let nsString = textStorage.string as NSString
        // Clamp the reported edited range to the current (post-edit) string bounds.
        let safeEdited = NSRange(
            location: min(max(0, editedCharRange.location), length),
            length: min(editedCharRange.length, length - min(max(0, editedCharRange.location), length))
        )

        // STRUCTURAL FALLBACK: if the edited text touches a construct whose change
        // can re-pair / re-shape blocks below it, restyle the whole document.
        if requiresFullRestyle(editedRange: safeEdited, nsString: nsString) {
            apply(to: textStorage)
            return false
        }

        // Compute a safe block-bounded scope around the edit. If we cannot, full.
        guard let scope = blockScope(for: safeEdited, in: nsString) else {
            apply(to: textStorage)
            return false
        }

        textStorage.beginEditing()
        textStorage.setAttributes(baseAttributes(), range: scope)
        applyLineStyles(to: textStorage, scope: scope)
        applyInlineStyles(to: textStorage, scope: scope)
        textStorage.endEditing()
        return true
    }

    /// The EXACT conditions that force a full restyle instead of an incremental one.
    ///
    /// We inspect a TIGHT neighbourhood: the edited (inserted) characters themselves
    /// plus a few characters of slack on each side. This is deliberately NOT the
    /// whole paragraph — `paragraphRange` includes a paragraph's trailing newline,
    /// and the following blank-line separator's newline sits right after it, so a
    /// paragraph-wide region would see the pre-existing `\n\n` block separator and
    /// (wrongly) full-restyle on EVERY keystroke. By examining only the edit's own
    /// neighbourhood we catch structural chars the edit INTRODUCED or BORDERS, while
    /// a plain within-line edit (no structural char nearby) stays incremental.
    ///
    /// The slack (`pad`) lets a deletion that joined onto an adjacent structural
    /// char — e.g. backspacing into a `\n`, a `|`, or a fence — still be seen, since
    /// we cannot inspect the removed text directly. Block merges from removing a
    /// lone blank line are handled safely by the scoped pass (it covers both newly
    /// adjacent blocks), so they need not force a full restyle here.
    private static func requiresFullRestyle(editedRange: NSRange, nsString: NSString) -> Bool {
        let length = nsString.length
        let pad = 2
        let start = max(0, editedRange.location - pad)
        let end = min(length, editedRange.location + editedRange.length + pad)
        guard end > start else { return false }
        let region = nsString.substring(with: NSRange(location: start, length: end - start))

        // 1) A code-fence delimiter in/adjacent to the edit. Opening or closing a
        //    ``` re-pairs every fence below it (body ↔ prose flips downstream), so
        //    the scoped pass can't be trusted — full restyle.
        if region.contains("```") { return true }

        // 2) A newline the EDIT ITSELF introduced (Enter → could split a block or
        //    create a `\n\n` blank line). A plain-character insertion CANNOT change
        //    block structure, so we no longer full-restyle merely because a
        //    pre-existing blank line sits NEAR the edit — that proximity check made
        //    every paragraph-boundary keystroke full-restyle (measured inc:1 full:110,
        //    the fast-typing lag). Deletions (length 0, removed text unknowable) rely
        //    on `blockScope` expanding to the neighbouring block on each side, which
        //    re-styles a block MERGE (deleting a lone blank line) correctly.
        if editedRange.length > 0, nsString.substring(with: editedRange).contains("\n") { return true }

        // 3) A table pipe `|`. Adding/removing a pipe can turn a paragraph into a
        //    table (or vice-versa) and changes the multi-row column grouping, which
        //    spans lines the scope may not cover — full restyle.
        if region.contains("|") { return true }

        // 4) The edited region contains a run of 3+ `-`, `*`, or `_` — a possible
        //    thematic break (`---`) or table separator (`---|---`), whose effect is
        //    multi-line. Conservative superset; full restyle.
        if regionHasMarkerRun(region) { return true }

        return false
    }

    /// True if `region` contains a run of 3 or more `-`, `*`, or `_` (a thematic
    /// break, a table separator, or strong/em delimiters that could be multi-line).
    private static func regionHasMarkerRun(_ region: String) -> Bool {
        let markers: Set<Character> = ["-", "*", "_"]
        var run = 0
        var last: Character? = nil
        for ch in region {
            if markers.contains(ch), ch == last || last == nil || markers.contains(last!) {
                run = (ch == last) ? run + 1 : 1
                if run >= 3 { return true }
            } else {
                run = 0
            }
            last = ch
        }
        return false
    }

    /// Expand `editedRange` to a SAFE block-bounded scope for an incremental pass.
    ///
    /// The scope must (a) start and end OUTSIDE any fenced code block (guaranteed:
    /// `requiresFullRestyle` already bailed on any ``` near the edit, but the edit
    /// may sit INSIDE a pre-existing fence — we detect that and expand to the whole
    /// fence container); and (b) include enough neighbouring context that the
    /// line-styler's cross-line state (insideCodeBlock, prevWasBlank, prevBlock,
    /// multi-row table grouping, list intra-gap look-ahead, blank-gap look-ahead)
    /// is recomputed correctly. We achieve this by snapping the scope to blank-line
    /// boundaries and including one extra block of context on each side.
    private static func blockScope(for editedRange: NSRange, in nsString: NSString) -> NSRange? {
        let length = nsString.length
        guard length > 0 else { return nil }

        // If the edit sits inside an EXISTING fenced code block (one that survives
        // the edit, since `requiresFullRestyle` ruled out fence-delimiter changes),
        // restyle that whole block's container so the card stays a single piece.
        if let fenceScope = enclosingFenceContainer(for: editedRange, in: nsString) {
            // The fence container is itself bounded by blank lines in well-formed
            // markdown; pad it to blank-line boundaries to be safe and recompute the
            // surrounding gaps.
            return paddedBlankBoundedScope(around: fenceScope, in: nsString)
        }

        let para = nsString.paragraphRange(for: editedRange)
        return paddedBlankBoundedScope(around: para, in: nsString)
    }

    /// Snap `range` outward to blank-line boundaries, then extend one further block
    /// of context on each side (so the gap-carrying blank lines are recomputed with
    /// their true neighbours). Never crosses a fenced code block — if expansion
    /// would touch a ``` line, returns nil so the caller falls back to a full
    /// restyle (defensive: should not happen given `requiresFullRestyle`).
    private static func paddedBlankBoundedScope(around range: NSRange, in nsString: NSString) -> NSRange? {
        let fullRange = NSRange(location: 0, length: nsString.length)
        let lines = markdownLines(in: nsString, fullRange: fullRange)
        guard !lines.isEmpty else { return nil }

        // Locate the line indices covering `range`.
        let rangeEnd = range.location + range.length
        var startLine = 0
        var endLine = lines.count - 1
        for (i, line) in lines.enumerated() {
            let lineEnd = line.range.location + line.range.length
            if line.range.location <= range.location && range.location <= lineEnd {
                startLine = i
            }
            if line.range.location <= rangeEnd && rangeEnd <= lineEnd {
                endLine = i
            }
        }
        if endLine < startLine { endLine = startLine }

        func isBlank(_ i: Int) -> Bool {
            lines[i].text.trimmingCharacters(in: .whitespaces).isEmpty
        }
        func isFence(_ i: Int) -> Bool {
            lines[i].text.trimmingCharacters(in: .whitespaces).hasPrefix("```")
        }

        // Walk UP: (1) into the current block until its top (a blank line or
        // doc-start); (2) across the blank-line run above it; (3) into ONE preceding
        // block, stopping at the blank/doc-start above THAT. This guarantees the
        // scope starts at a blank-line (or doc) boundary — so `insideCodeBlock`
        // begins false — and includes the preceding block so a leading blank's
        // collapsed gap (max(prevBlock.marginBottom, nextBlock.marginTop)) is
        // recomputed against its true previous block. If expansion would touch a
        // fence line, bail to a full restyle (we can't recover the fence's
        // insideCodeBlock state without including the whole — possibly large —
        // block; correctness over a slightly larger incremental scope).
        var s = startLine
        // (1) climb to the top of the current block.
        while s > 0, !isBlank(s - 1) {
            if isFence(s - 1) { return nil }
            s -= 1
        }
        // (2) cross the blank run above.
        while s > 0, isBlank(s - 1) {
            if isFence(s - 1) { return nil }
            s -= 1
        }
        // (3) include one preceding block.
        while s > 0, !isBlank(s - 1) {
            if isFence(s - 1) { return nil }
            s -= 1
        }

        // Walk DOWN symmetrically: to the bottom of the current block, across the
        // blank run below, then into one following block.
        var e = endLine
        while e < lines.count - 1, !isBlank(e + 1) {
            if isFence(e + 1) { return nil }
            e += 1
        }
        while e < lines.count - 1, isBlank(e + 1) {
            if isFence(e + 1) { return nil }
            e += 1
        }
        while e < lines.count - 1, !isBlank(e + 1) {
            if isFence(e + 1) { return nil }
            e += 1
        }

        let scopeStart = lines[s].range.location
        // Extend the scope end to the END of line `e` INCLUDING its trailing
        // terminator (line ranges from enumerateSubstrings exclude terminators), so
        // the markCodeBlockNewline / blank-line styling that touches a terminator is
        // covered and the reset clears it.
        var scopeEnd = lines[e].range.location + lines[e].range.length
        if scopeEnd < nsString.length {
            let c = nsString.character(at: scopeEnd)
            if c == 0x0A || c == 0x0D { scopeEnd += 1 }
        }
        scopeEnd = min(scopeEnd, nsString.length)
        guard scopeEnd > scopeStart else { return nil }
        return NSRange(location: scopeStart, length: scopeEnd - scopeStart)
    }

    /// If `editedRange` falls inside a fenced code block (between an opening ``` and
    /// its matching closing ```), return that block's container range; else nil.
    /// Reuses `fencedCodeBlocks` so the detection matches exactly how blocks are
    /// styled. Only well-formed (closed) blocks are returned — an unterminated fence
    /// is not a block here (and a ``` near the edit already triggers full restyle).
    private static func enclosingFenceContainer(for editedRange: NSRange, in nsString: NSString) -> NSRange? {
        let editStart = editedRange.location
        let editEnd = editedRange.location + editedRange.length
        for block in fencedCodeBlocks(in: nsString) {
            let bStart = block.containerRange.location
            let bEnd = block.containerRange.location + block.containerRange.length
            // Strictly inside the container (not on a fence line — those changes are
            // structural and already handled by requiresFullRestyle).
            if editStart >= bStart && editEnd <= bEnd {
                return block.containerRange
            }
        }
        return nil
    }

    static func typingAttributes() -> [NSAttributedString.Key: Any] {
        baseAttributes()
    }

    /// Classification of a non-blank source line into a rendered block, with the
    /// margin-top / margin-bottom it contributes to the vertical rhythm. Mirrors
    /// the mockup's per-block CSS margins (Markdown Viewer.dc.html): paragraphs
    /// and "container" blocks (list/code/blockquote/table/hr) carry only a 22px
    /// bottom margin; headings carry a larger TOP margin (H1 56, H2/H3 40) plus a
    /// bottom margin (H1 24, H2/H3 16). The blank line between two blocks then
    /// carries `max(prev.bottom, next.top)` — true CSS margin-collapse — so the
    /// gaps stay tight and even instead of double-counting.
    private enum BlockKind {
        case heading1, heading23, headingOther
        case paragraph, list, blockquote, code, table, hr

        var marginTop: CGFloat {
            switch self {
            case .heading1: return 56
            case .heading23, .headingOther: return 40
            default: return 0
            }
        }
        var marginBottom: CGFloat {
            switch self {
            case .heading1: return 24
            case .heading23, .headingOther: return 16
            default: return 22
            }
        }
    }

    /// Classify the non-blank line at `index` (assumed at top level, i.e. not
    /// inside a fenced code block — blanks only occur outside fences, so the next
    /// non-blank line after a blank run is always classifiable in isolation).
    private static func classifyBlock(lines: [(text: String, range: NSRange)], index: Int, nsString: NSString) -> BlockKind {
        let line = lines[index].text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") { return .code }
        if trimmed == "---" || trimmed == "***" || trimmed == "___" { return .hr }
        if let heading = firstMatch(headingRegex, in: nsString, exactly: lines[index].range) {
            switch heading.range(at: 1).length {
            case 1: return .heading1
            case 2, 3: return .heading23
            default: return .headingOther
            }
        }
        if trimmed.hasPrefix(">") { return .blockquote }
        if index + 1 < lines.count,
           looksLikeTableLine(line),
           isTableSeparatorLine(lines[index + 1].text) {
            return .table
        }
        if firstMatch(taskRegex, in: nsString, exactly: lines[index].range) != nil { return .list }
        if firstMatch(listRegex, in: nsString, exactly: lines[index].range) != nil { return .list }
        return .paragraph
    }

    private static func applyLineStyles(to textStorage: NSTextStorage, scope: NSRange) {
        let nsString = textStorage.string as NSString
        let lines = markdownLines(in: nsString, fullRange: scope)
        var insideCodeBlock = false
        var index = 0
        // Tracks whether the immediately preceding line was a (non-code) blank, so
        // consecutive blanks in a run collapse instead of each rendering at full
        // body line-height (the "too much vertical spacing" bug).
        var prevWasBlank = false
        // The kind of the most recent non-blank block, so a blank can size its gap
        // as max(prevBlock.marginBottom, nextBlock.marginTop) — CSS margin-collapse.
        var prevBlock: BlockKind? = nil

        while index < lines.count {
            let current = lines[index]
            let substringRange = current.range
            let line = current.text
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Blank line (empty or whitespace-only) outside a fenced code block:
            // the blank CARRIES the inter-block gap (block margins are zeroed, so
            // there is no double-counting). Only the FIRST blank in a run carries
            // the gap; subsequent blanks collapse to ~1px. The gap is the collapsed
            // margin between the preceding block and the next non-blank block.
            if trimmed.isEmpty && !insideCodeBlock {
                if substringRange.length > 0 {
                    let blankStyle = NSMutableParagraphStyle()
                    var h: CGFloat = 1
                    if !prevWasBlank {
                        // Look ahead past consecutive blanks to the next block.
                        var j = index + 1
                        while j < lines.count,
                              lines[j].text.trimmingCharacters(in: .whitespaces).isEmpty {
                            j += 1
                        }
                        let nextTop: CGFloat = j < lines.count
                            ? classifyBlock(lines: lines, index: j, nsString: nsString).marginTop
                            : 0
                        let prevBottom = prevBlock?.marginBottom ?? 0
                        h = max(prevBottom, nextTop)
                        if h <= 0 { h = 1 }
                    }
                    blankStyle.minimumLineHeight = h
                    blankStyle.maximumLineHeight = h
                    blankStyle.lineHeightMultiple = 1
                    textStorage.addAttributes([
                        .font: NSFont.systemFont(ofSize: 1),
                        .paragraphStyle: blankStyle
                    ], range: substringRange)
                }
                prevWasBlank = true
                index += 1
                continue
            }
            prevWasBlank = false

            guard substringRange.length > 0 else {
                // A truly-empty line (length 0) INSIDE a fenced code block must still
                // join the card: its own range has no characters to mark, so we mark
                // the trailing newline that follows it. Combined with the newline
                // marking done for every code body/fence line below, this keeps the
                // `.mvCodeBlock` character run CONTIGUOUS across the blank — otherwise
                // `CardLayoutManager.drawCodeCards` would split the card into pieces
                // with a hairline gap at the empty line (the directory-tree "grid").
                if insideCodeBlock {
                    markCodeBlockNewline(after: substringRange, in: nsString, textStorage: textStorage)
                }
                index += 1
                continue
            }

            // Remember this block's kind for the NEXT blank's gap computation. Skip
            // lines inside a fence (code body / closing fence) so the whole code
            // block keeps the `.code` kind set by its opening fence.
            if !insideCodeBlock {
                prevBlock = classifyBlock(lines: lines, index: index, nsString: nsString)
            }

            if trimmed.hasPrefix("```") {
                let isOpeningFence = !insideCodeBlock
                textStorage.addAttributes(codeBlockAttributes(role: isOpeningFence ? .open : .close), range: substringRange)
                if isOpeningFence, let langRange = fenceLanguageRange(line: line, lineRange: substringRange) {
                    // Hide the ``` markers but surface the language token as a small
                    // uppercase-style gray label (mockup code-block header, #b3b3b8).
                    let markersLength = langRange.location - substringRange.location
                    if markersLength > 0 {
                        textStorage.addAttributes(hiddenMarkupAttributes(),
                            range: NSRange(location: substringRange.location, length: markersLength))
                    }
                    let langEnd = langRange.location + langRange.length
                    let tailLength = (substringRange.location + substringRange.length) - langEnd
                    if tailLength > 0 {
                        textStorage.addAttributes(hiddenMarkupAttributes(),
                            range: NSRange(location: langEnd, length: tailLength))
                    }
                    textStorage.addAttributes(codeLanguageLabelAttributes(), range: langRange)
                } else {
                    // Bare ``` (no language) or the closing fence: hide entirely.
                    textStorage.addAttributes(hiddenMarkupAttributes(), range: substringRange)
                }
                // Mark the newline AFTER the opening fence so its `.mvCodeBlock` run
                // touches the first body line — keeps the card a single piece even if
                // the body starts with an empty line. (The closing fence needs no
                // trailing extension; the card ends there.)
                if isOpeningFence {
                    markCodeBlockNewline(after: substringRange, in: nsString, textStorage: textStorage)
                }
                insideCodeBlock.toggle()
                index += 1
                continue
            }

            if insideCodeBlock {
                textStorage.addAttributes(codeBlockAttributes(), range: substringRange)
                // Extend the marker over the trailing newline so this body line's
                // `.mvCodeBlock` run touches the next line's run — empty lines in the
                // block can't break card contiguity.
                markCodeBlockNewline(after: substringRange, in: nsString, textStorage: textStorage)
                index += 1
                continue
            }

            if index + 1 < lines.count,
               looksLikeTableLine(line),
               isTableSeparatorLine(lines[index + 1].text) {
                var tableRows: [(text: String, range: NSRange, isHeader: Bool)] = [
                    (line, substringRange, true)
                ]
                let separatorRange = lines[index + 1].range
                index += 2

                while index < lines.count && looksLikeTableLine(lines[index].text) {
                    tableRows.append((lines[index].text, lines[index].range, false))
                    index += 1
                }

                applyTableBlock(rows: tableRows, separatorRange: separatorRange, to: textStorage)
                continue
            }

            if let heading = firstMatch(headingRegex, in: nsString, exactly: substringRange) {
                let level = heading.range(at: 1).length
                let font = headingFont(level: level)
                textStorage.addAttributes([
                    .font: font,
                    // Headings are #111 (mockup L285/287), darker than body #333336.
                    .foregroundColor: DesignTokens.headingText,
                    .paragraphStyle: headingParagraphStyle(level: level)
                ], range: substringRange)
                let textRange = heading.range(at: 2)
                if textRange.location != NSNotFound, textRange.length > 0 {
                    let headingText = nsString.substring(with: textRange)
                    if level == 1 {
                        textStorage.addAttributes([.kern: -0.2], range: textRange)
                    } else if level == 2, !containsCJK(headingText) {
                        textStorage.addAttributes([.kern: 0.3], range: textRange)
                    }
                }
                textStorage.addAttributes(hiddenMarkupAttributes(), range: heading.range(at: 1))
                index += 1
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                // Keep the raw `---` text hidden (clear) as before, but give the
                // line enough height for a centered divider and stamp
                // `mvHorizontalRule` so CardLayoutManager paints a visible 1px
                // #F0F0F1 hairline across the text measure.
                // Margins zeroed: the surrounding blank lines carry the 22px gaps.
                let style = paragraphStyle()
                style.minimumLineHeight = 14
                style.maximumLineHeight = 14
                textStorage.addAttributes([
                    .foregroundColor: NSColor.clear,
                    .font: NSFont.systemFont(ofSize: 1),
                    .mvHorizontalRule: true,
                    // The raw `---`/`***`/`___` is not reading text - exclude from find.
                    .mvNonBody: true,
                    .paragraphStyle: style
                ], range: substringRange)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                // Mockup blockquote (L310): font-size 14.5, color #767676,
                // padding-left 0 (no head indent), line-height 1.7.
                let style = paragraphStyle(spacingAfter: 0)
                textStorage.addAttributes([
                    .font: NSFont.systemFont(ofSize: 14.5),
                    .foregroundColor: NSColor(hex: 0x767676),
                    .backgroundColor: quoteBackground,
                    .paragraphStyle: style
                ], range: substringRange)
                if let markerRange = line.range(of: ">") {
                    let nsMarkerRange = NSRange(markerRange, in: line)
                    textStorage.addAttributes(hiddenMarkupAttributes(), range: NSRange(location: substringRange.location + nsMarkerRange.location, length: nsMarkerRange.length))
                }
                index += 1
                continue
            }

            if let task = firstMatch(taskRegex, in: nsString, exactly: substringRange) {
                let markerRange = task.range(at: 1)
                // Match the list indent (mockup `padding-left: 20px`, hanging indent).
                // 6px gap only BETWEEN items; the last item drops it (blank carries 22).
                let intraGap: CGFloat = isListItemLine(lines: lines, index: index + 1, nsString: nsString) ? 6 : 0
                let style = paragraphStyle(spacingAfter: intraGap)
                style.firstLineHeadIndent = 20
                style.headIndent = 36
                textStorage.addAttributes([.paragraphStyle: style], range: substringRange)
                textStorage.addAttributes(markerAttributes(font: boldCodeFont), range: markerRange)
                index += 1
                continue
            }

            if let list = firstMatch(listRegex, in: nsString, exactly: substringRange) {
                let markerRange = list.range(at: 1)
                // Mockup list `padding-left: 20px` (L288): indent the whole list 20px,
                // with a hanging indent so wrapped lines align under the item text
                // (marker at 20, text continues ~16 further). 6px gap only BETWEEN
                // items; the last item drops it so the blank carries the 22px gap.
                let intraGap: CGFloat = isListItemLine(lines: lines, index: index + 1, nsString: nsString) ? 6 : 0
                let style = paragraphStyle(spacingAfter: intraGap)
                style.firstLineHeadIndent = 20
                style.headIndent = 36
                textStorage.addAttributes([.paragraphStyle: style], range: substringRange)
                textStorage.addAttributes(markerAttributes(font: markerFont), range: markerRange)
            }

            index += 1
        }
    }

    private static func applyInlineStyles(to textStorage: NSTextStorage, scope: NSRange) {
        let nsString = textStorage.string as NSString
        // Inline passes are bounded to `scope`. The inline regexes never match
        // across a newline (every pattern excludes `\n`), so a scope snapped to
        // whole lines/blocks cannot clip an inline run mid-match — a `**bold**`
        // or `` `code` `` always lives within a single line, hence within scope.
        let fullRange = scope

        applyDelimitedStyle(regex: strongStarRegex, trait: .boldFontMask, textStorage: textStorage, fullRange: fullRange)
        applyDelimitedStyle(regex: strongUnderscoreRegex, trait: .boldFontMask, textStorage: textStorage, fullRange: fullRange)
        applyDelimitedStyle(regex: italicStarRegex, trait: .italicFontMask, textStorage: textStorage, fullRange: fullRange)
        applyStrikethrough(textStorage: textStorage, fullRange: fullRange)

        for match in inlineCodeRegex.matches(in: nsString as String, range: fullRange).reversed() {
            textStorage.addAttributes([
                .font: inlineCodeFont,
                .foregroundColor: DesignTokens.titleText
            ], range: match.range)
            // Mark ONLY the code content (not the backticks, which dimMarkup hides)
            // so CardLayoutManager paints a rounded #F0F0F1 pill behind the text.
            let content = match.range(at: 1)
            if content.location != NSNotFound, content.length > 0 {
                textStorage.addAttributes([.mvInlineCode: true], range: content)
            }
            dimMarkup(in: match, contentIndex: 1, textStorage: textStorage)
        }

        for match in imageRegex.matches(in: nsString as String, range: fullRange).reversed() {
            textStorage.addAttributes([
                .foregroundColor: mutedColor,
                .font: NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask),
                .obliqueness: 0.15,
                // The image alt text is not body reading text - exclude from find.
                .mvNonBody: true
            ], range: match.range(at: 1))
            hideImageMarkup(in: match, textStorage: textStorage)
        }

        for match in linkRegex.matches(in: nsString as String, range: fullRange).reversed() {
            if match.range.location > 0 {
                let previousIndex = nsString.character(at: match.range.location - 1)
                if previousIndex == 33 {
                    continue
                }
            }
            textStorage.addAttributes([
                // Mockup rendered link (L372): color #1d1d1f, single underline tinted #C7C7CC.
                .foregroundColor: NSColor(hex: 0x1D1D1F),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: NSColor(hex: 0xC7C7CC)
            ], range: match.range(at: 1))
            let urlRange = match.range(at: 2)
            textStorage.addAttributes([
                .foregroundColor: mutedColor,
                .font: markerFont,
                // The link address (URL) is not body reading text - exclude from find.
                .mvNonBody: true
            ], range: urlRange)
            dimMarkup(in: match, contentIndex: 1, textStorage: textStorage)
        }
    }

    private static func applyStrikethrough(textStorage: NSTextStorage, fullRange: NSRange) {
        let source = textStorage.string
        for match in strikeRegex.matches(in: source, range: fullRange).reversed() {
            textStorage.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: mutedColor
            ], range: match.range(at: 1))
            dimMarkup(in: match, contentIndex: 1, textStorage: textStorage)
        }
    }

    private static func applyDelimitedStyle(regex: NSRegularExpression, trait: NSFontTraitMask, textStorage: NSTextStorage, fullRange: NSRange) {
        let source = textStorage.string
        for match in regex.matches(in: source, range: fullRange).reversed() {
            let contentRange = match.range(at: 1)
            applyFontTrait(trait, to: contentRange, in: textStorage)
            dimMarkup(in: match, contentIndex: 1, textStorage: textStorage)
        }
    }

    private static func applyFontTrait(_ trait: NSFontTraitMask, to range: NSRange, in textStorage: NSTextStorage) {
        textStorage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = (value as? NSFont) ?? bodyFont
            let converted = NSFontManager.shared.convert(font, toHaveTrait: trait)
            var attrs: [NSAttributedString.Key: Any] = [.font: converted]
            if trait == .italicFontMask {
                attrs[.obliqueness] = 0.15
            }
            textStorage.addAttributes(attrs, range: subrange)
        }
    }

    private static func dimMarkup(in match: NSTextCheckingResult, contentIndex: Int, textStorage: NSTextStorage) {
        let whole = match.range
        let content = match.range(at: contentIndex)

        if content.location > whole.location {
            textStorage.addAttributes(hiddenMarkupAttributes(), range: NSRange(location: whole.location, length: content.location - whole.location))
        }

        let contentEnd = content.location + content.length
        let wholeEnd = whole.location + whole.length
        if wholeEnd > contentEnd {
            textStorage.addAttributes(hiddenMarkupAttributes(), range: NSRange(location: contentEnd, length: wholeEnd - contentEnd))
        }
    }

    private static func hideImageMarkup(in match: NSTextCheckingResult, textStorage: NSTextStorage) {
        let whole = match.range
        let alt = match.range(at: 1)
        if alt.location > whole.location {
            textStorage.addAttributes(hiddenMarkupAttributes(), range: NSRange(location: whole.location, length: alt.location - whole.location))
        }
        let altEnd = alt.location + alt.length
        let wholeEnd = whole.location + whole.length
        if wholeEnd > altEnd {
            textStorage.addAttributes(hiddenMarkupAttributes(), range: NSRange(location: altEnd, length: wholeEnd - altEnd))
        }
    }

    private static func containsCJK(_ text: String) -> Bool {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return cjkRegex.firstMatch(in: text, range: range) != nil
    }

    private static func firstMatch(_ regex: NSRegularExpression, in nsString: NSString, exactly range: NSRange) -> NSTextCheckingResult? {
        regex.firstMatch(in: nsString as String, range: range).flatMap { match in
            match.range.location == range.location && match.range.length == range.length ? match : nil
        }
    }

    private static func markdownLines(in nsString: NSString, fullRange: NSRange) -> [(text: String, range: NSRange)] {
        var lines: [(String, NSRange)] = []
        nsString.enumerateSubstrings(in: fullRange, options: [.byLines, .substringNotRequired]) { _, substringRange, _, _ in
            lines.append((nsString.substring(with: substringRange), substringRange))
        }
        return lines
    }

    /// Whether the line at `index` renders as a list or task item — used so the
    /// intra-list 6px item gap only applies BETWEEN items; the last item drops it
    /// so the blank after the list carries the 22px list-block gap (no double count).
    private static func isListItemLine(lines: [(text: String, range: NSRange)], index: Int, nsString: NSString) -> Bool {
        guard index >= 0, index < lines.count else { return false }
        let r = lines[index].range
        guard r.length > 0 else { return false }
        return firstMatch(taskRegex, in: nsString, exactly: r) != nil
            || firstMatch(listRegex, in: nsString, exactly: r) != nil
    }

    private static func looksLikeTableLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|") && (trimmed.hasPrefix("|") || trimmed.hasSuffix("|"))
    }

    private static func isTableSeparatorLine(_ line: String) -> Bool {
        let cells = splitTableCells(line)
        guard cells.count >= 2 else { return false }
        return cells.allSatisfy { cell in
            let normalized = cell.replacingOccurrences(of: ":", with: "")
            return normalized.count >= 3 && normalized.allSatisfy { $0 == "-" }
        }
    }

    private static func applyTableBlock(rows: [(text: String, range: NSRange, isHeader: Bool)], separatorRange: NSRange, to textStorage: NSTextStorage) {
        let parsedRows = rows.map { row in
            (row: row, cells: parseTableCells(line: row.text, lineRange: row.range))
        }
        let columnCount = parsedRows.map { $0.cells.count }.max() ?? 0
        let columnWidths: [CGFloat] = (0..<columnCount).map { columnIndex in
            parsedRows.map { parsedRow in
                guard parsedRow.cells.indices.contains(columnIndex) else { return CGFloat(0) }
                let font = parsedRow.row.isHeader ? tableHeaderFont : tableBodyFont
                return measuredWidth(parsedRow.cells[columnIndex].visibleText, font: font)
            }.max() ?? 0
        }

        let lastIndex = parsedRows.count - 1
        for (rowIndex, parsedRow) in parsedRows.enumerated() {
            if parsedRow.row.isHeader {
                applyTableHeader(parsedRow.row.text, range: parsedRow.row.range, cells: parsedRow.cells, columnWidths: columnWidths, to: textStorage)
            } else {
                // The final body row omits its bottom hairline (mockup, L325 has no
                // border-bottom on the last `td`s).
                applyTableRow(parsedRow.row.text, range: parsedRow.row.range, cells: parsedRow.cells, columnWidths: columnWidths, isLastRow: rowIndex == lastIndex, to: textStorage)
            }
        }

        applyHiddenTableSeparator(range: separatorRange, to: textStorage)
    }

    private static func applyTableHeader(_ line: String, range: NSRange, cells: [TableCell], columnWidths: [CGFloat], to textStorage: NSTextStorage) {
        // Margins zeroed: the blank before the table carries the gap (#1 rhythm).
        let style = paragraphStyle(spacingBefore: 0, spacingAfter: 0)
        style.headIndent = 8
        style.firstLineHeadIndent = 8
        style.lineBreakMode = .byClipping
        // Borderless: no filled card behind the table. `.backgroundColor: .clear`
        // keeps the header-style assertion satisfied; `mvTableHeaderRule` makes
        // CardLayoutManager draw only the #ECECEE hairline under the header row.
        textStorage.addAttributes([
            // Mockup `th` (L317): 11px semibold sans, color #86868b, letter-spacing 0.4.
            // The 0.4 letter-spacing is applied per-cell in alignTableCells so its
            // width can be backed out of the column math (alignment self-test).
            .font: tableHeaderFont,
            .foregroundColor: DesignTokens.tertiaryText,
            .backgroundColor: NSColor.clear,
            .mvTableHeaderRule: true,
            .paragraphStyle: style
        ], range: range)
        alignTableCells(cells, columnWidths: columnWidths, rowFont: tableHeaderFont, letterSpacing: 0.4, textStorage: textStorage)
    }

    private static func applyTableRow(_ line: String, range: NSRange, cells: [TableCell], columnWidths: [CGFloat], isLastRow: Bool, to textStorage: NSTextStorage) {
        let style = paragraphStyle(spacingBefore: 0, spacingAfter: 0)
        style.headIndent = 8
        style.firstLineHeadIndent = 8
        style.lineBreakMode = .byClipping
        // Borderless white row; `mvTableBodyRule` draws only the #F4F4F5 hairline
        // under the row (mockup `td` border-bottom). Prose body cells render in the
        // document body sans font at the table's 13.5px font-size (mockup table
        // `font-size:13.5`, L314; `td` has no font-family override, L323/350).
        // The LAST body row omits the hairline (mockup, L325), so it is not stamped.
        var attrs: [NSAttributedString.Key: Any] = [
            .font: tableBodyFont,
            .paragraphStyle: style
        ]
        if !isLastRow {
            attrs[.mvTableBodyRule] = true
        }
        textStorage.addAttributes(attrs, range: range)
        alignTableCells(cells, columnWidths: columnWidths, rowFont: tableBodyFont, textStorage: textStorage)
    }

    private static func applyHiddenTableSeparator(range: NSRange, to textStorage: NSTextStorage) {
        let style = paragraphStyle(spacingBefore: 0, spacingAfter: 0)
        style.minimumLineHeight = 1
        style.maximumLineHeight = 1
        // Collapsed + invisible (the visible separator is now the header hairline).
        textStorage.addAttributes([
            .font: NSFont.systemFont(ofSize: 1),
            .foregroundColor: NSColor.clear,
            // The `---|---` separator line is not reading text - exclude from find.
            .mvNonBody: true,
            .paragraphStyle: style
        ], range: range)
    }

    private static func alignTableCells(_ cells: [TableCell], columnWidths: [CGFloat], rowFont: NSFont, letterSpacing: CGFloat = 0, textStorage: NSTextStorage) {
        let columnGap: CGFloat = 30

        let full = textStorage.string as NSString
        for (index, cell) in cells.enumerated() {
            if cell.contentRange.length > 0 {
                textStorage.addAttributes([.font: rowFont], range: cell.contentRange)
                // The visible text is trimmed, but contentRange spans the cell's
                // intra-pipe whitespace too. The kern alignment math measures only
                // `visibleText`, so render that surrounding whitespace at a hidden
                // (~zero) metric — otherwise a sans body row and the monospace
                // header would offset column 0 by their differing space widths.
                hideCellPadding(cell.contentRange, in: full, textStorage: textStorage)
                // Header letter-spacing (mockup `th` letter-spacing 0.4) is applied
                // here, to the VISIBLE cell text only, so its added width is known
                // and can be backed out of the column gap below (keeping the column
                // start aligned with the un-kerned body cell, per the self-test).
                if letterSpacing != 0, let visible = visibleContentRange(of: cell, in: full) {
                    textStorage.addAttributes([.kern: letterSpacing], range: visible)
                }
            }

            guard let trailingPipeRange = cell.trailingPipeRange else { continue }
            let currentWidth = measuredWidth(cell.visibleText, font: rowFont)
            let targetWidth = columnWidths.indices.contains(index) ? columnWidths[index] : currentWidth
            // The letter-spacing kern adds `letterSpacing` after each visible glyph,
            // shifting later columns right; subtract it from the gap so columns stay
            // aligned with the body row (which carries no kern).
            let kernWidth = letterSpacing * CGFloat(cell.visibleText.count)
            let addedSpace = max(columnGap, targetWidth - currentWidth + columnGap) - kernWidth
            // Collapse the pipe glyph to ~zero width (size-1 font); the column gap
            // comes entirely from `.kern`, so a monospace header pipe and a sans
            // body pipe no longer drift the following columns apart.
            var attrs = hiddenMarkupAttributes()
            if index < cells.count - 1 {
                attrs[.kern] = addedSpace
            }
            textStorage.addAttributes(attrs, range: trailingPipeRange)
        }

        if let first = cells.first?.leadingPipeRange {
            // Collapse the leading pipe to ~zero width (size-1 font) so column 0
            // starts at the same x for header (monospace) and body (sans) rows.
            textStorage.addAttributes(hiddenMarkupAttributes(), range: first)
        }
    }

    /// Collapse the leading/trailing whitespace inside a table cell's content
    /// range to a hidden (~zero-width) metric so the visible text starts exactly
    /// at the cell boundary regardless of the row's font. Keeps columns aligned
    /// when the body uses sans and the header uses monospace.
    private static func hideCellPadding(_ contentRange: NSRange, in full: NSString, textStorage: NSTextStorage) {
        guard contentRange.length > 0 else { return }
        // Collapse to a 1pt font so the whitespace contributes ~zero width.
        let collapsed = hiddenMarkupAttributes()
        let s = full.substring(with: contentRange) as NSString
        var leading = 0
        while leading < s.length, isASCIISpaceOrTab(s.character(at: leading)) { leading += 1 }
        // Whole cell is whitespace (empty cell): collapse it all.
        if leading == s.length {
            textStorage.addAttributes(collapsed, range: contentRange)
            return
        }
        var trailing = s.length - 1
        while trailing >= 0, isASCIISpaceOrTab(s.character(at: trailing)) { trailing -= 1 }
        if leading > 0 {
            textStorage.addAttributes(collapsed,
                                      range: NSRange(location: contentRange.location, length: leading))
        }
        let trailCount = (s.length - 1) - trailing
        if trailCount > 0 {
            textStorage.addAttributes(collapsed,
                                      range: NSRange(location: contentRange.location + contentRange.length - trailCount, length: trailCount))
        }
    }

    /// The sub-range of a cell's `contentRange` covering its trimmed visible text
    /// (excludes the leading/trailing intra-pipe whitespace that hideCellPadding
    /// collapses). Used to apply header letter-spacing to only the visible glyphs.
    private static func visibleContentRange(of cell: TableCell, in full: NSString) -> NSRange? {
        let contentRange = cell.contentRange
        guard contentRange.length > 0 else { return nil }
        let s = full.substring(with: contentRange) as NSString
        var leading = 0
        while leading < s.length, isASCIISpaceOrTab(s.character(at: leading)) { leading += 1 }
        if leading == s.length { return nil }   // whitespace-only cell
        var trailing = s.length - 1
        while trailing >= 0, isASCIISpaceOrTab(s.character(at: trailing)) { trailing -= 1 }
        let visibleLength = trailing - leading + 1
        guard visibleLength > 0 else { return nil }
        return NSRange(location: contentRange.location + leading, length: visibleLength)
    }

    private static func isASCIISpaceOrTab(_ c: unichar) -> Bool { c == 32 || c == 9 }

    private struct TableCell {
        let visibleText: String
        let contentRange: NSRange
        let leadingPipeRange: NSRange?
        let trailingPipeRange: NSRange?
    }

    private static func parseTableCells(line: String, lineRange: NSRange) -> [TableCell] {
        let nsLine = line as NSString
        var pipePositions: [Int] = []
        var searchLocation = 0
        while searchLocation < nsLine.length {
            let found = nsLine.range(of: "|", options: [], range: NSRange(location: searchLocation, length: nsLine.length - searchLocation))
            if found.location == NSNotFound { break }
            pipePositions.append(found.location)
            searchLocation = found.location + found.length
        }

        guard !pipePositions.isEmpty else {
            return [
                TableCell(
                    visibleText: line.trimmingCharacters(in: .whitespaces),
                    contentRange: lineRange,
                    leadingPipeRange: nil,
                    trailingPipeRange: nil
                )
            ]
        }

        var boundaries = pipePositions
        if boundaries.first != 0 {
            boundaries.insert(-1, at: 0)
        }
        if boundaries.last != nsLine.length - 1 {
            boundaries.append(nsLine.length)
        }

        var cells: [TableCell] = []
        for index in 0..<(boundaries.count - 1) {
            let startBoundary = boundaries[index]
            let endBoundary = boundaries[index + 1]
            let contentStart = startBoundary + 1
            let contentLength = max(0, endBoundary - contentStart)
            let contentRange = NSRange(location: lineRange.location + contentStart, length: contentLength)
            let text = contentLength > 0 ? nsLine.substring(with: NSRange(location: contentStart, length: contentLength)).trimmingCharacters(in: .whitespaces) : ""
            let leadingPipe = startBoundary >= 0 ? NSRange(location: lineRange.location + startBoundary, length: 1) : nil
            let trailingPipe = endBoundary < nsLine.length && nsLine.character(at: endBoundary) == 124 ? NSRange(location: lineRange.location + endBoundary, length: 1) : nil
            cells.append(TableCell(visibleText: text, contentRange: contentRange, leadingPipeRange: leadingPipe, trailingPipeRange: trailingPipe))
        }

        return cells.filter { !$0.visibleText.isEmpty || $0.trailingPipeRange != nil }
    }

    private static func splitTableCells(_ line: String) -> [String] {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }

        if cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        return cells
    }

    private static func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    private static func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: bodyFont,
            .foregroundColor: DesignTokens.bodyText,
            .paragraphStyle: paragraphStyle()
        ]
    }

    private static func markerAttributes(font: NSFont = markerFont) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: markerColor,
            // Dimmed list/quote markers are NOT reading text - exclude from find.
            .mvNonBody: true
        ]
    }

    private static func hiddenMarkupAttributes(font: NSFont = NSFont.systemFont(ofSize: 1)) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor.clear,
            // Truly-hidden syntax is never body text - exclude from find ("所见即所搜").
            .mvNonBody: true
        ]
    }

    /// Horizontal inset (points) of the code TEXT from the card's left/right
    /// edges. Mirrors `CardLayoutManager.cardPadX` so the painted card hugs the
    /// indented text (mockup `pre` padding 16px, Markdown Viewer.dc.html ~299).
    static let codeCardPadX: CGFloat = 16
    enum CodeLineRole { case open, body, close }

    private static func codeParagraphStyle(role: CodeLineRole) -> NSMutableParagraphStyle {
        // Margins zeroed: the blank lines around the fence carry the 22px outer
        // gaps (#1 rhythm). The card's 12px top/bottom padding (drawn by
        // CardLayoutManager) sits inside that 22px blank, leaving ~10px clearance.
        let style = paragraphStyle()
        // Inset the code text inside the card on both sides.
        style.firstLineHeadIndent = codeCardPadX
        style.headIndent = codeCardPadX
        style.tailIndent = -codeCardPadX
        // The mockup's `<pre>` is `overflow-x: auto` — long lines do NOT soft-wrap.
        // `.byClipping` makes an over-long code line clip at the card edge instead of
        // wrapping to a second line, matching that behavior without breaking the
        // single-text-view layout or the card drawing (the card spans line fragments,
        // which stay one-per-line under clipping).
        style.lineBreakMode = .byClipping
        return style
    }

    /// Mark the newline that immediately FOLLOWS a code line's `lineRange` with the
    /// `.mvCodeBlock` attribute (and the code paragraph style, so the empty line
    /// keeps the card's left inset). `enumerateSubstrings(.byLines)` excludes line
    /// terminators, so consecutive code lines would otherwise leave the joining `\n`
    /// unmarked — and a 0-length empty line would leave a gap in the `.mvCodeBlock`
    /// character run, splitting the card. Marking the terminator keeps the run
    /// contiguous from the open fence through the close fence.
    private static func markCodeBlockNewline(after lineRange: NSRange, in nsString: NSString, textStorage: NSTextStorage) {
        let newlineIndex = lineRange.location + lineRange.length
        guard newlineIndex < nsString.length else { return }
        let c = nsString.character(at: newlineIndex)
        guard c == 0x0A || c == 0x0D else { return }
        textStorage.addAttributes([
            .mvCodeBlock: true,
            .paragraphStyle: codeParagraphStyle(role: .body)
        ], range: NSRange(location: newlineIndex, length: 1))
    }

    /// Attributes for a code line. `mvCodeBlock` marks the run so
    /// `CardLayoutManager` paints the rounded #FAFAFA card+border behind it; the
    /// flat `.backgroundColor` fill is intentionally gone (the card replaces it).
    private static func codeBlockAttributes(role: CodeLineRole = .body) -> [NSAttributedString.Key: Any] {
        [
            .font: codeFont,
            // Fenced `pre` color is #444 (mockup), slightly lighter than body #333336.
            .foregroundColor: NSColor(hex: 0x444444),
            .mvCodeBlock: true,
            // NOTE: no `.mvNonBody` here. Fenced code CONTENT is visible reading text,
            // so "所见即所搜" find must MATCH it. Only the truly-hidden bits of a code
            // block stay excluded, and they carry `.mvNonBody` via their own attrs: the
            // ``` fence markers + tail (hiddenMarkupAttributes) and the language label
            // (codeLanguageLabelAttributes). A bare/closing fence line is fully hidden.
            .paragraphStyle: codeParagraphStyle(role: role)
        ]
    }

    /// The character range of the language token on an opening fence line (the
    /// text after the leading ```), or nil if the fence has no language. Trailing
    /// whitespace and any info-string remainder after the first word are excluded.
    private static func fenceLanguageRange(line: String, lineRange: NSRange) -> NSRange? {
        let ns = line as NSString
        // Locate the opening ``` (it may be indented by leading whitespace).
        let backtickRange = ns.range(of: "```")
        guard backtickRange.location != NSNotFound else { return nil }
        var i = backtickRange.location + backtickRange.length
        let length = ns.length
        // Skip any whitespace between ``` and the language word.
        while i < length, isWhitespaceUnichar(ns.character(at: i)) { i += 1 }
        let start = i
        // The language is the first whitespace-delimited word of the info string.
        while i < length, !isWhitespaceUnichar(ns.character(at: i)) { i += 1 }
        guard i > start else { return nil }
        return NSRange(location: lineRange.location + start, length: i - start)
    }

    private static func isWhitespaceUnichar(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09
    }

    /// Small uppercase-style gray label for the fenced-code language token
    /// (mockup: font-size 10.5, letter-spacing 0.6, color #b3b3b8, uppercase).
    /// True text-transform is omitted: this is live-editable text, so the
    /// displayed characters must stay byte-identical to what the user typed.
    private static func codeLanguageLabelAttributes() -> [NSAttributedString.Key: Any] {
        // No `.backgroundColor`: the CardLayoutManager paints the #FAFAFA card
        // behind this label. Reuse the `.open` paragraph style so the label keeps
        // the card's top spacing + left inset and stays inside the card padding.
        [
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor(hex: 0xB3B3B8),
            .kern: 0.6,
            .mvCodeBlock: true,
            // Dimmed code-fence language label is not reading text - exclude from find.
            .mvNonBody: true,
            .paragraphStyle: codeParagraphStyle(role: .open)
        ]
    }

    private static func headingFont(level: Int) -> NSFont {
        switch level {
        case 1:
            return NSFont.systemFont(ofSize: 26, weight: .semibold)
        case 2:
            return NSFont.systemFont(ofSize: 18, weight: .semibold)
        case 3:
            return NSFont.systemFont(ofSize: 16, weight: .semibold)
        default:
            return NSFont.systemFont(ofSize: 15.5, weight: .semibold)
        }
    }

    private static func headingParagraphStyle(level: Int) -> NSParagraphStyle {
        // Margins are zeroed: the blank line before/after a heading carries the
        // collapsed gap (see classifyBlock / the blank-line branch). H1's larger
        // top/bottom and H2/H3's are encoded as BlockKind margins, not here.
        paragraphStyle()
    }

    private static func paragraphStyle(spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 0) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.7
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacingAfter
        return style
    }
}
