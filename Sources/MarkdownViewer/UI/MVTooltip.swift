import SwiftUI
import AppKit

/// Custom dark hover tooltip matching the spec (`ui/Markdown Viewer.dc.html` L264-267, JS L511-530).
///
/// Behaviour:
/// - Appears after the cursor dwells **480ms** over the target.
/// - Hides immediately on hover-out / view disappear.
/// - Quick fly-overs do not trigger (delay task is cancelled).
///
/// Bubble style (spec L266): background `rgba(28,28,30,0.92)` (#1C1C1E @ 0.92),
/// white text, radius 6, padding `4px 9px`, font-size 11.5, single line (no wrap),
/// shadow `0 6px 20px rgba(0,0,0,0.22)`, 0.12s fade-in.
///
/// Rendering model — **why anchorPreference (spec L264 `position: fixed; z-index: 90`):**
/// The bubble must paint on the *global top layer*, above everything. The content
/// area is an `NSViewRepresentable` (NSScrollView+NSTextView). AppKit host views
/// draw *over* SwiftUI's local `.overlay` layers, so a per-button local overlay
/// that extends down into the body gets covered by the NSTextView. The fix mirrors
/// how the toast works: it lives on a **root-level** `.overlay` (`.mvTooltipHost()`),
/// which composites above the NSViewRepresentable and is never occluded.
///
/// So `.mvTip(_:)` no longer paints the bubble itself — when the dwell elapses it
/// publishes `(text, Anchor<CGRect>)` up the tree via a `PreferenceKey`; the root
/// host (`.mvTooltipHost()`) reads it and draws the single global bubble.
///
/// Position: 8px below the target, horizontally centred (`rect.midX, rect.maxY + 8`),
/// **flipping above** the target when a below-anchored bubble would clip the bottom
/// of the content host (spec L518). The sidebar "全部命令 · ⌘K" row sits at the very
/// bottom, so its tooltip opens upward; the header buttons keep opening downward.

// MARK: - Preference plumbing

/// What `.mvTip(_:)` publishes when its dwell timer fires: the tooltip text and an
/// anchor on the target element. `nil` means "no tooltip should be shown right now".
struct MVTipPayload: Equatable {
    let text: String
    let anchor: Anchor<CGRect>

    static func == (lhs: MVTipPayload, rhs: MVTipPayload) -> Bool {
        // Anchor<CGRect> is not Equatable; identity of the active tip is the text.
        lhs.text == rhs.text
    }
}

/// Carries the currently-active tooltip (if any) from a `.mvTip` target up to the
/// root `.mvTooltipHost()`. Last writer wins: only one target is hovered at a time.
struct MVTipPreferenceKey: PreferenceKey {
    static var defaultValue: MVTipPayload? = nil

    static func reduce(value: inout MVTipPayload?, nextValue: () -> MVTipPayload?) {
        if let next = nextValue() { value = next }
    }
}

// MARK: - Per-target modifier

private struct MVTooltipModifier: ViewModifier {
    let text: String

    @State private var isHovered = false
    @State private var isShown = false
    @State private var pendingTask: DispatchWorkItem?

    private static let dwell: TimeInterval = 0.480

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering {
                    scheduleShow()
                } else {
                    cancelAndHide()
                }
            }
            .onDisappear { cancelAndHide() }
            // Report (text, anchor) only while shown; otherwise report nil so the
            // root host clears the bubble.
            .anchorPreference(key: MVTipPreferenceKey.self, value: .bounds) { anchor in
                isShown ? MVTipPayload(text: text, anchor: anchor) : nil
            }
    }

    private func scheduleShow() {
        isHovered = true
        pendingTask?.cancel()
        let task = DispatchWorkItem {
            guard isHovered else { return }
            isShown = true
        }
        pendingTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwell, execute: task)
    }

    private func cancelAndHide() {
        isHovered = false
        pendingTask?.cancel()
        pendingTask = nil
        if isShown { isShown = false }
    }
}

// MARK: - Root host (single global bubble)

private struct MVTooltipHostModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 8px gap below the target (spec).
    private static let gap: CGFloat = 8

    /// Measured bubble height, so `.position` (which centres a view) can be turned
    /// into a top-edge anchor (`y = target.maxY + gap + height/2`). Measured once;
    /// single-line 11.5pt text is a stable size.
    @State private var bubbleHeight: CGFloat = 23
    @State private var mouseMonitor: Any?
    @State private var suppressedByMouseDown = false
    @State private var activeText: String?

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(MVTipPreferenceKey.self) { payload in
                GeometryReader { proxy in
                    if let payload, !suppressedByMouseDown {
                    let rect = proxy[payload.anchor]
                    // `.position` places the bubble's CENTRE. Default: TOP edge 8px
                    // below the target (centre y = rect.maxY + gap + height/2).
                    // Flip ABOVE when a below-anchored bubble would clip the container
                    // bottom — e.g. the sidebar "全部命令 · ⌘K" row sits at the very
                    // bottom, so its tooltip must open upward (spec L518, QA P2).
                    let centreYBelow = rect.maxY + Self.gap + bubbleHeight / 2
                    let centreYAbove = rect.minY - Self.gap - bubbleHeight / 2
                    let overflowsBottom = rect.maxY + Self.gap + bubbleHeight > proxy.size.height
                    bubble(payload.text)
                        .fixedSize()
                        .position(
                            x: rect.midX,
                            y: overflowsBottom ? centreYAbove : centreYBelow
                        )
                        .allowsHitTesting(false)
                        .transition(MotionPolicy.transition(
                            .opacity,
                            reduceMotion: reduceMotion
                        ))
                    }
                }
                // Drive the 0.12s fade-in/out (spec) when the active tip appears or
                // clears. Keyed on the payload so `.transition(.opacity)` animates.
                .animation(
                    MotionPolicy.animation(.easeOut(duration: 0.12), reduceMotion: reduceMotion),
                    value: payload
                )
                .allowsHitTesting(false)
            }
            .onPreferenceChange(MVTipPreferenceKey.self) { payload in
                let nextText = payload?.text
                if nextText != activeText {
                    activeText = nextText
                    suppressedByMouseDown = false
                }
            }
            .onAppear { installMouseMonitor() }
            .onDisappear { removeMouseMonitor() }
    }

    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            if activeText != nil { suppressedByMouseDown = true }
            return event
        }
    }

    private func removeMouseMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    private func bubble(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .lineLimit(1)
            .foregroundColor(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(hex: 0x1C1C1E, opacity: 0.92))
            )
            .shadow(color: .black.opacity(0.22), radius: 10, y: 6)
            .fixedSize()
            .background(
                GeometryReader { g in
                    Color.clear.onAppear { bubbleHeight = g.size.height }
                }
            )
    }
}

// MARK: - Public API

extension View {
    /// Attaches a custom dark hover tooltip that fades in after a 480ms dwell.
    /// Spec-aligned replacement for the native `.help(_:)`. Renders via the root
    /// `.mvTooltipHost()` so the bubble paints above the NSTextView content area.
    func mvTip(_ text: String) -> some View {
        modifier(MVTooltipModifier(text: text))
    }

    /// Install **once** on the root view. Renders the single global tooltip bubble
    /// (driven by `MVTipPreferenceKey`) above all content, including the
    /// NSViewRepresentable editor.
    func mvTooltipHost() -> some View {
        modifier(MVTooltipHostModifier())
    }
}
