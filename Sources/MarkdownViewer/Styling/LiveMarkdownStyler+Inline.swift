import AppKit

extension LiveMarkdownStyler {
    // Inline `code` runs are 13px (mockup); the fenced code BLOCK stays 12.5.
    private static let inlineCodeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let linkURLFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    private static let mutedColor = DesignTokens.secondaryText

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
               nsString.character(at: match.range.location - 1) == 33 { // '!' -> image
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
               nsString.character(at: match.range.location - 1) == 33 { // '!' -> image
                continue
            }
            let urlRange = match.range(at: 2)
            guard urlRange.location != NSNotFound else { continue }
            result.append((range: match.range, url: nsString.substring(with: urlRange)))
        }
        return result
    }

    static func applyInlineStyles(to textStorage: NSTextStorage, scope: NSRange) {
        let nsString = textStorage.string as NSString
        // Inline passes are bounded to `scope`. The inline regexes never match
        // across a newline (every pattern excludes `\n`), so a scope snapped to
        // whole lines/blocks cannot clip an inline run mid-match - a `**bold**`
        // or `` `code` `` always lives within a single line, hence within scope.
        let fullRange = scope

        // Emphasis (`**`/`__`/`*`/`~~`) must NOT treat a delimiter that lives inside
        // code as a boundary: a `*` inside `` `reader__*` `` broke bold pairing for
        // the rest of the line, and `__` in an identifier got mis-bolded. Match the
        // emphasis regexes against a copy with every inline-code + code-block span
        // blanked to spaces (length preserved, so ranges still map onto the storage).
        // No code in scope -> the raw string is returned, so prose pays nothing.
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
                .font: linkURLFont,
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
}
