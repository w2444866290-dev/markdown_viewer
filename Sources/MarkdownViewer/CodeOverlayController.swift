import AppKit

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
        for block in blocks {
            let glyphRange = tv.layoutManager!.glyphRange(forCharacterRange: block.bodyRange, actualCharacterRange: nil)
            var rect = tv.layoutManager!.boundingRect(forGlyphRange: glyphRange, in: tv.textContainer!)
            rect.origin.y += tv.textContainerInset.height
            if rect.contains(tvPoint) {
                show(for: block, in: tv)
                return
            }
        }
        hide()
    }

    private func show(for block: LiveMarkdownStyler.FencedCodeBlock, in tv: NSTextView) {
        bodyRange = block.bodyRange
        if button == nil {
            let btn = NSButton(title: "复制", target: self, action: #selector(copyCode))
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
        let glyphRange = tv.layoutManager!.glyphRange(forCharacterRange: block.bodyRange, actualCharacterRange: nil)
        var rect = tv.layoutManager!.boundingRect(forGlyphRange: glyphRange, in: tv.textContainer!)
        rect.origin.y += tv.textContainerInset.height
        // Pin the button to the card's top-right corner. The card spans the full
        // textContainer column width (not the longest code line), so base x on the
        // card's right edge instead of rect.maxX (the glyph bounding box).
        let cardLeft = tv.textContainerInset.width
        let cardRight = cardLeft + tv.textContainer!.size.width
        let btnWidth: CGFloat = 44
        btn.frame = NSRect(x: cardRight - btnWidth - 14, y: rect.minY + 8, width: btnWidth, height: 20)
        btn.isHidden = false
        btn.animator().alphaValue = 1
    }

    func hide() {
        bodyRange = nil
        button?.alphaValue = 0
        button?.isHidden = true
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
