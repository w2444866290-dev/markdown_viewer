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

    // Cached minY (one per heading, in document order → ascending) so the
    // throttled scroll path is O(log n) instead of O(headings × doc-length).
    private var headingYs: [CGFloat] = []

    // Cheap layout-version key derived from current geometry. When it (and the
    // heading count) match the stored key, headingYs is still valid and we skip
    // the expensive layout queries — the pure-scroll fast path.
    private struct LayoutKey: Equatable {
        let count: Int
        let containerWidth: CGFloat
        let usedHeight: CGFloat
    }
    private var cacheKey: LayoutKey?

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
        // Amber flash fading 0.30 → 0 over ~0.7s (web washHeading). Each step
        // re-applies a lower-alpha temporary background AND forces a redraw of the
        // line — removeTemporaryAttribute alone does NOT repaint, which previously
        // left the highlight stuck on screen ("一直高亮").
        let steps = 12
        let total = 0.7
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            DispatchQueue.main.asyncAfter(deadline: .now() + total * t) { [weak tv] in
                guard let tv, let lm = tv.layoutManager else { return }
                if i == steps {
                    lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: lineRange)
                } else {
                    let amber = NSColor(hex: 0xE8A33D, alpha: CGFloat(0.30 * (1 - t)))
                    lm.addTemporaryAttribute(.backgroundColor, value: amber, forCharacterRange: lineRange)
                }
                lm.invalidateDisplay(forCharacterRange: lineRange)
            }
        }
    }

    /// Rebuilds `headingYs` only when geometry actually changed. On a pure
    /// scroll the layout key still matches, so this returns immediately and the
    /// expensive per-heading layout queries are skipped entirely.
    private func ensureHeadingYsFresh() {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else {
            headingYs = []
            cacheKey = nil
            return
        }
        let key = LayoutKey(
            count: headings.count,
            containerWidth: tc.size.width,
            usedHeight: lm.usedRect(for: tc).height
        )
        if key == cacheKey, headingYs.count == headings.count { return }

        // Bridge the document once, not once per heading.
        let ns = tv.string as NSString
        var ys: [CGFloat] = []
        ys.reserveCapacity(headings.count)
        for h in headings {
            let lr = ns.lineRange(for: NSRange(location: h.charIndex, length: 0))
            let gr = lm.glyphRange(forCharacterRange: lr, actualCharacterRange: nil)
            var r = lm.boundingRect(forGlyphRange: gr, in: tc)
            r.origin.y += tv.textContainerInset.height
            ys.append(r.minY)
        }
        headingYs = ys
        cacheKey = key
    }

    func activeIndex(for scrollY: CGFloat) -> Int {
        ensureHeadingYsFresh()
        guard !headingYs.isEmpty else { return 0 }
        let threshold = scrollY + 140
        // Binary search for the LAST index whose minY <= threshold (default 0).
        // headingYs is ascending (document order), so this is identical to the
        // old linear scan that set active=i while minY<=threshold and broke at
        // the first minY>threshold.
        var lo = 0
        var hi = headingYs.count - 1
        var active = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if headingYs[mid] <= threshold {
                active = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return active
    }
}
