import SwiftUI
import AppKit

struct EditorView: NSViewRepresentable {
    @Binding var text: String
    @Binding var fontIndex: Int
    @Binding var scrollProgress: Double
    var isMarkdown: Bool = true
    var findState: FindState?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.scrollerStyle = .overlay
        sv.drawsBackground = true
        sv.backgroundColor = DesignTokens.paper

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

        // Observe scroll for progress + status fade
        sv.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollDidChange),
            name: NSView.boundsDidChangeNotification,
            object: sv.contentView
        )

        // Track mouse for link hover preview + code copy button
        let tracker = MouseTracker(coordinator: context.coordinator)
        sv.addTrackingArea(NSTrackingArea(
            rect: sv.bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
            owner: tracker,
            userInfo: nil
        ))

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

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditorView
        weak var textView: PaperTextView?
        weak var scrollView: NSScrollView?

        // Find state
        private var findMatches: [NSTextCheckingResult] = []
        private var findIndex = 0

        // Outline
        private var outlineEntries: [OutlineHeading] = []

        init(_ p: EditorView) {
            parent = p
            super.init()
            // Wire find/replace callbacks to this coordinator.
            p.findState?.onSearch = { [weak self] q in self?.performFind(query: q, caseSensitive: p.findState?.caseSensitive ?? false, wholeWord: p.findState?.wholeWord ?? false, useRegex: p.findState?.useRegex ?? false) }
            p.findState?.onNavigate = { [weak self] d in self?.navigateFind(d) }
            p.findState?.onReplaceCurrent = { [weak self] in self?.replaceCurrent() }
            p.findState?.onReplaceAll = { [weak self] in self?.replaceAll() }
        }

        // MARK: - Text editing

        func textDidChange(_ n: Notification) {
            guard let tv = textView, let s = tv.textStorage else { return }
            let current = tv.string
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.parent.text = current
                self.parent.scrollProgress = self.computeProgress()
                self.rebuildOutline()
            }
            LiveMarkdownStyler.apply(to: s)
        }

        // MARK: - Scroll syncing

        @objc func scrollDidChange() {
            parent.scrollProgress = computeProgress()
        }

        private func computeProgress() -> Double {
            guard let sv = scrollView, let tv = textView else { return 0 }
            let docH = tv.frame.height
            let viewH = sv.contentView.bounds.height
            let maxOff = max(1, docH - viewH)
            return max(0, min(1, sv.contentView.bounds.origin.y / maxOff))
        }

        // MARK: - Code copy button (mouse bridging)

        func handleMouseAt(_ tvPoint: NSPoint) {
            updateCodeCopyButton(at: tvPoint)
        }

        private var codeCopyButton: NSButton?
        private var copyButtonBodyRange: NSRange?

        private func updateCodeCopyButton(at point: NSPoint) {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let ns = storage.string as NSString
            for block in LiveMarkdownStyler.fencedCodeBlocks(in: ns) {
                let glyphRange = tv.layoutManager!.glyphRange(forCharacterRange: block.bodyRange, actualCharacterRange: nil)
                var rect = tv.layoutManager!.boundingRect(forGlyphRange: glyphRange, in: tv.textContainer!)
                rect.origin.y += tv.textContainerInset.height
                if rect.contains(point) {
                    showCodeCopyButton(for: block, in: tv)
                    return
                }
            }
            hideCodeCopyButton()
        }

        private func showCodeCopyButton(for block: LiveMarkdownStyler.FencedCodeBlock, in tv: NSTextView) {
            copyButtonBodyRange = block.bodyRange
            if codeCopyButton == nil {
                let btn = NSButton(title: "复制", target: self, action: #selector(copyCode))
                btn.isBordered = false
                btn.bezelStyle = .inline
                btn.font = NSFont.systemFont(ofSize: 11)
                btn.contentTintColor = DesignTokens.placeholderText
                btn.wantsLayer = true
                btn.layer?.cornerRadius = 5
                btn.isHidden = true
                btn.alphaValue = 0
                tv.addSubview(btn)
                codeCopyButton = btn
            }
            guard let btn = codeCopyButton else { return }
            let glyphRange = tv.layoutManager!.glyphRange(forCharacterRange: block.bodyRange, actualCharacterRange: nil)
            var rect = tv.layoutManager!.boundingRect(forGlyphRange: glyphRange, in: tv.textContainer!)
            rect.origin.y += tv.textContainerInset.height
            btn.frame = NSRect(x: rect.maxX - 50, y: rect.minY + 8, width: 44, height: 20)
            btn.isHidden = false
            btn.alphaValue = 1
        }

        private func hideCodeCopyButton() {
            copyButtonBodyRange = nil
            codeCopyButton?.alphaValue = 0
            codeCopyButton?.isHidden = true
        }

        @objc private func copyCode() {
            guard let range = copyButtonBodyRange,
                  let tv = textView else { return }
            let ns = tv.string as NSString
            var body = ns.substring(with: range)
            if body.hasSuffix("\n") { body.removeLast() }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body, forType: .string)
        }

        // MARK: - Find / Replace engine

        func performFind(query: String, caseSensitive: Bool, wholeWord: Bool, useRegex: Bool) {
            guard let tv = textView else { return }
            clearFindHighlights()
            findMatches = []
            findIndex = 0

            guard !query.isEmpty else {
                parent.findState?.isError = false
                parent.findState?.matchCount = 0
                return
            }

            var pattern = query
            if !useRegex {
                pattern = NSRegularExpression.escapedPattern(for: pattern)
                if wholeWord { pattern = "\\b\(pattern)\\b" }
            }
            var opts: NSRegularExpression.Options = []
            if !caseSensitive { opts.insert(.caseInsensitive) }

            guard let regex = try? NSRegularExpression(pattern: pattern, options: opts) else {
                parent.findState?.isError = true
                parent.findState?.matchCount = 0
                return
            }

            let text = tv.string
            let full = NSRange(location: 0, length: (text as NSString).length)
            findMatches = regex.matches(in: text, range: full).filter { $0.range.length > 0 }
            findIndex = 0
            parent.findState?.isError = false
            parent.findState?.matchCount = findMatches.count
            parent.findState?.currentIndex = 0
            applyFindHighlights()
            scrollToCurrentMatch()
        }

        func navigateFind(_ delta: Int) {
            guard !findMatches.isEmpty else { return }
            findIndex = (findIndex + delta + findMatches.count) % findMatches.count
            parent.findState?.currentIndex = findIndex
            applyFindHighlights()
            scrollToCurrentMatch()
        }

        func replaceCurrent() {
            guard findMatches.indices.contains(findIndex),
                  let tv = textView, let storage = tv.textStorage,
                  let replaceText = parent.findState?.replaceText else { return }
            let match = findMatches[findIndex]
            guard tv.shouldChangeText(in: match.range, replacementString: replaceText) else { return }
            storage.replaceCharacters(in: match.range, with: replaceText)
            tv.didChangeText()
            if let s = tv.textStorage { LiveMarkdownStyler.apply(to: s) }
            performFind(query: parent.findState?.query ?? "", caseSensitive: parent.findState?.caseSensitive ?? false, wholeWord: parent.findState?.wholeWord ?? false, useRegex: parent.findState?.useRegex ?? false)
        }

        func replaceAll() {
            guard !findMatches.isEmpty,
                  let tv = textView, let storage = tv.textStorage,
                  let replaceText = parent.findState?.replaceText else { return }
            let full = NSRange(location: 0, length: storage.length)
            guard tv.shouldChangeText(in: full, replacementString: nil) else { return }
            for match in findMatches.reversed() {
                storage.replaceCharacters(in: match.range, with: replaceText)
            }
            tv.didChangeText()
            if let s = tv.textStorage { LiveMarkdownStyler.apply(to: s) }
            parent.findState?.matchCount = 0
            parent.findState?.currentIndex = 0
            findMatches = []
        }

        private func clearFindHighlights() {
            guard let lm = textView?.layoutManager else { return }
            let full = NSRange(location: 0, length: (textView?.string ?? "").utf16.count)
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        }

        private func applyFindHighlights() {
            guard let lm = textView?.layoutManager else { return }
            clearFindHighlights()
            for (i, match) in findMatches.enumerated() {
                let color = i == findIndex ? DesignTokens.accentStrong : DesignTokens.accentSoft
                lm.addTemporaryAttributes([.backgroundColor: color], forCharacterRange: match.range)
            }
        }

        private func scrollToCurrentMatch() {
            guard findMatches.indices.contains(findIndex) else { return }
            textView?.scrollRangeToVisible(findMatches[findIndex].range)
        }

        // MARK: - Outline / headings

        struct OutlineHeading: Identifiable {
            let id: Int
            let title: String
            let level: Int
            let charIndex: Int
        }

        private func rebuildOutline() {
            guard let tv = textView else { return }
            let ns = tv.string as NSString
            var entries: [OutlineHeading] = []
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
                entries.append(OutlineHeading(id: entries.count, title: title, level: lvl, charIndex: range.location))
            }
            outlineEntries = entries
        }

        var headings: [OutlineHeading] { outlineEntries }

        func jumpToHeading(_ charIndex: Int) {
            guard let tv = textView, let sv = scrollView else { return }
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            let ns = tv.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyphRange = lm.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            rect.origin.y += tv.textContainerInset.height
            let target = max(0, min(rect.minY - 40, max(0, tv.frame.height - sv.contentView.bounds.height)))
            sv.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: target))
        }

        func activeHeadingIndex(for scrollY: CGFloat) -> Int {
            guard let tv = textView, !outlineEntries.isEmpty else { return 0 }
            let threshold = scrollY + 140
            var active = 0
            for (i, e) in outlineEntries.enumerated() {
                let ns = tv.string as NSString
                let lr = ns.lineRange(for: NSRange(location: e.charIndex, length: 0))
                let gr = tv.layoutManager!.glyphRange(forCharacterRange: lr, actualCharacterRange: nil)
                var r = tv.layoutManager!.boundingRect(forGlyphRange: gr, in: tv.textContainer!)
                r.origin.y += tv.textContainerInset.height
                if r.minY <= threshold { active = i } else { break }
            }
            return active
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

/// Thin NSResponder that forwards mouseMoved to the coordinator for
/// code-copy-button hover detection.
private final class MouseTracker: NSView {
    weak var coordinator: EditorView.Coordinator?
    convenience init(coordinator: EditorView.Coordinator) {
        self.init(frame: .zero)
        self.coordinator = coordinator
    }
    override func mouseMoved(with event: NSEvent) {
        guard let c = coordinator,
              let tv = c.textView,
              let sv = c.scrollView else { return }
        let point = sv.convert(event.locationInWindow, from: nil)
        let tvPoint = NSPoint(x: point.x, y: sv.documentVisibleRect.height - point.y + sv.contentView.bounds.origin.y)
        // Access private method via a bridging helper
        c.handleMouseAt(tvPoint)
    }
}
