import SwiftUI
import AppKit

struct EditorView: NSViewRepresentable {
    @Binding var text: String
    @Binding var fontIndex: Int
    var isMarkdown: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.scrollerStyle = .overlay
        sv.drawsBackground = true
        sv.backgroundColor = .white

        let tv = PaperTextView(frame: .zero)
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.font = NSFont.systemFont(ofSize: DesignTokens.bodyFontSizes[fontIndex])
        tv.textColor = DesignTokens.bodyText
        tv.backgroundColor = DesignTokens.paper
        tv.insertionPointColor = DesignTokens.titleText
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]

        if let c = tv.textContainer {
            c.replaceLayoutManager(CardLayoutManager())
            c.widthTracksTextView = false
            c.lineFragmentPadding = 0
            c.containerSize = NSSize(width: DesignTokens.paperWidth, height: .greatestFiniteMagnitude)
        }
        tv.textContainerInset = NSSize(width: 70, height: 44)
        context.coordinator.textView = tv
        sv.documentView = tv
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        let size = DesignTokens.bodyFontSizes[fontIndex]
        let newFont = NSFont.systemFont(ofSize: size)
        LiveMarkdownStyler.bodyPointSize = size

        // Font changed: re-apply styling even if text hasn't changed, so
        // heading/code sizes scale immediately.
        let fontChanged = tv.font != newFont
        if fontChanged {
            tv.font = newFont
            if let s = tv.textStorage, isMarkdown { LiveMarkdownStyler.apply(to: s) }
        }

        // Text changed from model side (e.g. tab switch): push to editor.
        // Guard prevents overwriting live edits — after textDidChange writes
        // back, tv.string == text so this branch becomes a no-op.
        if tv.string != text {
            tv.string = text
            if let s = tv.textStorage, isMarkdown { LiveMarkdownStyler.apply(to: s) }
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditorView
        weak var textView: PaperTextView?

        init(_ p: EditorView) { parent = p }

        func textDidChange(_ n: Notification) {
            guard let tv = textView, let s = tv.textStorage else { return }
            // Write live edits back to the SwiftUI model so saves/tab switches
            // see the current text. Dispatch async to avoid modifying @Binding
            // during the current view update cycle.
            let current = tv.string
            DispatchQueue.main.async { [weak self] in
                self?.parent.text = current
            }
            LiveMarkdownStyler.apply(to: s)
        }
    }
}

final class PaperTextView: NSTextView {
    override func layout() {
        super.layout()
        let w = max(bounds.width, 1)
        let pw = min(DesignTokens.paperWidth, max(240, w - 140))
        textContainer?.widthTracksTextView = false
        textContainer?.containerSize = NSSize(width: pw, height: .greatestFiniteMagnitude)
        textContainer?.lineFragmentPadding = 0
        textContainerInset = NSSize(width: max(70, (w - pw) / 2), height: 44)
    }
    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); layout() }
}
