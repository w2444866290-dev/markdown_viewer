import AppKit

extension LiveMarkdownStyler {
    private static let codeFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

    /// One fenced code block recovered from the source. `containerRange` spans the
    /// opening fence line through the closing fence line (used to compute the
    /// block's on-screen rect for the top-right copy button). `bodyRange` covers
    /// ONLY the code lines between the fences - it EXCLUDES both ``` fence lines
    /// and the opening fence's language token, so copying yields the raw code body.
    struct FencedCodeBlock {
        let containerRange: NSRange
        let bodyRange: NSRange
    }

    /// Enumerate the fenced code blocks in `nsString`, reusing the SAME
    /// ``` -toggle line scan that `applyLineStyles` uses to style them (so the copy
    /// button targets exactly the blocks the styler colors - inline `code` is never
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
                // Unterminated fence: stop (no closing ``` -> not a real block).
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
        // The mockup's `<pre>` is `overflow-x: auto` - long lines do NOT soft-wrap.
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
    /// unmarked - and a 0-length empty line would leave a gap in the `.mvCodeBlock`
    /// character run, splitting the card. Marking the terminator keeps the run
    /// contiguous from the open fence through the close fence.
    static func markCodeBlockNewline(after lineRange: NSRange, in nsString: NSString, textStorage: NSTextStorage) {
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
    static func codeBlockAttributes(role: CodeLineRole = .body) -> [NSAttributedString.Key: Any] {
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
    static func fenceLanguageRange(line: String, lineRange: NSRange) -> NSRange? {
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
    static func codeLanguageLabelAttributes() -> [NSAttributedString.Key: Any] {
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
}
