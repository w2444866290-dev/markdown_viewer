import AppKit

/// Manages a floating "复制" button that appears over fenced code blocks
/// when the mouse hovers over them.
final class CodeOverlayController {
    weak var textView: NSTextView?
    private var button: NSButton?
    private var bodyRange: NSRange?

    func handleMouse(at tvPoint: NSPoint) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let ns = storage.string as NSString
        for block in LiveMarkdownStyler.fencedCodeBlocks(in: ns) {
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
        btn.frame = NSRect(x: rect.maxX - 50, y: rect.minY + 8, width: 44, height: 20)
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
    }
}
