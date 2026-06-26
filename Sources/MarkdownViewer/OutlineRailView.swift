import SwiftUI
import AppKit

/// Outline rail — spec: right 0, top 46%, translateY(-50%), tick→text melt animation.
struct OutlineRailView: View {
    let headings: [OutlineController.Heading]
    let activeIndex: Int
    let onJump: (Int) -> Void

    @State private var hovered = false
    @State private var hoveredIndex: Int?
    @State private var showCoach = false
    @State private var pulse = false
    @AppStorage("railCoachShown") private var coachShown = false

    var body: some View {
        if headings.isEmpty {
            EmptyView()
        } else {
            outlineContent
                .onAppear { maybeShowCoach() }
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
                .offset(y: geo.size.height * 0.46 - geo.size.height / 2)
            }
            // Size the interactive rail to the narrow right strip (resting 84 /
            // hovered 250) and attach hit-testing + hover to THAT strip only.
            .frame(width: hovered ? 250 : 84, height: geo.size.height, alignment: .trailing)
            .contentShape(Rectangle())
            .onHover { h in
                // Pointing-hand cursor over the rail (clickable), instead of the
                // text view's I-beam underneath.
                if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
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
            // THEN pin that strip to the right edge. This positioning frame has no
            // contentShape, so it never intercepts scroll/hover over the editor.
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
                    .fill(isActive ? DesignTokens.swiftUI.accent : DesignTokens.swiftUI.tickRest)
                    .frame(width: tickW, height: 2)
                    .opacity(hovered ? 0 : 1)
                    .blur(radius: hovered ? 3 : 0)
                    .scaleEffect(x: hovered ? 2.6 : 1, y: 1, anchor: .trailing)
                    .animation(.easeOut(duration: 0.18).delay(delay), value: hovered)

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
