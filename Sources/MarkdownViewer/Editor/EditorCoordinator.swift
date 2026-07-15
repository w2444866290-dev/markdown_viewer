import SwiftUI
import AppKit

extension EditorView {
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

        /// Discard any captured edited range AND supersede any pending scheduled
        /// (coalesced) restyle. Called after a WHOLE-document event (doc load/switch,
        /// font change, find replace-current/replace-all) does a full restyle, so:
        ///   1. the char-edit that `tv.string = …` itself fires does not leak a stale
        ///      (whole-doc) scope into the next keystroke's incremental, AND
        ///   2. a still-queued per-frame restyle can't run a now-redundant scoped pass
        ///      over a possibly-stale range against storage the full apply just covered.
        func clearPendingEditedRange() {
            pendingEditedRange = nil
            restyleWork?.cancel()
            restyleWork = nil
        }

        /// The body point size the document was LAST styled with. Seeded in
        /// makeNSView with the initial size and updated inside updateNSView's
        /// font-change branch. updateNSView gates its whole-document restyle on
        /// `lastStyledBodySize != size` instead of reading `tv.font?.pointSize`
        /// (which reflects the first character's font — a heading, not the body —
        /// so it never equalled the body size and made the guard fire on every
        /// re-render). `-1` means "never styled" → first pass restyles once.
        var lastStyledBodySize: CGFloat = -1

        // MARK: - Debug diagnostics
        /// Per-restyle-path cumulative tallies + last-event, for the typing-flash
        /// diagnostic. Every re-style path funnels through `diagRecord(_:)`, which
        /// bumps the matching counter, logs the path, and pushes a formatted line
        /// into the isolated `DiagModel` rendered by the optional Debug HUD.
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
            // Also surface the raw values behind the font-change
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
        private var scrollActivityTracker = ScrollActivityTracker()
        var suppressScrollActivity = false

