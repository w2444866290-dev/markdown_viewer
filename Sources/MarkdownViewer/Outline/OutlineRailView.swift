import SwiftUI

/// Left-side outline rail that melts from hierarchy ticks into heading labels.
struct OutlineRailView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let headings: [OutlineController.Heading]
    @ObservedObject var activeHeading: ActiveHeadingModel
    let onJump: (Int) -> Void
    var docToken: UUID? = nil
    var onHoverChange: ((Bool) -> Void)? = nil

    @State private var interaction = OutlineRailInteractionState()

    private let tickWidths: [CGFloat] = [16, 13, 11, 9, 8, 7]
    private let labelSizes: [CGFloat] = [13.5, 12.5, 12, 11.5, 11, 11]

    var body: some View {
        Group {
            if !headings.isEmpty {
                GeometryReader { geometry in
                    let railWidth: CGFloat = interaction.expanded ? 258 : 64
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(headings.enumerated()), id: \.element.id) { index, heading in
                            outlineRow(heading, index: index)
                        }
                    }
                    .padding(.leading, 18)
                    .padding(.trailing, 20)
                    .padding(.vertical, 30)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: railWidth, alignment: .leading)
                    .frame(
                        minHeight: OutlineBehaviorPolicy.railMinimumHitHeight,
                        alignment: .center
                    )
                    .contentShape(Rectangle())
                    .onHover(perform: setRailHover)
                    .debugVisualAnchor("outline-rail-frame")
                    .position(x: railWidth / 2, y: geometry.size.height * 0.46)
                }
                .frame(width: interaction.expanded ? 258 : 64)
                .animation(
                    MotionPolicy.animation(
                        .timingCurve(
                            0.22,
                            1,
                            0.36,
                            1,
                            duration: OutlineBehaviorPolicy.railRowHeightDuration
                        ),
                        reduceMotion: reduceMotion
                    ),
                    value: interaction.expanded
                )
            }
        }
        .onChange(of: docToken) { _ in resetInteraction() }
        .onChange(of: headings.count) { count in
            if count == 0 {
                resetInteraction()
            } else if let hoveredIndex = interaction.hoveredIndex,
                      hoveredIndex >= count {
                interaction.setHoveredIndex(nil)
            }
        }
        .onDisappear(perform: resetInteraction)
    }

    private func outlineRow(_ heading: OutlineController.Heading, index: Int) -> some View {
        let levelIndex = min(max(heading.level, 1), 6) - 1
        let isActive = heading.id == activeHeading.index
        let isHovered = interaction.hoveredIndex == index
        let delay = MotionPolicy.delay(
            interaction.expanded
                ? Double(index) * OutlineBehaviorPolicy.railRowStagger
                : 0,
            reduceMotion: reduceMotion
        )

        return Button(action: { onJump(heading.charIndex) }) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(isActive ? DesignTokens.swiftUI.accent : DesignTokens.swiftUI.tickRest)
                    .frame(width: tickWidths[levelIndex], height: 2)
                    .opacity(interaction.expanded ? 0 : 1)
                    .blur(radius: interaction.expanded ? 3 : 0)
                    .scaleEffect(x: interaction.expanded ? 2.6 : 1, y: 1, anchor: .leading)
                    .animation(
                        MotionPolicy.animation(
                            .easeOut(
                                duration: OutlineBehaviorPolicy.railExpansionDuration
                            ).delay(delay),
                            reduceMotion: reduceMotion
                        ),
                        value: interaction.expanded
                    )
                    .animation(
                        MotionPolicy.animation(
                            .easeOut(
                                duration: OutlineBehaviorPolicy.currentTickColorDuration
                            ),
                            reduceMotion: reduceMotion
                        ),
                        value: isActive
                    )

                Text(heading.title)
                    .font(.system(size: labelSizes[levelIndex], weight: .regular))
                    .foregroundColor(
                        isHovered
                            ? DesignTokens.swiftUI.titleText
                            : (isActive
                                ? DesignTokens.swiftUI.accent
                                : DesignTokens.swiftUI.tertiaryText)
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 220, alignment: .leading)
                    .offset(x: CGFloat(levelIndex) * 11)
                    .shadow(color: .white, radius: 4)
                    .shadow(color: .white, radius: 2.5)
                    .shadow(color: .white, radius: 1)
                    .opacity(interaction.expanded ? 1 : 0)
                    .blur(radius: interaction.expanded ? 0 : 5)
                    .scaleEffect(isHovered ? 1.14 : 1, anchor: .leading)
                    .animation(
                        MotionPolicy.animation(
                            .easeOut(
                                duration: OutlineBehaviorPolicy.railExpansionDuration
                            ).delay(delay),
                            reduceMotion: reduceMotion
                        ),
                        value: interaction.expanded
                    )
                    .animation(
                        MotionPolicy.animation(
                            .easeOut(duration: OutlineBehaviorPolicy.rowHoverDuration),
                            reduceMotion: reduceMotion
                        ),
                        value: isHovered
                    )
                    .animation(
                        MotionPolicy.animation(
                            .easeOut(
                                duration: OutlineBehaviorPolicy.currentLabelColorDuration
                            ),
                            reduceMotion: reduceMotion
                        ),
                        value: isActive
                    )
            }
            .frame(minWidth: 26, maxWidth: 220, alignment: .leading)
            .frame(height: interaction.expanded ? 23 : 9)
            .animation(
                MotionPolicy.animation(
                    .timingCurve(
                        0.22,
                        1,
                        0.36,
                        1,
                        duration: OutlineBehaviorPolicy.railRowHeightDuration
                    ).delay(delay),
                    reduceMotion: reduceMotion
                ),
                value: interaction.expanded
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(
            MarkdownAccessibilitySurface.outlineHeading(index: index)
        )
        .accessibilityLabel(heading.title)
        .accessibilityHint("跳转到此标题")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .help(heading.title)
        .onHover { isHovering in
            interaction.setHoveredIndex(isHovering ? index : nil)
            if isHovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    private func setRailHover(_ hovering: Bool) {
        if hovering {
            onHoverChange?(true)
            interaction.enterRail()
            return
        }

        onHoverChange?(false)
        let generation = interaction.leaveRail()
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OutlineBehaviorPolicy.hoverLeaveDelay
        ) {
            interaction.collapse(ifCurrent: generation)
        }
    }

    private func resetInteraction() {
        interaction.reset()
        onHoverChange?(false)
    }
}
