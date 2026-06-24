import SwiftUI
import AppKit

struct EditorView: NSViewRepresentable {
    @Binding var text: String
    @Binding var fontIndex: Int
    var isMarkdown: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator() }

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
        tv.textColor = NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.212, alpha: 1)
        tv.backgroundColor = .white
        tv.insertionPointColor = NSColor(calibratedRed: 0.114, green: 0.114, blue: 0.122, alpha: 1)
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
        tv.font = NSFont.systemFont(ofSize: size)
        LiveMarkdownStyler.bodyPointSize = size
        if tv.string != text {
            tv.string = text
            if let s = tv.textStorage, isMarkdown { LiveMarkdownStyler.apply(to: s) }
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: PaperTextView?
        func textDidChange(_ n: Notification) {
            if let tv = textView, let s = tv.textStorage { LiveMarkdownStyler.apply(to: s) }
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