        func recordScrollBaseline(_ y: CGFloat) {
            _ = scrollActivityTracker.observe(y, suppressed: true)
        }

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
                self?.search(q, state: fs)
            }
            fs.onNavigate = { [weak self] d in
                self?.findController.navigate(d)
                self?.synchronizeFindState(fs)
                // Show the live scroll math on the Debug HUD as you
                // step through matches, and make it the click-to-copy payload.
                if AppEnv.debug {
                    let s = self?.findController.lastScrollDiagnostic ?? ""
                    self?.parent.diag.findText = s
                    self?.parent.diag.findDetail = s
                }
                self?.publishPlainSourceDiagnostic()
            }
            fs.onReplaceCurrent = { [weak self] in
                guard let self else { return }
                self.findController.replaceCurrent(
                    with: fs.replaceText,
                    restyle: {
                        self.restyleAfterFindReplacement()
                        // The replace mutated storage → didChangeText already scheduled a
                        // per-frame incremental. This full apply supersedes it: cancel the
                        // now-redundant pass and drop its stale unioned range.
                        self.clearPendingEditedRange()
                    })
                self.synchronizeFindState(fs)
                self.publishPlainSourceDiagnostic()
            }
            fs.onReplaceAll = { [weak self] in
                guard let self else { return }
                self.findController.replaceAll(
                    with: fs.replaceText,
                    restyle: {
                        self.restyleAfterFindReplacement()
                        // Full apply supersedes the per-frame incremental that the
                        // replace's didChangeText just scheduled — cancel it + its range.
                        self.clearPendingEditedRange()
                    }
                )
                self.synchronizeFindState(fs)
                self.publishPlainSourceDiagnostic()
            }
        }

        /// Recompute a query that was already open when this per-tab editor mounted.
        /// A tab switch creates a new Coordinator and FindController, so wiring the
        /// callbacks alone is insufficient: without this explicit first search the
        /// shared FindState would continue showing the previous tab's result count.
        func searchCurrentFindQueryIfNeeded() {
            guard let fs = parent.findState, !fs.query.isEmpty else { return }
            search(fs.query, state: fs)
        }

        private func search(_ query: String, state: FindState) {
            findController.search(FindController.Options(
                query: query,
                caseSensitive: state.caseSensitive,
                wholeWord: state.wholeWord,
                useRegex: state.useRegex
            ))
            synchronizeFindState(state)
            // Surface the find summary on the Debug HUD's second line;
            // stash the full per-match dump (+ scroll math) for click-to-copy.
            if AppEnv.debug {
                parent.diag.findText = findController.lastDebugDiagnostic
                parent.diag.findDetail = findController.lastDebugDetail
                    + "\n" + findController.lastScrollDiagnostic
            }
            publishPlainSourceDiagnostic()
        }

        func publishPlainSourceDiagnostic() {
            guard AppEnv.debug, !parent.isMarkdown else { return }
            DispatchQueue.main.async { [weak self] in
                self?.publishPlainSourceDiagnosticOnMainActor()
            }
        }

        @MainActor
        private func publishPlainSourceDiagnosticOnMainActor() {
            guard !parent.isMarkdown,
                  let active = parent.docManager.activeTab,
                  active.id == parent.diagnosticDocumentID else { return }
            DebugDiagnosticWriter.shared.update(.plainSource(
                document: parent.diagnosticDocumentName.isEmpty
                    ? active.name
                    : parent.diagnosticDocumentName,
                selection: textView?.selectedRange() ?? active.selectionRange,
                dirty: active.isDirty,
                find: .current(parent.findState),
                scrollY: Double(scrollView?.contentView.bounds.origin.y ?? active.scrollY),
                sessionPath: SessionStore.fileURL.path
            ))
        }

        private func synchronizeFindState(_ state: FindState) {
            state.isError = findController.lastPatternInvalid
            state.matchCount = findController.matches.count
            state.currentIndex = findController.matches.isEmpty
                ? 0
                : min(findController.currentIndex, findController.matches.count - 1)
        }

        /// Restore attributes after a find replacement without changing the document's
        /// rendering mode. Plain-source files must remain one flat monospaced run and
        /// must never acquire hidden Markdown-marker attributes.
        private func restyleAfterFindReplacement() {
            guard let textView, let storage = textView.textStorage else { return }
            if parent.isMarkdown {
                LiveMarkdownStyler.apply(to: storage)
            } else {
                let fallback = NSFont.systemFont(
                    ofSize: DesignTokens.bodyFontSizes[parent.fontIndex]
                )
                parent.applyPlainSource(to: storage, font: textView.font ?? fallback)
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
            findController.invalidateForTextMutation()
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

        // MARK: - Coalesced live re-style (~1 per frame)

        /// The in-flight coalesced-restyle timer, or `nil` when none is scheduled.
        /// Doubles as the "already scheduled" guard (see `scheduleRestyle`) and the
        /// cancellation handle used by every full-apply supersede point
        /// (`clearPendingEditedRange`, the find replace closures, teardown).
        private var restyleWork: DispatchWorkItem?

        /// Schedule ONE live re-style ~1 frame (16 ms) out, coalescing every edit that
        /// lands before it fires into a single pass over the unioned
        /// `pendingEditedRange`. This replaces the old per-keystroke SYNCHRONOUS
        /// restyle (the fast-typing lag): a burst of N keystrokes within one frame now
        /// costs ONE `applyIncremental`, not N.
        ///
        /// NON-rescheduling on purpose: if a restyle is already queued we simply let
        /// the edited range keep growing (unioned by `textStorage(_:didProcessEditing:)`)
        /// and let the in-flight timer consume it. We do NOT cancel-and-reschedule per
        /// keystroke — that would push the deadline forward on every key during
        /// sustained fast typing and leave the text unstyled until the user paused.
        /// Fixed cadence from the FIRST pending keystroke instead, so the just-typed
        /// text is always styled within ~1 frame (imperceptible).
        private func scheduleRestyle() {
            guard restyleWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.performScheduledRestyle() }
            restyleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0, execute: work)
        }

        /// Consume the unioned pending range and restyle ONCE, then clear the range
        /// and the scheduled flag. Runs on the main queue (the asyncAfter target),
        /// never during a SwiftUI view update, so the DIAG @Published write is safe.
        /// Guards weak self / textView so a timer that outlives a torn-down tab (tab
        /// switch recreates the view → deallocs this coordinator) is a harmless no-op.
        private func performScheduledRestyle() {
            restyleWork = nil
            guard let tv = textView, let s = tv.textStorage else { return }
            // #22: non-Markdown source files are never live-styled — keep them flat.
            guard parent.isMarkdown else {
                parent.applyPlainSource(to: s, font: tv.font ?? NSFont.systemFont(ofSize: DesignTokens.bodyFontSizes[parent.fontIndex]))
                diagRecord("PLAIN")  // Debug diagnostic: non-Markdown flat source
                return
            }
            // INCREMENTAL re-style: scope the work to the block(s) the batched edits
            // touched (unioned via NSTextStorageDelegate), so typing in one paragraph
            // no longer resets/relays the WHOLE document (the white-flash + jank). The
            // styler falls back to a full `apply` whenever the edit could change block
            // boundaries downstream (open/close a fence, add/remove a blank line, change
            // a table/list shape) — correctness over speed. `applyIncremental` clamps
            // the (possibly now-stale) unioned range to the live storage bounds, so a
            // batched range is always safe. If we somehow have no captured range, do a
            // full restyle (also correctness-first).
            let edited = pendingEditedRange
            pendingEditedRange = nil
            if let edited {
                // A true diagnostic means a block-scoped incremental ran.
                // False means the styler fell back to a full-document apply.
                let didIncremental = LiveMarkdownStyler.applyIncremental(to: s, editedCharRange: edited)
                diagRecord(didIncremental ? "INC" : "FULL")
            } else {
                LiveMarkdownStyler.apply(to: s)
                diagRecord("FULL(norange)")  // Debug diagnostic: no range means full restyle
            }
        }

        deinit {
            // No scheduled closure should fire against a dead coordinator/view. The
            // work already captures [weak self] (a fired-after-dealloc timer is a
            // no-op), but cancel eagerly so a pending 16 ms timer isn't held at all.
            restyleWork?.cancel()
            debounceWork?.cancel()
        }

        func textDidChange(_ n: Notification) {
            // Plain-source find is instant, so every source mutation immediately
            // rebuilds ranges and publishes a count/index from the same snapshot.
            // The storage delegate already invalidated the prior snapshot before
            // this callback, including for undo, paste, and programmatic replacement.
            if !parent.isMarkdown,
               let findState = parent.findState,
               !findState.query.isEmpty {
                search(findState.query, state: findState)
            }
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
                self.publishPlainSourceDiagnostic()

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
                        self.parent.activeHeadingModel.publish(
                            self.outlineController.activeIndex(for: scrollY),
                            for: self.parent.diagnosticDocumentID
                        )
                    } else {
                        self.parent.bridge.headings = []
                        self.parent.activeHeadingModel.publish(
                            0,
                            for: self.parent.diagnosticDocumentID
                        )
                    }
                    // Status bar needs char/line counts for ALL files.
                    self.parent.docMetrics.publish(
                        charCount: DocMetricsModel.nonWhitespaceCharacterCount(in: text),
                        lineCount: DocMetricsModel.sourceLineCount(in: text),
                        for: self.parent.diagnosticDocumentID
                    )
                }
                self.debounceWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            }
            // COALESCED re-style (fast-typing lag fix): instead of restyling
            // synchronously on THIS keystroke, schedule a single restyle ~1 frame out
            // and keep unioning the edited range (via NSTextStorageDelegate) until it
            // fires. A burst of N keystrokes within one frame collapses to ONE
            // `applyIncremental` over the unioned range. Both Markdown (incremental /
            // full) and non-Markdown (flat) styling run inside the scheduled pass — see
            // performScheduledRestyle. DIAG counters now climb per-FRAME, not
            // per-keystroke (the intended verification signal).
            scheduleRestyle()
        }

        @objc func scrollDidChange() {
            let scrollY = max(0, scrollView?.contentView.bounds.origin.y ?? 0)
            let isScrollActivity = scrollActivityTracker.observe(
                scrollY,
                suppressed: suppressScrollActivity
            )
            let progress = computeProgress()
            // Throttle: skip publishes smaller than ~0.4%. Writes the isolated
            // scrollModel — only EditorStatusBar observes it, so the rest of the
            // ContentView tree never re-renders while scrolling.
            let progressChanged = abs(progress - lastPublishedProgress) >= 0.004
            parent.scrollModel.publish(
                progressChanged ? progress : parent.scrollModel.value,
                for: parent.diagnosticDocumentID,
                isScrollActivity: isScrollActivity
            )
            guard progressChanged else { return }
            lastPublishedProgress = progress

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
            guard parent.isMarkdown else {
                publishPlainSourceDiagnostic()
                return
            }
            let active = outlineController.activeIndex(for: scrollY)
            parent.activeHeadingModel.publish(
                active,
                for: parent.diagnosticDocumentID
            )
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let changedTextView = notification.object as? NSTextView,
                  changedTextView === textView else { return }
            publishPlainSourceDiagnostic()
        }

        // MARK: - Mouse bridging

        func handleMouseAt(_ tvPoint: NSPoint) {
            // Code-copy overlay is Markdown-only: a non-Markdown doc is shown as
            // plain source, so the floating "复制" button must never surface. We
            // can't rely on the empty `codeOverlay.blocks` cache alone — its
            // empty-cache fallback live-parses `tv.string` for ``` fences, which
            // would pop the button over a stray fence in a .txt file. Gate on
            // isMarkdown here (and hide any button a prior doc left behind).
            if parent.isMarkdown {
                codeOverlay.handleMouse(at: tvPoint)
            } else {
                codeOverlay.hide()
            }
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
            parent.hoverURL.publish(url, sourceBlockIndex: nil)
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
