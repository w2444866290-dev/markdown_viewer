import AppKit

/// Parses Markdown headings from NSTextView content and supports
/// scroll-to-heading navigation.
final class OutlineController {
    weak var textView: NSTextView?

    struct Heading: Identifiable {
        let id: Int
        let title: String
        let level: Int
        let charIndex: Int
    }

    private(set) var headings: [Heading] = []

    func rebuild() {
        guard let tv = textView else { headings = []; return }
        let ns = tv.string as NSString
        var entries: [Heading] = []
        var inCode = false
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { sub, range, _, _ in
            guard let line = sub else { return }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { inCode.toggle(); return }
            guard !inCode else { return }
            var lvl = 0
            for ch in t { if ch == "#" { lvl += 1 } else { break } }
            guard (1...6).contains(lvl), t.count > lvl, t[t.index(t.startIndex, offsetBy: lvl)] == " " else { return }
            let title = String(t.dropFirst(lvl + 1)).trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return }
            entries.append(Heading(id: entries.count, title: title, level: lvl, charIndex: range.location))
        }
        headings = entries
    }

    func jumpTo(_ charIndex: Int) {
        guard let tv = textView, let sv = tv.enclosingScrollView else { return }
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let ns = tv.string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: charIndex, length: 0))
        let glyphRange = lm.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        rect.origin.y += tv.textContainerInset.height
        let target = max(0, min(rect.minY - 40, max(0, tv.frame.height - sv.contentView.bounds.height)))
        sv.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: target))
        washHeading(lineRange, in: tv, lm: lm)
    }

    /// Amber "wash" flash on the jumped-to heading line, mirroring the web
    /// washHeading animation (bg rgba(232,163,61,0.30) → 0 over ~900ms).
    /// Clears only this line's range so it won't disturb find highlights, which
    /// use the same .backgroundColor temporary attribute on other ranges.
    private func washHeading(_ lineRange: NSRange, in tv: NSTextView, lm: NSLayoutManager) {
        let wash = NSColor(hex: 0xE8A33D, alpha: 0.30)
        lm.addTemporaryAttribute(.backgroundColor, value: wash, forCharacterRange: lineRange)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak tv] in
            guard let tv, let lm = tv.layoutManager else { return }
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: lineRange)
        }
    }

    func activeIndex(for scrollY: CGFloat) -> Int {
        guard let tv = textView, !headings.isEmpty else { return 0 }
        let threshold = scrollY + 140
        var active = 0
        for (i, h) in headings.enumerated() {
            let ns = tv.string as NSString
            let lr = ns.lineRange(for: NSRange(location: h.charIndex, length: 0))
            let gr = tv.layoutManager!.glyphRange(forCharacterRange: lr, actualCharacterRange: nil)
            var r = tv.layoutManager!.boundingRect(forGlyphRange: gr, in: tv.textContainer!)
            r.origin.y += tv.textContainerInset.height
            if r.minY <= threshold { active = i } else { break }
        }
        return active
    }
}
