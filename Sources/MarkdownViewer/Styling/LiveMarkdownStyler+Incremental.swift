import AppKit

extension LiveMarkdownStyler {
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
    /// whole paragraph - `paragraphRange` includes a paragraph's trailing newline,
    /// and the following blank-line separator's newline sits right after it, so a
    /// paragraph-wide region would see the pre-existing `\n\n` block separator and
    /// (wrongly) full-restyle on EVERY keystroke. By examining only the edit's own
    /// neighbourhood we catch structural chars the edit INTRODUCED or BORDERS, while
    /// a plain within-line edit (no structural char nearby) stays incremental.
    ///
    /// The slack (`pad`) lets a deletion that joined onto an adjacent structural
    /// char - e.g. backspacing into a `\n`, a `|`, or a fence - still be seen, since
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
        //    the scoped pass can't be trusted - full restyle.
        if region.contains("```") { return true }

        // 2) A newline the EDIT ITSELF introduced (Enter → could split a block or
        //    create a `\n\n` blank line). A plain-character insertion CANNOT change
        //    block structure, so we no longer full-restyle merely because a
        //    pre-existing blank line sits NEAR the edit - that proximity check made
        //    every paragraph-boundary keystroke full-restyle (measured inc:1 full:110,
        //    the fast-typing lag). Deletions (length 0, removed text unknowable) rely
        //    on `blockScope` expanding to the neighbouring block on each side, which
        //    re-styles a block MERGE (deleting a lone blank line) correctly.
        if editedRange.length > 0, nsString.substring(with: editedRange).contains("\n") { return true }

        // 3) A table pipe `|`. Adding/removing a pipe can turn a paragraph into a
        //    table (or vice-versa) and changes the multi-row column grouping, which
        //    spans lines the scope may not cover - full restyle.
        if region.contains("|") { return true }

        // 4) The edited region contains a run of 3+ `-`, `*`, or `_` - a possible
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
    /// may sit INSIDE a pre-existing fence - we detect that and expand to the whole
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
    /// their true neighbours). Never crosses a fenced code block - if expansion
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
        // scope starts at a blank-line (or doc) boundary - so `insideCodeBlock`
        // begins false - and includes the preceding block so a leading blank's
        // collapsed gap (max(prevBlock.marginBottom, nextBlock.marginTop)) is
        // recomputed against its true previous block. If expansion would touch a
        // fence line, bail to a full restyle (we can't recover the fence's
        // insideCodeBlock state without including the whole - possibly large -
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
    /// styled. Only well-formed (closed) blocks are returned - an unterminated fence
    /// is not a block here (and a ``` near the edit already triggers full restyle).
    private static func enclosingFenceContainer(for editedRange: NSRange, in nsString: NSString) -> NSRange? {
        let editStart = editedRange.location
        let editEnd = editedRange.location + editedRange.length
        for block in fencedCodeBlocks(in: nsString) {
            let bStart = block.containerRange.location
            let bEnd = block.containerRange.location + block.containerRange.length
            // Strictly inside the container (not on a fence line - those changes are
            // structural and already handled by requiresFullRestyle).
            if editStart >= bStart && editEnd <= bEnd {
                return block.containerRange
            }
        }
        return nil
    }
}
