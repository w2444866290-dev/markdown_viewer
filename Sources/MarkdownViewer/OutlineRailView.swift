import SwiftUI

struct OutlineRailView: View {
    let headings: [OutlineController.Heading]
    let activeIndex: Int
    let onJump: (Int) -> Void

    @State private var hovered = false
    @State private var hoveredIndex: Int?

    var body: some View {
        if headings.isEmpty {
            EmptyView()
        } else {
            outlineContent
        }
    }

    private var outlineContent: some View {
        HStack(spacing: 0) {
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                ForEach(headings) { h in
                    outlineRow(h)
                }
            }
            .padding(.trailing, 18)
            .padding(.vertical, 30)
        }
        .frame(width: hovered ? 250 : 84)
        .contentShape(Rectangle())
        .onHover { h in
            withAnimation(.easeOut(duration: 0.2)) { hovered = h }
            if !h { hoveredIndex = nil }
        }
    }

    private func outlineRow(_ h: OutlineController.Heading) -> some View {
        let isActive = h.id == activeIndex
        let isHovered = hoveredIndex == h.id

        return Button(action: { onJump(h.charIndex) }) {
            HStack(spacing: 0) {
                if !hovered {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(isActive ? DesignTokens.swiftUI.accent : DesignTokens.swiftUI.tickRest)
                        .frame(width: h.level == 1 ? 22 : 14, height: 2)
                } else {
                    Text(h.title)
                        .font(.system(size: h.level == 1 ? 13 : 12, weight: isActive ? .semibold : .regular))
                        .foregroundColor(isHovered ? DesignTokens.swiftUI.titleText : (isActive ? DesignTokens.swiftUI.accent : DesignTokens.swiftUI.tertiaryText))
                        .lineLimit(1)
                        .scaleEffect(isHovered ? 1.14 : 1, anchor: .trailing)
                }
            }
            .frame(height: hovered ? 26 : 18)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredIndex = hovering ? h.id : nil
        }
    }
}
