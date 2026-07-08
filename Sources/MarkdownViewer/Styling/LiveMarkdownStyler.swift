import AppKit
import UniformTypeIdentifiers

enum LiveMarkdownStyler {
    static var bodyPointSize: CGFloat = 15.5
    static var bodyFont: NSFont { NSFont.systemFont(ofSize: bodyPointSize) }

    private static let markerFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    // Inline `code` runs are 13px (mockup); the fenced code BLOCK stays 12.5.
    private static let inlineCodeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let boldCodeFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
    // Mockup table header `th` (L317): 11px semibold sans, #86868b, letter-spacing 0.4.
    static let tableHeaderFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    // Mockup table body `td` (L323): 13.5px (table font-size, L314), body sans.
    static let tableBodyFont = NSFont.systemFont(ofSize: 13.5)
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

        // Emphasis (`**`/`__`/`*`/`~~`) must NOT treat a delimiter that lives inside
        // code as a boundary: a `*` inside `` `reader__*` `` broke bold pairing for
        // the rest of the line, and `__` in an identifier got mis-bolded. Match the
        // emphasis regexes against a copy with every inline-code + code-block span
        // blanked to spaces (length preserved, so ranges still map onto the storage).
        // No code in scope → the raw string is returned, so prose pays nothing.
        let emphasisSource = maskedEmphasisSource(textStorage, nsString: nsString, scope: fullRange)
        applyDelimitedStyle(regex: strongStarRegex, trait: .boldFontMask, textStorage: textStorage, source: emphasisSource, fullRange: fullRange)
        applyDelimitedStyle(regex: strongUnderscoreRegex, trait: .boldFontMask, textStorage: textStorage, source: emphasisSource, fullRange: fullRange)
        applyDelimitedStyle(regex: italicStarRegex, trait: .italicFontMask, textStorage: textStorage, source: emphasisSource, fullRange: fullRange)
        applyStrikethrough(textStorage: textStorage, source: emphasisSource, fullRange: fullRange)

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

    /// A copy of the storage text with every inline-code and code-block span blanked
    /// to spaces (same length, so match ranges still map 1:1 onto the storage). Used
    /// as the source for the emphasis regexes so a `*`/`_`/`~` inside code is never
    /// read as a delimiter. Returns the raw string unchanged when `scope` has no code
    /// at all, so the common prose path allocates nothing.
    private static func maskedEmphasisSource(_ textStorage: NSTextStorage, nsString: NSString, scope: NSRange) -> String {
        var codeRanges: [NSRange] = []
        for m in inlineCodeRegex.matches(in: nsString as String, range: scope) {
            codeRanges.append(m.range)
        }
        textStorage.enumerateAttribute(.mvCodeBlock, in: scope, options: []) { value, range, _ in
            if (value as? Bool) == true, range.length > 0 { codeRanges.append(range) }
        }
        guard !codeRanges.isEmpty else { return nsString as String }
        let masked = NSMutableString(string: nsString)
        for r in codeRanges where NSMaxRange(r) <= masked.length {
            masked.replaceCharacters(in: r, with: String(repeating: " ", count: r.length))
        }
        return masked as String
    }

    private static func applyStrikethrough(textStorage: NSTextStorage, source: String, fullRange: NSRange) {
        for match in strikeRegex.matches(in: source, range: fullRange).reversed() {
            textStorage.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: mutedColor
            ], range: match.range(at: 1))
            dimMarkup(in: match, contentIndex: 1, textStorage: textStorage)
        }
    }

    private static func applyDelimitedStyle(regex: NSRegularExpression, trait: NSFontTraitMask, textStorage: NSTextStorage, source: String, fullRange: NSRange) {
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
        style.lineHeightMultiple = 1.7
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacingAfter
        return style
    }
}
