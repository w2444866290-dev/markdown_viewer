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
            bridge.charCount = loadedText.count
            bridge.lineCount = loadedText.isEmpty ? 0 : loadedText.components(separatedBy: "\n").count
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
    private func applyPlainSource(to storage: NSTextStorage, font: NSFont) {
        let size = font.pointSize
        let mono = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let full = NSRange(location: 0, length: storage.length)
        storage.setAttributes([
            .font: mono,
            .foregroundColor: DesignTokens.bodyText,
        ], range: full)
    }

    // MARK: - Coordinator (thin delegate dispatcher)

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: EditorView
        weak var textView: PaperTextView?
        weak var scrollView: NSScrollView?
        var mouseTracker: MouseTracker?  // kept alive for NSTrackingArea

        /// The character range that the LAST text edit actually changed (post-edit),
        /// captured from `NSTextStorageDelegate`. `textDidChange` consumes it to
        /// scope the incremental re-style, then clears it. `nil` means "no captured
        /// range" → `textDidChange` falls back to a full restyle (correctness-first).
        private var pendingEditedRange: NSRange?

        /// Discard any captured edited range. Called after a WHOLE-document event
        /// (doc load/switch, font change) does a full restyle, so the char-edit that
        /// `tv.string = …` itself fires does not leak a stale (whole-doc) scope into
        /// the next keystroke's incremental pass.
        func clearPendingEditedRange() { pendingEditedRange = nil }

        /// The body point size the document was LAST styled with. Seeded in
        /// makeNSView with the initial size and updated inside updateNSView's
        /// font-change branch. updateNSView gates its whole-document restyle on
        /// `lastStyledBodySize != size` instead of reading `tv.font?.pointSize`
        /// (which reflects the first character's font — a heading, not the body —
        /// so it never equalled the body size and made the guard fire on every
        /// re-render). `-1` means "never styled" → first pass restyles once.
        var lastStyledBodySize: CGFloat = -1

        // DIAG (temporary) ---------------------------------------------------
        /// Per-restyle-path cumulative tallies + last-event, for the typing-flash
        /// diagnostic. Every re-style path funnels through `diagRecord(_:)`, which
        /// bumps the matching counter, logs the path, and pushes a formatted line
        /// into the isolated DiagModel (rendered top-center). Remove together with
        /// the rest of the `// DIAG (temporary)` markers.
        private var diagInc = 0, diagFull = 0, diagSetStr = 0, diagPlain = 0, diagFont = 0
        func diagRecord(_ event: String) {
            // USER mode: no HUD, so skip every counter/log/format cost entirely.
            guard AppEnv.debug else { return }
            switch event {
            case "INC": diagInc += 1
            case "SETSTR": diagSetStr += 1
            case "PLAIN": diagPlain += 1
            case "FONT": diagFont += 1
            default: diagFull += 1   // "FULL" and "FULL(norange)" both count as full
            }
            MVLog.debug("restyle path: \(event)", category: "diag")
            // DIAG (temporary): also surface the raw values behind the font-change
            // decision, so if FONT ever fires again we can read WHY at a glance:
            //   sz   = the body size currently requested (fontIndex → size)
            //   tvpt = tv.font?.pointSize (first-char font — the misleading old signal)
            //   lsz  = lastStyledBodySize (the tracked size the guard now compares)
            let sz = DesignTokens.bodyFontSizes[parent.fontIndex]
            let tvpt = textView?.font?.pointSize ?? -1
            parent.diag.text = "DIAG  last:\(event)  inc:\(diagInc) full:\(diagFull) setstr:\(diagSetStr) plain:\(diagPlain) font:\(diagFont)  sz:\(sz) tvpt:\(tvpt) lsz:\(lastStyledBodySize)"
        }

        let findController = FindController()
        let outlineController = OutlineController()
        let codeOverlay = CodeOverlayController()

        private var debounceWork: DispatchWorkItem?
        /// Last scroll progress published to the model — used to throttle
        /// per-frame publishes (only emit when the delta is perceptible).
        private var lastPublishedProgress: Double = -1

        /// Per-text-version caches for the mouse-hover hot path. Recomputed only
        /// when the document text changes (see `refreshTextCaches`), so each
        /// mouseMoved does a cheap lookup instead of an O(n) parse/regex scan.
        private var cachedFencedBlocks: [LiveMarkdownStyler.FencedCodeBlock] = []
        private var cachedLinkRanges: [(range: NSRange, url: String)] = []

        /// Recompute the hover caches from the current text-view contents. Call on
        /// any text change (debounce block + the updateNSView text branch).
        func refreshTextCaches() {
            // Non-Markdown docs are shown as plain source: the code-copy overlay
            // and link-hover ranges are meaningless, so skip the full-document
            // regex/scan passes and clear the caches (also drops any stale ranges
            // left over from a previously-open Markdown doc).
            guard parent.isMarkdown, let ns = textView?.string as NSString? else {
                cachedFencedBlocks = []
                cachedLinkRanges = []
                codeOverlay.blocks = []
                return
            }
            cachedFencedBlocks = LiveMarkdownStyler.fencedCodeBlocks(in: ns)
            cachedLinkRanges = LiveMarkdownStyler.linkRanges(in: ns)
            codeOverlay.blocks = cachedFencedBlocks
        }

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
                fs.isError = self?.findController.lastPatternInvalid ?? false
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

        /// Capture the post-edit character range of each real text change. This is
        /// the reliable source for the incremental re-style scope (NOT
        /// `tv.selectedRange`). We react ONLY to `.editedCharacters`; the styler's
        /// own attribute writes (inside `beginEditing`/`endEditing`) fire this with
        /// `.editedAttributes` and must be ignored to avoid feedback.
        func textStorage(_ textStorage: NSTextStorage,
                         didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange,
                         changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            // `editedRange` here is already the POST-edit range of the changed
            // characters (length reflects the inserted text). Union successive
            // character edits that arrive before `textDidChange` consumes them
            // (e.g. a replace = delete+insert) so the scope covers all of them.
            if let existing = pendingEditedRange {
                pendingEditedRange = NSUnionRange(existing, editedRange)
            } else {
                pendingEditedRange = editedRange
            }
        }

        func textDidChange(_ n: Notification) {
            guard let tv = textView, let s = tv.textStorage else { return }
            // The live text now lives ONLY in tv.string — NO per-keystroke write-back
            // through docManager (that re-rendered the whole ContentView every
            // keystroke, 性能-1). tabs[].text is reconciled at discrete points instead.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                // Dirty as a DISCRETE transition: flip on the FIRST edit after a clean
                // state only. markActiveDirty self-guards, so later keystrokes never
                // re-publish — one publish lights the dot, the save path clears it.
                let dm = self.parent.docManager
                if let idx = dm.activeIdx, !dm.tabs[idx].isDirty {
                    dm.markActiveDirty()
                }

                // Phase-2 session persistence: debounced (~1s) write of the latest
                // state. scheduleSessionSave only cancels/reschedules a work item and
                // mutates NO @Published, so it stays cheap and never re-renders.
                dm.scheduleSessionSave()

                // Debounced heavy work → write to the (isolated) bridge. Counts/outline
                // read the LIVE tv.string, never the stale tabs[].text snapshot.
                self.debounceWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, let tv = self.textView else { return }
                    let scrollY = self.scrollView?.contentView.bounds.origin.y ?? 0
                    let text = tv.string
                    // Text changed → refresh hover caches (cheap lookups stay valid).
                    self.refreshTextCaches()
                    // Outline is Markdown-only (#22) — see updateNSView for why a
                    // non-Markdown file's `#` comments must not become fake headings.
                    if self.parent.isMarkdown {
                        self.outlineController.rebuild()
                        self.parent.bridge.headings = self.outlineController.headings
                        self.parent.activeHeadingModel.index = self.outlineController.activeIndex(for: scrollY)
                    } else {
                        self.parent.bridge.headings = []
                        self.parent.activeHeadingModel.index = 0
                    }
                    // Status bar needs char/line counts for ALL files.
                    self.parent.bridge.charCount = text.count
                    self.parent.bridge.lineCount = text.isEmpty ? 0 : text.components(separatedBy: "\n").count
                }
                self.debounceWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            }
            // #22: non-Markdown source files are never live-styled — keep them flat.
            if parent.isMarkdown {
                // INCREMENTAL re-style: scope the work to the block(s) the edit
                // touched (captured via NSTextStorageDelegate), so typing in one
                // paragraph no longer resets/relays the WHOLE document (the
                // white-flash + jank). The styler itself falls back to a full
                // `apply` whenever the edit could change block boundaries
                // downstream (open/close a fence, add/remove a blank line, change a
                // table/list shape) — correctness over speed. If we somehow have no
                // captured range, do a full restyle (also correctness-first).
                let edited = pendingEditedRange
                pendingEditedRange = nil
                if let edited {
                    // DIAG (temporary): capture the styler's own result - true means
                    // an incremental (block-scoped) restyle ran, false means it fell
                    // back to a full-document apply.
                    let didIncremental = LiveMarkdownStyler.applyIncremental(to: s, editedCharRange: edited)
                    diagRecord(didIncremental ? "INC" : "FULL")
                } else {
                    LiveMarkdownStyler.apply(to: s)
                    diagRecord("FULL(norange)")  // DIAG (temporary): no captured range → full restyle
                }
            } else {
                parent.applyPlainSource(to: s, font: tv.font ?? NSFont.systemFont(ofSize: DesignTokens.bodyFontSizes[parent.fontIndex]))
                diagRecord("PLAIN")  // DIAG (temporary): non-Markdown flat source
            }
        }

        @objc func scrollDidChange() {
            let progress = computeProgress()
            // Throttle: skip publishes smaller than ~0.4%. Writes the isolated
            // scrollModel — only EditorStatusBar observes it, so the rest of the
            // ContentView tree never re-renders while scrolling.
            guard abs(progress - lastPublishedProgress) >= 0.004 else { return }
            lastPublishedProgress = progress
            parent.scrollModel.value = progress

            // Phase-2 session persistence: debounced save after the scroll settles, so
            // a restored tab reopens at the last-viewed position. Placed after the
            // perceptible-delta gate above; scheduleSessionSave mutates no @Published.
            // Hopped through the main queue (like textDidChange) to reach the
            // @MainActor DocumentManager from this nonisolated notification callback.
            DispatchQueue.main.async { [weak self] in self?.parent.docManager.scheduleSessionSave() }

            // Spec (syncScroll, ~line 655): a scroll updates BOTH progress AND the
            // active outline heading (the amber tick in the rail). Reuse the same
            // computation the text-change path uses. Gated by the progress throttle
            // above so the O(headings) layout loop runs at most once per perceptible
            // scroll delta, and only published when the index actually changes —
            // avoiding redundant @Published invalidations on the ContentView tree.
            //
            // Outline is Markdown-only (#22): a non-Markdown doc has no headings and no
            // rail, so skip the layout work entirely — scroll progress still publishes.
            guard parent.isMarkdown else { return }
            let scrollY = scrollView?.contentView.bounds.origin.y ?? 0
            let active = outlineController.activeIndex(for: scrollY)
            if parent.activeHeadingModel.index != active {
                parent.activeHeadingModel.index = active
            }
        }

        // MARK: - Mouse bridging

        func handleMouseAt(_ tvPoint: NSPoint) {
            codeOverlay.handleMouse(at: tvPoint)
            updateHoveredURL(at: tvPoint)
            // Pointing-hand over the outline rail or copy button; I-beam over text.
            if parent.bridge.cursorOverRail || codeOverlay.hitsButton(tvPoint) {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.iBeam.set()
            }
        }

        /// Browser-convention link URL preview: map `tvPoint` (text-view
        /// coordinates, same space codeOverlay uses) to a character index, then
        /// ask the styler for the `[label](url)` covering it. Writes the URL (or
        /// "") into the bridge, only on change to avoid churn. Any failure in the
        /// coordinate math falls through to clearing the preview — never crashes.
        private func updateHoveredURL(at tvPoint: NSPoint) {
            let url = linkURL(at: tvPoint) ?? ""
            if parent.hoverURL.url != url {
                parent.hoverURL.url = url
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
            // Cheap lookup over the per-version cache — no full-document regex on
            // mouseMoved. Same hit result as scanning linkRegex live (cache built
            // from that exact regex + image-skip logic in refreshTextCaches).
            for link in cachedLinkRanges where NSLocationInRange(charIndex, link.range) {
                return link.url
            }
            return nil
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
    /// Cursor is managed by ONE source — the MouseTracker (Coordinator.handleMouseAt):
    /// pointing-hand over the outline rail / copy button, I-beam over text. Suppress
    /// NSTextView's own cursor mechanisms (cursorUpdate + cursor rects) so they don't
    /// fight that single source — the earlier "flicker / 抽风" was two setters racing.
    override func cursorUpdate(with event: NSEvent) {}

    // Suppress the default I-beam cursor RECTS — they re-asserted right after
    // cursorUpdate (the "hand flickers then reverts to I-beam" bug). With no
    // rects, the cursor is driven solely by cursorUpdate + the MouseTracker.
    override func resetCursorRects() {}

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

// MARK: - ResponsiveScrollView

/// Scroll view whose bottom content inset tracks 33vh of its own visible height
/// (spec L180), without ever nudging the user's scroll position.
///
/// #27 regression history: the inset was first recomputed inside `tile()` (which
/// shifted the flipped clip view's `bounds.origin.y` re-entrantly), then moved to
/// a clip-view `frameDidChange` observer that captured `bounds.origin.y` just
/// before the inset write and restored it after.
///
/// #27 follow-up (THIS fix): that capture-and-restore was asymmetric on SHRINK.
/// The `frameDidChange` observer fires *after* AppKit has already resized the clip
/// view AND already constrained its `bounds.origin.y` for the new (smaller)
/// visible height while the OLD (larger) inset was still in effect — so the `y`
/// we captured was a value the system had already shifted. We then "restored" that
/// already-drifted `y`, and the clamp used a `maxY` derived from the NEW inset /
/// NEW visibleH (which on shrink is *more* permissive), so the drift was never
/// pulled back and accumulated a little downward each shrink cycle. Growing didn't
/// drift because the upward shift clamps cleanly to 0.
///
/// Fix: anchor on the user's scroll position in *document space*, snapshotted at
/// the moment a live resize BEGINS (before any clip-view shift), and re-pin to it
/// after every inset write during and at the end of the drag. The document point
/// at the top of the viewport is invariant to inset / visible-height changes, so
/// re-pinning it keeps both grow and shrink rock-stable. Programmatic (non-live)
/// size changes still take a fresh per-frame capture, which is correct there
/// because no live-resize shift sequence precedes them.
final class ResponsiveScrollView: NSScrollView {
    private var sizeObserver: NSObjectProtocol?
    private var lastVisibleHeight: CGFloat = 0
    /// Document-space y of the top of the viewport, captured at live-resize start.
    /// `nil` outside a live resize, in which case `updateBottomInset` falls back to
    /// a fresh capture of the current origin (fine for programmatic size changes).
    private var liveResizeAnchorY: CGFloat?

    override func tile() {
        super.tile()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startObservingSizeChanges()
        updateBottomInset()
    }

    private func startObservingSizeChanges() {
        guard sizeObserver == nil else { return }
        // The clip view posts frame-change notifications when the scroll view is
        // resized; that is precisely when the responsive 33vh inset must update.
        contentView.postsFrameChangedNotifications = true
        sizeObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: contentView,
            queue: .main
        ) { [weak self] _ in
            self?.updateBottomInset()
        }
    }

    // Snapshot the scroll anchor BEFORE the drag mutates the clip view, so every
    // intermediate `frameDidChange` during the drag re-pins to the same untouched
    // document position instead of to an already-shifted (stale) origin.
    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        liveResizeAnchorY = contentView.bounds.origin.y
    }

    // One authoritative re-pin once the drag settles, then drop the anchor so
    // later programmatic resizes take a fresh capture.
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        updateBottomInset(force: true)
        liveResizeAnchorY = nil
    }

    /// Recompute the 33vh bottom inset for the current visible height, pinning the
    /// scroll origin so neither the inset change nor the resize moves the user's
    /// position. During a live resize the anchor is the document position captured
    /// at `viewWillStartLiveResize` (invariant to the drag); otherwise it is a
    /// fresh capture of the current origin.
    private func updateBottomInset(force: Bool = false) {
        let visibleH = contentView.bounds.height
        guard visibleH > 0 else { return }
        // The per-frame path still throttles on visible-height delta; the
        // end-of-resize re-pin forces through so the final position is exact.
        if !force {
            guard abs(visibleH - lastVisibleHeight) >= 0.5 else { return }
        }
        lastVisibleHeight = visibleH

        let target = (0.33 * visibleH).rounded()
        // The anchor (document y at the top of the viewport) is what we hold fixed.
        // It is invariant to the inset, so capture it independent of the write.
        let anchorY = liveResizeAnchorY ?? contentView.bounds.origin.y

        if abs(contentInsets.bottom - target) >= 0.5 {
            contentInsets.bottom = target
        }

        let docHeight = (documentView?.frame.height ?? 0) + contentInsets.top + contentInsets.bottom
        let maxY = max(0, docHeight - visibleH)
        let restoredY = min(max(0, anchorY), maxY)
        contentView.scroll(to: CGPoint(x: contentView.bounds.origin.x, y: restoredY))
        reflectScrolledClipView(contentView)

        MVLog.debug(
            "ResponsiveScrollView inset → \(target) (visibleH \(Int(visibleH)), anchorY \(Int(anchorY)) → pinned \(Int(restoredY)))",
            category: "editor"
        )
    }

    deinit {
        if let sizeObserver { NotificationCenter.default.removeObserver(sizeObserver) }
    }
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
