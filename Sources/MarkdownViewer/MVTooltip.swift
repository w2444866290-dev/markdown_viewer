import SwiftUI

/// Custom dark hover tooltip matching the spec (`ui/Markdown Viewer.dc.html` L264-267, JS L511-530).
///
/// Behaviour:
/// - Appears after the cursor dwells **480ms** over the target.
/// - Hides immediately on hover-out / view disappear.
/// - Quick fly-overs do not trigger (delay task is cancelled).
///
/// Bubble style (spec L266): background `rgba(28,28,30,0.92)` (#1C1C1E @ 0.92),
/// white text, radius 6, padding `4px 9px`, font-size 11.5, line-height 1.3,
/// single line (no wrap), shadow `0 6px 20px rgba(0,0,0,0.22)`, 0.12s fade-in.
///
/// Position: 8px below the target, horizontally centred. The header buttons that
/// use this never sit near the window bottom, so we always anchor **below**
/// (see "待确认" note in the deliverable).
private struct MVTooltipModifier: ViewModifier {
    let text: String

    @State private var isHovered = false
    @State private var isShown = false
    @State private var pendingTask: DispatchWorkItem?

    private static let dwell: TimeInterval = 0.480
    private static let gap: CGFloat = 8

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
            .overlay(alignment: .bottom) {
                if isShown {
                    bubble
                        // Push the bubble below the target with an 8px gap.
                        .alignmentGuide(.bottom) { _ in 0 }
                        .fixedSize()
                        .offset(y: bubbleHeightHint + Self.gap)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
    }

    private var bubble: some View {
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
    }

    /// Approximate bubble height so the `.offset` clears the target edge.
    /// (font 11.5 * line-height 1.3 ≈ 15 + vertical padding 8 ≈ 23.)
    private var bubbleHeightHint: CGFloat { 23 }

    private func scheduleShow() {
        isHovered = true
        pendingTask?.cancel()
        let task = DispatchWorkItem {
            guard isHovered else { return }
            withAnimation(.easeOut(duration: 0.12)) { isShown = true }
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

extension View {
    /// Attaches a custom dark hover tooltip that fades in after a 480ms dwell.
    /// Spec-aligned replacement for the native `.help(_:)`.
    func mvTip(_ text: String) -> some View {
        modifier(MVTooltipModifier(text: text))
    }
}
