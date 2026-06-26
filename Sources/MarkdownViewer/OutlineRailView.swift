import SwiftUI
import AppKit

/// Outline rail — spec: right 0, top 46%, translateY(-50%), tick→text melt animation.
struct OutlineRailView: View {
    let headings: [OutlineController.Heading]
    let activeIndex: Int
    let onJump: (Int) -> Void
    /// Active document identity — changes on tab open/switch to fire the tick
    /// pulse hint (spec pulseRail).
    var docToken: UUID? = nil
    /// Reports rail hover so the editor can show a pointing-hand cursor over it.
    var onHoverChange: ((Bool) -> Void)? = nil

    @State private var hovered = false
    @State private var hoveredIndex: Int?
    @State private var showCoach = false
    @State private var pulse = false
    @State private var pulseActive = false
    @AppStorage("railCoachShown") private var coachShown = false

    var body: some View {
        if headings.isEmpty {
            EmptyView()
        } else {
            outlineContent
                .onAppear { maybeShowCoach(); firePulse() }
                .onChange(of: docToken) { _ in firePulse() }
        }
    }

    // MARK: - Content

    private var outlineContent: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(Array(headings.enumerated()), id: \.element.id) { idx, h in
                        outlineRow(h, idx: idx)
                    }
                }
                .padding(.trailing, 18)
                .padding(.vertical, 30)
                // Hit/hover area = the ticks block ONLY (width strip; height = the
                // ticks, NOT full column height). Hovering empty top/bottom-right
                // space must not trigger the rail or the hand cursor.
                // CONSTANT hit width (= expanded width). The previous `hovered?250:84`
                // resized the hit area, which fed back at the edge and made onHover —
                // and the cursor — flicker. With a fixed frame, onHover is stable, so
                // the cursor is set immediately and reverts to I-beam the moment the
                // mouse leaves the rail. Only the visual (ticks↔labels) animates.
                .frame(width: 250, alignment: .trailing)
                .contentShape(Rectangle())
                .onHover { h in
                    onHoverChange?(h)   // immediate; stable because the frame no longer resizes
                    withAnimation(.easeOut(duration: 0.24)) { hovered = h }
                    if !h {
                        withAnimation(.easeOut(duration: 0.18)) { hoveredIndex = nil }
                    }
                }
                .overlay(alignment: .trailing) {
                    if showCoach {
                        coachBubble
                            .offset(x: -46, y: 0)
                    }
                }
                .offset(y: geo.size.height * 0.46 - geo.size.height / 2)
            }
            // Position the ticks block at the right edge, vertically centred (then
            // nudged to 46% by the offset). No contentShape here → never intercepts
            // scroll/hover/clicks over the editor.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
    }

    // MARK: - Row

    private func outlineRow(_ h: OutlineController.Heading, idx: Int) -> some View {
        let isActive = h.id == activeIndex
        let isHovered = hoveredIndex == idx
        let delay = hovered ? Double(idx) * 0.012 : 0
        let tickW: CGFloat = h.level == 1 ? 22 : 14

        return Button(action: { onJump(h.charIndex) }) {
            ZStack(alignment: .trailing) {
                // Tick bar — fades out when expanded
                RoundedRectangle(cornerRadius: 1)
                    .fill((isActive || (pulseActive && !hovered)) ? DesignTokens.swiftUI.accent : DesignTokens.swiftUI.tickRest)
                    .frame(width: tickW, height: 2)
                    .opacity(hovered ? 0 : 1)
                    .blur(radius: hovered ? 3 : 0)
                    // Hint pulse (spec railHint): stretch to peak + amber, staggered.
                    .scaleEffect(x: hovered ? 2.6 : (pulseActive ? (h.level == 1 ? 2.05 : 1.7) : 1), y: 1, anchor: .trailing)
                    .animation(.easeOut(duration: 0.18).delay(delay), value: hovered)
                    .animation(.easeInOut(duration: 0.22).delay(Double(idx) * 0.084), value: pulseActive)

                // Text label — fades in when expanded
                Text(h.title)
                    .font(.system(size: h.level == 1 ? 13 : 12,
                                  weight: isActive ? .semibold : .regular))
                    .foregroundColor(isHovered
                        ? DesignTokens.swiftUI.titleText
                        : (isActive ? DesignTokens.swiftUI.accent : DesignTokens.swiftUI.tertiaryText))
                    .lineLimit(1)
                    .opacity(hovered ? 1 : 0)
                    .blur(radius: hovered ? 0 : 5)
                    .scaleEffect(isHovered ? 1.14 : 1, anchor: .trailing)
                    .animation(.easeOut(duration: 0.12).delay(delay), value: hovered)
                    .animation(.easeOut(duration: 0.12), value: isHovered)
            }
            .frame(height: hovered ? 26 : 18)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredIndex = hovering ? idx : nil
            if hovering { showCoach = false }
        }
    }

    // MARK: - Coach bubble

    private var coachBubble: some View {
        HStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hex: 0x1C1C1E, opacity: 0.92))
                Text("本页目录 · 悬停展开")
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
            .fixedSize()
            .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
            Triangle()
                .fill(Color(hex: 0x1C1C1E, opacity: 0.92))
                .frame(width: 6, height: 10)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Tick pulse hint (spec railHint / pulseRail)

    /// One-shot amber wave across the ticks: each stretches to its peak + turns
    /// amber (staggered), then settles back. Fired on first appearance and on
    /// document open/switch. Skipped while the rail is hovered/expanded.
    private func firePulse() {
        guard !headings.isEmpty, !hovered else { return }
        pulseActive = true
        let settle = Double(headings.count) * 0.084 + 0.30
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
            if !hovered { pulseActive = false }
        }
    }

    // MARK: - Coach logic

    private func maybeShowCoach() {
        guard !coachShown else { return }
        coachShown = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            showCoach = true
            pulse = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.1) {
            pulse = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.2) {
            showCoach = false
        }
    }
}

// MARK: - Triangle shape

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: rect.width, y: rect.midY))
        p.addLine(to: CGPoint(x: 0, y: rect.height))
        p.closeSubpath()
        return p
    }
}
