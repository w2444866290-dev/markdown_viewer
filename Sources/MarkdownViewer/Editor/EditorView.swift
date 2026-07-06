import SwiftUI
import AppKit

struct EditorView: NSViewRepresentable {
    /// The active tab's text AT MOUNT — a plain load value, NOT a two-way binding.
    /// The live text lives in the NSTextView after mount; per-tab loads happen via
    /// the `.id(activeTabID)` recreation in ContentView (a fresh makeNSView loads
    /// the new tab's snapshot). Reconcile pulls the live text back into the snapshot
    /// at discrete points — see DocumentManager.reconcileActiveText.
    let text: String
    /// The active tab's saved scroll offset AT MOUNT (document-space y of the
    /// viewport top). Applied ONCE after the first layout pass in makeNSView — same
    /// one-shot load semantics as `text`; the live position lives in the scroll view
    /// after mount and is reconciled back at discrete points (Phase-2 per-tab scroll).
    let scrollY: CGFloat
    /// Unobserved reference (class → no re-render subscription) used to wire the
    /// reconcile channel on mount and to mark the tab dirty on the first edit.
    let docManager: DocumentManager
    @Binding var fontIndex: Int
    var isMarkdown: Bool = true
    var findState: FindState?
    @ObservedObject var bridge: EditorBridge
    /// Isolated scroll-progress sink. NOT observed by ContentView (held there via
    /// @State), so writing it on every scroll frame does not re-render the tree.
    var scrollModel: ScrollProgressModel
    /// Isolated active-heading sink, same rationale as `scrollModel`: written on
    /// every perceptible scroll frame, observed only by OutlineRailView.
    var activeHeadingModel: ActiveHeadingModel
    /// Isolated hovered-link-URL sink, same rationale as `scrollModel`: written on
    /// every mouse move over a link, observed only by the bottom-left preview leaf.
    var hoverURL: HoverURLModel
    /// Isolated document char/line-count sink, same rationale as `scrollModel`:
    /// written on load + every (debounced) edit, observed only by EditorStatusBar.
    var docMetrics: DocMetricsModel
    /// DIAG (temporary): isolated restyle-path readout sink. Written on every
    /// keystroke by the Coordinator, observed only by the top-center `DiagReadout`
    /// leaf - never by ContentView. Rip out with the other `// DIAG (temporary)`.
    var diag: DiagModel

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = ResponsiveScrollView()
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.scrollerStyle = .overlay
        sv.drawsBackground = true
        sv.backgroundColor = DesignTokens.paper
        // Bottom padding — spec L180: 33vh. ResponsiveScrollView keeps
        // contentInsets.bottom = 0.33 × visible height in sync on every layout;
        // editorBottomPadding is only the pre-measurement fallback.
        sv.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: DesignTokens.editorBottomPadding, right: 0)

        let tv = PaperTextView(frame: .zero)
        tv.delegate = context.coordinator
        // Become the textStorage delegate too, so we get the exact POST-edit
        // character range of each change (the reliable scope source for the
        // incremental re-style — see Coordinator.textStorage(_:didProcessEditing:…)).
        tv.textStorage?.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.font = NSFont.systemFont(ofSize: DesignTokens.bodyFontSizes[fontIndex])
        // Seed the Coordinator's tracked body size with the SAME initial size, so the
        // first updateNSView (which requests this same size) sees no change and skips
        // a redundant whole-document restyle at startup.
        context.coordinator.lastStyledBodySize = DesignTokens.bodyFontSizes[fontIndex]
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

        // --- Per-tab load (two-tier text) --------------------------------------
        // `.id(activeTabID)` in ContentView recreates this view on every tab switch,
        // so makeNSView is the single load point: seed tv.string with the mount-time
        // snapshot and run the initial whole-document style. updateNSView no longer
        // touches tv.string, so it can never revert live edits during typing.
        let bodySize = DesignTokens.bodyFontSizes[fontIndex]
        LiveMarkdownStyler.bodyPointSize = bodySize
        tv.string = text
        if let s = tv.textStorage {
            if isMarkdown { LiveMarkdownStyler.apply(to: s) }
            else { applyPlainSource(to: s, font: tv.font ?? NSFont.systemFont(ofSize: bodySize)) }
        }
        // The `tv.string = text` above fired one character edit; discard it so it
        // can't leak a stale whole-doc scope into the first keystroke's incremental.
        context.coordinator.clearPendingEditedRange()
        context.coordinator.refreshTextCaches()

        // Reconcile channel: expose this tab's LIVE NSTextView text to
        // DocumentManager, which pulls it into tabs[].text at discrete points. Weak
        // coordinator ref so the closure held by docManager can't retain-cycle it.
        docManager.pullActiveText = { [weak c = context.coordinator] in c?.textView?.string ?? "" }

        // Parallel scroll channel: expose this tab's LIVE viewport-top offset so the
        // session snapshot can read the current scroll without a per-frame write-back.
        docManager.pullActiveScrollY = { [weak c = context.coordinator] in
            c?.scrollView?.contentView.bounds.origin.y ?? 0
        }

        // Per-tab scroll restore (Phase-2): re-apply the saved offset ONCE, on the
        // NEXT layout pass so the document has been sized and ResponsiveScrollView's
        // initial 33vh inset pin has already run (applying now would fight it).
        // Clamp to the valid range against the fully-laid-out document height.
        let restoreY = scrollY
        if restoreY > 0 {
            DispatchQueue.main.async { [weak c = context.coordinator] in
                guard let c, let rsv = c.scrollView, let rtv = c.textView,
                      let lm = rtv.layoutManager, let tc = rtv.textContainer else { return }
                lm.ensureLayout(for: tc)          // force full glyph layout → real height
                rsv.layoutSubtreeIfNeeded()
                let docH = rtv.frame.height + rsv.contentInsets.top + rsv.contentInsets.bottom
                let maxY = max(0, docH - rsv.contentView.bounds.height)
                let y = min(max(0, restoreY), maxY)
                rsv.contentView.scroll(to: CGPoint(x: rsv.contentView.bounds.origin.x, y: y))
                rsv.reflectScrolledClipView(rsv.contentView)
            }
        }

        // Document loaded → rebuild outline + refresh cached metrics (this moved out
        // of updateNSView's old text branch). Async to avoid mutating @Published
        // state during a view update. Outline is Markdown-only (#22).
        let loadedText = text
        let loadedIsMarkdown = isMarkdown
        DispatchQueue.main.async {
            let bridge = context.coordinator.parent.bridge
            if loadedIsMarkdown {
                context.coordinator.outlineController.rebuild()
                bridge.headings = context.coordinator.outlineController.headings
            } else {
                bridge.headings = []
                MVLog.info("non-Markdown document opened — outline skipped (\(loadedText.count) chars)", category: "editor")
            }
            context.coordinator.parent.activeHeadingModel.index = 0
            let metrics = context.coordinator.parent.docMetrics
            metrics.charCount = loadedText.count
            metrics.lineCount = loadedText.isEmpty ? 0 : loadedText.components(separatedBy: "\n").count
        }
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        let size = DesignTokens.bodyFontSizes[fontIndex]
        let newFont = NSFont.systemFont(ofSize: size)
        LiveMarkdownStyler.bodyPointSize = size

        // Gate the whole-document restyle on the body size WE LAST STYLED WITH,
        // tracked on the Coordinator — NOT on `tv.font?.pointSize`, which reflects
        // the FIRST character's font. For any doc starting with a heading (`# Title`)
        // that first-char size is the heading size, never the body `size`, so the
        // old `tv.font` guard was true on every re-render → whole-doc font reset +
        // restyle on every ContentView re-render (e.g. each find-box keystroke) →
        // a one-frame styling flash. Comparing the tracked body size fires ONLY when
        // the user actually changed the body size (⌘+/−/0 → fontIndex → size).
        let fontChanged = context.coordinator.lastStyledBodySize != size
        if fontChanged {
            // DIAG (temporary): font-change whole-document restyle. Deferred to the
            // next runloop tick so writing DiagModel does not mutate observable
            // state during this SwiftUI view update (matches the async bridge writes
            // in the text branch below).
            DispatchQueue.main.async { context.coordinator.diagRecord("FONT") }
            tv.font = newFont
            if let s = tv.textStorage {
                if isMarkdown { LiveMarkdownStyler.apply(to: s) }
                else { applyPlainSource(to: s, font: newFont) }
            }
            // Whole-document restyle: drop any captured edited range so the next
            // keystroke scopes cleanly (the font change does not edit characters,
            // but keep this symmetric with the doc-load path below).
            context.coordinator.clearPendingEditedRange()
            // Record the body size we just styled with, so subsequent re-renders
            // that request the SAME size are correctly treated as "no font change".
            context.coordinator.lastStyledBodySize = size
        }

        // NO text branch here anymore. Two-tier text: the live text lives in
        // tv.string, and `text` is only a STALE mount-time snapshot during typing.
        // Per-tab loads happen via `.id(activeTabID)` recreation → makeNSView, so
        // updateNSView must NEVER set tv.string (the old `if tv.string != text`
        // branch would wrongly revert the user's just-typed edits on any re-render).
    }

    /// Non-Markdown documents (#22, spec ~L391) are shown as PLAIN source — the
    /// live styler is never run. Reset the whole storage to one flat monospaced
    /// run so any attributes left over from a prior styling pass are cleared.
    func applyPlainSource(to storage: NSTextStorage, font: NSFont) {
        let size = font.pointSize
        let mono = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let full = NSRange(location: 0, length: storage.length)
        storage.setAttributes([
            .font: mono,
            .foregroundColor: DesignTokens.bodyText,
        ], range: full)
    }

}
