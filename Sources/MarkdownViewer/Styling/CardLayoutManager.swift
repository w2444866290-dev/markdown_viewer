import AppKit
import UniformTypeIdentifiers

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
