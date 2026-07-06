import SwiftUI
import AppKit

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
