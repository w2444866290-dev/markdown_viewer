import AppKit

/// NSButton that shows the pointing-hand cursor over the text view. The parent
/// PaperTextView has empty cursor rects + no-op cursorUpdate, so this button's own
/// cursor rect wins cleanly (no I-beam fight).
private final class HandButton: NSButton {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Manages a floating "复制" button that appears over fenced code blocks
/// when the mouse hovers over them.
final class CodeOverlayController {
    weak var textView: NSTextView?
    private var button: NSButton?
    private var bodyRange: NSRange?
    /// Fenced code blocks for the current text version, supplied by the
    /// coordinator on each text change. Used instead of re-parsing the whole
    /// document on every mouseMoved (the hot path here is hover hit-testing).
    var blocks: [LiveMarkdownStyler.FencedCodeBlock] = []

    func handleMouse(at tvPoint: NSPoint) {
        guard let tv = textView else { return }
        // Use the cached blocks; fall back to a live parse if the cache is empty
        // so the copy button always appears when the doc actually has code fences.
        let list = blocks.isEmpty ? LiveMarkdownStyler.fencedCodeBlocks(in: tv.string as NSString) : blocks
        for block in list {
            let card = cardRect(for: block, in: tv)
            // Hover region is the WHOLE card (full column width × block height),
            // not just the code-text glyph box — otherwise the right-edge button
            // is unreachable: moving toward it leaves the text box and hides it.
            if card.contains(tvPoint) {
                show(for: block, cardRect: card, in: tv)
                return
            }
        }
        // Keep it shown while the cursor is on the button itself (it can sit a hair
        // past the card's measured edge); only hide once the cursor is truly away.
        if hitsButton(tvPoint) { return }
        hide()
    }

    /// On-screen rect of a fenced block's card: full textContainer column width,
    /// spanning the whole block (fence/lang line through body) + a little slack —
    /// matches the painted #FAFAFA card and is the hover/hit region.
    private func cardRect(for block: LiveMarkdownStyler.FencedCodeBlock, in tv: NSTextView) -> NSRect {
        let lm = tv.layoutManager!, tc = tv.textContainer!
        let glyphs = lm.glyphRange(forCharacterRange: block.containerRange, actualCharacterRange: nil)
        var r = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        r.origin.y += tv.textContainerInset.height
        let left = tv.textContainerInset.width
        return NSRect(x: left, y: r.minY - 4, width: tc.size.width, height: r.height + 8)
    }

    private func show(for block: LiveMarkdownStyler.FencedCodeBlock, cardRect: NSRect, in tv: NSTextView) {
        bodyRange = block.bodyRange
        if button == nil {
            let btn = HandButton(title: "复制", target: self, action: #selector(copyCode))
            btn.identifier = NSUserInterfaceItemIdentifier("mvCopyButton")
            btn.isBordered = false
            btn.bezelStyle = .inline
            btn.font = NSFont.systemFont(ofSize: 11)
            btn.contentTintColor = DesignTokens.placeholderText
            btn.wantsLayer = true
            btn.layer?.cornerRadius = 5
            btn.isHidden = true
            tv.addSubview(btn)
            button = btn
        }
        guard let btn = button else { return }
        // Top-right corner of the card (independent of code-line length).
        let btnWidth: CGFloat = 44
        btn.frame = NSRect(x: cardRect.maxX - btnWidth - 14, y: cardRect.minY + 6, width: btnWidth, height: 20)
        btn.isHidden = false
        btn.animator().alphaValue = 1
    }

    func hide() {
        bodyRange = nil
        button?.alphaValue = 0
        button?.isHidden = true
    }

    /// True when point `p` (text-view coords) is over the visible copy button.
    func hitsButton(_ p: NSPoint) -> Bool {
        guard let b = button, !b.isHidden else { return false }
        return b.frame.contains(p)
    }

    @objc private func copyCode() {
        guard let range = bodyRange, let tv = textView else { return }
        let ns = tv.string as NSString
        var body = ns.substring(with: range)
        if body.hasSuffix("\n") { body.removeLast() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
        Task { @MainActor in Toaster.shared.flash("已复制代码") }
    }
}
