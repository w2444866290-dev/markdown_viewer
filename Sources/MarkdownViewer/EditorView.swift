import SwiftUI
import AppKit

struct EditorView: NSViewRepresentable {
    @Binding var text: String
    @Binding var fontIndex: Int
    var isMarkdown: Bool = true
    var findState: FindState?
    @ObservedObject var bridge: EditorBridge

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.scrollerStyle = .overlay
        sv.drawsBackground = true
        sv.backgroundColor = DesignTokens.paper
        // Bottom padding — spec: 33vh ≈ 220pt
        sv.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: DesignTokens.editorBottomPadding, right: 0)

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
        tv.textContainerInset = NSSize(width: 70, height: DesignTokens.editorTopInset)

        // Scroll syncing
        sv.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollDidChange),
            name: NSView.boundsDidChangeNotification,
            object: sv.contentView
        )

        // Mouse tracker — stored on coordinator to keep alive
        let tracker = MouseTracker(coordinator: context.coordinator)
        context.coordinator.mouseTracker = tracker
        sv.addTrackingArea(NSTrackingArea(
            rect: sv.bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
            owner: tracker,
            userInfo: nil
        ))

        // Wire sub-controllers
        context.coordinator.findController.textView = tv
        context.coordinator.outlineController.textView = tv
        context.coordinator.codeOverlay.textView = tv
        context.coordinator.textView = tv
        context.coordinator.scrollView = sv
        sv.documentView = tv
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        let size = DesignTokens.bodyFontSizes[fontIndex]
        let newFont = NSFont.systemFont(ofSize: size)
        LiveMarkdownStyler.bodyPointSize = size

        let fontChanged = tv.font != newFont
        if fontChanged {
            tv.font = newFont
            if let s = tv.textStorage, isMarkdown { LiveMarkdownStyler.apply(to: s) }
        }

        if tv.string != text {
            tv.string = text
            if let s = tv.textStorage, isMarkdown { LiveMarkdownStyler.apply(to: s) }
        }
    }

    // MARK: - Coordinator (thin delegate dispatcher)

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditorView
        weak var textView: PaperTextView?
        weak var scrollView: NSScrollView?
        var mouseTracker: MouseTracker?  // kept alive for NSTrackingArea

        let findController = FindController()
        let outlineController = OutlineController()
        let codeOverlay = CodeOverlayController()

        private var debounceWork: DispatchWorkItem?

        init(_ p: EditorView) {
            parent = p
            super.init()
            p.bridge.onJumpToHeading = { [weak self] idx in
                self?.outlineController.jumpTo(idx)
            }
            wireFindState()
        }

        private func wireFindState() {
            guard let fs = parent.findState else { return }
            fs.onSearch = { [weak self] q in
                self?.findController.search(FindController.Options(
                    query: q,
                    caseSensitive: fs.caseSensitive,
                    wholeWord: fs.wholeWord,
                    useRegex: fs.useRegex
                ))
                fs.isError = false
                fs.matchCount = self?.findController.matches.count ?? 0
                fs.currentIndex = 0
            }
            fs.onNavigate = { [weak self] d in
                self?.findController.navigate(d)
                fs.currentIndex = self?.findController.currentIndex ?? 0
            }
            fs.onReplaceCurrent = { [weak self] in
                self?.findController.replaceCurrent(
                    with: fs.replaceText,
                    restyle: { if let s = self?.textView?.textStorage { LiveMarkdownStyler.apply(to: s) } },
                    redo: {
                        self?.findController.search(FindController.Options(
                            query: fs.query, caseSensitive: fs.caseSensitive,
                            wholeWord: fs.wholeWord, useRegex: fs.useRegex
                        ))
                        fs.matchCount = self?.findController.matches.count ?? 0
                    })
            }
            fs.onReplaceAll = { [weak self] in
                self?.findController.replaceAll(
                    with: fs.replaceText,
                    restyle: { if let s = self?.textView?.textStorage { LiveMarkdownStyler.apply(to: s) } }
                )
                fs.matchCount = 0
                fs.currentIndex = 0
            }
        }

        // MARK: - Delegate

        func textDidChange(_ n: Notification) {
            guard let tv = textView, let s = tv.textStorage else { return }
            let current = tv.string
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.parent.text = current

                // Debounced heavy work → write to bridge
                self.debounceWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    let progress = self.computeProgress()
                    let scrollY = self.scrollView?.contentView.bounds.origin.y ?? 0
                    self.outlineController.rebuild()
                    self.parent.bridge.scrollProgress = progress
                    self.parent.bridge.headings = self.outlineController.headings
                    self.parent.bridge.activeHeadingIndex = self.outlineController.activeIndex(for: scrollY)
                }
                self.debounceWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            }
            LiveMarkdownStyler.apply(to: s)
        }

        @objc func scrollDidChange() {
            parent.bridge.scrollProgress = computeProgress()
        }

        // MARK: - Mouse bridging

        func handleMouseAt(_ tvPoint: NSPoint) {
            codeOverlay.handleMouse(at: tvPoint)
            updateHoveredURL(at: tvPoint)
        }

        /// Browser-convention link URL preview: map `tvPoint` (text-view
        /// coordinates, same space codeOverlay uses) to a character index, then
        /// ask the styler for the `[label](url)` covering it. Writes the URL (or
        /// "") into the bridge, only on change to avoid churn. Any failure in the
        /// coordinate math falls through to clearing the preview — never crashes.
        private func updateHoveredURL(at tvPoint: NSPoint) {
            let url = linkURL(at: tvPoint) ?? ""
            if parent.bridge.hoveredURL != url {
                parent.bridge.hoveredURL = url
            }
        }

        private func linkURL(at tvPoint: NSPoint) -> String? {
            guard let tv = textView,
                  let lm = tv.layoutManager,
                  let tc = tv.textContainer else { return nil }
            let ns = tv.string as NSString
            guard ns.length > 0 else { return nil }

            // Reverse of codeOverlay's `rect.origin.y += textContainerInset.height`:
            // strip the inset to land in text-container coordinates.
            let containerPoint = NSPoint(
                x: tvPoint.x - tv.textContainerInset.width,
                y: tvPoint.y - tv.textContainerInset.height
            )
            // Reject points outside any glyph: glyphIndex(for:) clamps to the
            // nearest glyph, so verify the point is actually inside that glyph's
            // fragment rect before trusting the hit.
            var partial: CGFloat = 0
            let glyphIndex = lm.glyphIndex(for: containerPoint, in: tc, fractionOfDistanceThroughGlyph: &partial)
            guard lm.numberOfGlyphs > 0 else { return nil }
            let glyphRect = lm.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: tc)
            guard glyphRect.contains(containerPoint) else { return nil }

            let charIndex = lm.characterIndexForGlyph(at: glyphIndex)
            guard charIndex < ns.length else { return nil }
            return LiveMarkdownStyler.linkDestination(in: ns, coveringIndex: charIndex)
        }

        func computeProgress() -> Double {
            guard let sv = scrollView, let tv = textView else { return 0 }
            let docH = tv.frame.height
            let viewH = sv.contentView.bounds.height
            let maxOff = max(1, docH - viewH)
            return max(0, min(1, sv.contentView.bounds.origin.y / maxOff))
        }
    }
}

// MARK: - PaperTextView

final class PaperTextView: NSTextView {
    override func layout() {
        super.layout()
        let w = max(bounds.width, 1)
        let pw = min(DesignTokens.paperWidth, max(240, w - 140))
        textContainer?.widthTracksTextView = false
        textContainer?.containerSize = NSSize(width: pw, height: .greatestFiniteMagnitude)
        textContainer?.lineFragmentPadding = 0
        textContainerInset = NSSize(width: max(70, (w - pw) / 2), height: DesignTokens.editorTopInset)
    }
    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); layout() }
}

// MARK: - Mouse tracker

final class MouseTracker: NSView {
    weak var coordinator: EditorView.Coordinator?
    convenience init(coordinator: EditorView.Coordinator) {
        self.init(frame: .zero)
        self.coordinator = coordinator
    }
    override func mouseMoved(with event: NSEvent) {
        guard let c = coordinator, let sv = c.scrollView else { return }
        let point = sv.convert(event.locationInWindow, from: nil)
        let tvPoint = NSPoint(x: point.x, y: sv.documentVisibleRect.height - point.y + sv.contentView.bounds.origin.y)
        c.handleMouseAt(tvPoint)
    }
}
