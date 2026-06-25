import AppKit

/// Find/replace engine for NSTextView. Owns search state (matches, index),
/// applies/clears temporary highlights, and coordinates navigation.
final class FindController {
    weak var textView: NSTextView?
    var matches: [NSTextCheckingResult] = []
    var currentIndex = 0

    /// True when the last search used regex mode and the pattern failed to compile.
    private(set) var lastPatternInvalid = false

    struct Options {
        var query = ""
        var caseSensitive = false
        var wholeWord = false
        var useRegex = false
    }

    var isEmpty: Bool { matches.isEmpty }

    func search(_ opts: Options) {
        clearHighlights()
        matches = []
        currentIndex = 0
        lastPatternInvalid = false

        guard !opts.query.isEmpty, let tv = textView else { return }

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
            return
        }

        let ns = tv.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        matches = regex.matches(in: tv.string, range: full).filter { $0.range.length > 0 }
        currentIndex = 0
        applyHighlights()
        scrollToCurrent()
    }

    func navigate(_ delta: Int) {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex + delta + matches.count) % matches.count
        applyHighlights()
        scrollToCurrent()
    }

    func replaceCurrent(with text: String, restyle: () -> Void, redo: () -> Void) {
        guard matches.indices.contains(currentIndex),
              let tv = textView, let storage = tv.textStorage else { return }
        let range = matches[currentIndex].range
        guard tv.shouldChangeText(in: range, replacementString: text) else { return }
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
        for m in matches.reversed() { storage.replaceCharacters(in: m.range, with: text) }
        tv.didChangeText()
        restyle()
        matches = []
        currentIndex = 0
        Task { @MainActor in Toaster.shared.flash("已替换 " + String(count) + " 处") }
    }

    private func clearHighlights() {
        guard let lm = textView?.layoutManager, let s = textView?.string else { return }
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: s.utf16.count))
    }

    private func applyHighlights() {
        guard let lm = textView?.layoutManager else { return }
        clearHighlights()
        for (i, m) in matches.enumerated() {
            let c = i == currentIndex ? DesignTokens.accentStrong : DesignTokens.accentSoft
            lm.addTemporaryAttributes([.backgroundColor: c], forCharacterRange: m.range)
        }
    }

    private func scrollToCurrent() {
        guard matches.indices.contains(currentIndex) else { return }
        textView?.scrollRangeToVisible(matches[currentIndex].range)
    }
}
