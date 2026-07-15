import AppKit
import UniformTypeIdentifiers

enum LiveMarkdownStyler {
    static var bodyPointSize: CGFloat = 16.5
    static var bodyFont: NSFont { NSFont.systemFont(ofSize: bodyPointSize) }

    private static let markerFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    private static let boldCodeFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
    private static let markerColor = DesignTokens.placeholderText
    private static let codeBackground = DesignTokens.codeBackground
    private static let quoteBackground = NSColor.clear

    private static let headingRegex = try! NSRegularExpression(pattern: "^(#{1,6})\\s+(.+)$", options: [.anchorsMatchLines])
    private static let cjkRegex = try! NSRegularExpression(pattern: "[\u{2E80}-\u{9FFF}\u{3040}-\u{30FF}\u{AC00}-\u{D7AF}\u{FF00}-\u{FFEF}\u{3000}-\u{303F}]")
    private static let listRegex = try! NSRegularExpression(pattern: "^(\\s*(?:[-*+] |\\d+\\. ))(.+)$", options: [.anchorsMatchLines])
    private static let taskRegex = try! NSRegularExpression(pattern: "^(\\s*[-*+] \\[[ xX]\\] )(.+)$", options: [.anchorsMatchLines])

    static func apply(to textStorage: NSTextStorage) {
        let fullRange = NSRange(location: 0, length: textStorage.length)
        guard fullRange.length > 0 else { return }

        textStorage.beginEditing()
        textStorage.setAttributes(baseAttributes(), range: fullRange)
        applyScopedStyles(to: textStorage, scope: fullRange)
        textStorage.endEditing()
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
        if isTableBlockStart(lines: lines, index: index) {
            return .table
        }
        if firstMatch(taskRegex, in: nsString, exactly: lines[index].range) != nil { return .list }
        if firstMatch(listRegex, in: nsString, exactly: lines[index].range) != nil { return .list }
        return .paragraph
    }

    static func applyScopedStyles(to textStorage: NSTextStorage, scope: NSRange) {
        applyLineStyles(to: textStorage, scope: scope)
        applyInlineStyles(to: textStorage, scope: scope)
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
                    applyCodeBlockBodyLine(lineRange: substringRange, in: nsString, textStorage: textStorage)
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
                applyCodeFenceLine(line: line, lineRange: substringRange, isOpening: isOpeningFence, in: nsString, textStorage: textStorage)
                insideCodeBlock.toggle()
                index += 1
                continue
            }

            if insideCodeBlock {
                applyCodeBlockBodyLine(lineRange: substringRange, in: nsString, textStorage: textStorage)
                index += 1
                continue
            }

            if let nextIndex = applyTableBlockIfPresent(lines: lines, index: index, to: textStorage) {
                index = nextIndex
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

    private static func containsCJK(_ text: String) -> Bool {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return cjkRegex.firstMatch(in: text, range: range) != nil
    }

    private static func firstMatch(_ regex: NSRegularExpression, in nsString: NSString, exactly range: NSRange) -> NSTextCheckingResult? {
        regex.firstMatch(in: nsString as String, range: range).flatMap { match in
            match.range.location == range.location && match.range.length == range.length ? match : nil
        }
    }

    static func markdownLines(in nsString: NSString, fullRange: NSRange) -> [(text: String, range: NSRange)] {
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

    static func hiddenMarkupAttributes(font: NSFont = NSFont.systemFont(ofSize: 1)) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor.clear,
            // Truly-hidden syntax is never body text - exclude from find ("所见即所搜").
            .mvNonBody: true
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

    static func paragraphStyle(spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 0) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = DesignTokens.bodyLineHeight
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacingAfter
        return style
    }
}
