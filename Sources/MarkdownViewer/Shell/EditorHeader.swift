import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Editor header (44px): sidebar toggle + tabs + actions

struct EditorHeader: View {
    @EnvironmentObject var docManager: DocumentManager
    @ObservedObject var findState: FindState
    let tabPadLeft: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            // Sidebar toggle — spec: 26×26, radius 6, color #aeaeb2, hover bg rgba(0,0,0,0.05) + #6e6e73
            HeaderIconButton(action: { docManager.sidebarOpen.toggle() },
                             frame: CGSize(width: 26, height: 26),
                             tip: "显示 / 隐藏侧栏") { color in
                CIcon { CustomIcons.sidebarToggle }
                    .frame(width: 16, height: 13)
                    .foregroundColor(color)
            }

            // Tabs area
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(docManager.tabs) { tab in
                        EditorTabPill(tab: tab)
                    }
                    // + button — spec: 26×26, radius 6, font-size 16, hover bg rgba(0,0,0,0.05) + #6e6e73
                    HeaderIconButton(action: { docManager.newDocument() },
                                     frame: CGSize(width: 26, height: 26),
                                     tip: "新建文档 · ⌘N") { color in
                        Text("＋")
                            .font(.system(size: 16))
                            .foregroundColor(color)
                    }
                }
            }

            // Find + Open buttons — spec: gap 2px, 28×26, hover bg rgba(0,0,0,0.05) + #6e6e73
            HStack(spacing: 2) {
                HeaderIconButton(action: { findState.openFind() },
                                 frame: CGSize(width: 28, height: 26),
                                 tip: "查找 / 替换 · ⌘F") { color in
                    CIcon { CustomIcons.find }
                        .frame(width: 14, height: 14)
                        .foregroundColor(color)
                }

                HeaderIconButton(action: { docManager.openDocument() },
                                 frame: CGSize(width: 28, height: 26),
                                 tip: "打开 · ⌘O") { color in
                    CIcon { CustomIcons.openFolder }
                        .frame(width: 15, height: 14)
                        .foregroundColor(color)
                }
            }
        }
        .padding(.trailing, 12)
    }
}

// MARK: - Header button style (hover: bg rgba(0,0,0,0.05), color #6e6e73)

private struct HeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(configuration.isPressed
                        ? Color.black.opacity(0.08)
                        : Color.clear)
            )
    }
}

// spec L96/117/121/124: top-bar icon buttons hover → bg rgba(0,0,0,0.05) + icon
// color #6e6e73 (secondaryText). Static color #aeaeb2 (placeholderText). The icon
// foreground is set inside the label, so hover color must be driven per-button here
// (an outer .foregroundColor in the ButtonStyle can't override the inner one).
private struct HeaderIconButton<Label: View>: View {
    let action: () -> Void
    let frame: CGSize
    let tip: String
    @ViewBuilder let label: (Color) -> Label
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            label(hover ? DesignTokens.swiftUI.secondaryText
                        : DesignTokens.swiftUI.placeholderText)
                .frame(width: frame.width, height: frame.height)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hover ? Color.black.opacity(0.05) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(HeaderButtonStyle())
        .mvTip(tip)
        .onHover { hover = $0 }
    }
}

// MARK: - Tab pill

private struct EditorTabPill: View {
    @EnvironmentObject var docManager: DocumentManager
    let tab: DocumentTab
    @State private var isHovered = false
    @State private var closeHovered = false

    var isActive: Bool { tab.id == docManager.activeTabID }
    var isConfirming: Bool { docManager.confirmingCloseTabID == tab.id }

    var body: some View {
        // spec: [name][gap 6][16×16 trailing slot OR 确认关闭? capsule]
        HStack(spacing: 6) {
            Text(tab.name)
                .font(.system(size: 12.5))
                .fontWeight(isActive ? .semibold : .regular)
                .foregroundColor(isActive
                    ? DesignTokens.swiftUI.titleText
                    : DesignTokens.swiftUI.tertiaryText)

            if isConfirming {
                confirmCapsule
            } else {
                trailingSlot
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)  // spec: padding 0 7px 0 12px
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive
                    ? Color.black.opacity(0.06)
                    : (isHovered ? Color.black.opacity(0.05) : .clear))
        )
        .contentShape(Rectangle())
        // Route through activateTab so the OUTGOING tab's live edits reconcile first.
        .onTapGesture { docManager.activateTab(tab.id) }
        .onHover { isHovered = $0 }
    }

    // spec L105: red pill "确认关闭?" — height 18, padding 0 7px, radius 6,
    // font 11/500, color #C7482E, bg rgba(199,72,46,0.10), line-height 1.
    private var confirmCapsule: some View {
        Text("确认关闭?")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(DesignTokens.swiftUI.danger)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(DesignTokens.swiftUI.danger.opacity(0.10))
            )
            .contentShape(Rectangle())
            .onTapGesture { docManager.requestClose(tab) }
            .help("再点一次关闭，未保存的更改将丢弃")
    }

    // spec L108-114: constant 16×16 slot. Dirty (not hovering) → amber dot;
    // hover → × with its own hover background. Slot always reserved → no jitter.
    private var trailingSlot: some View {
        ZStack {
            if tab.isDirty && !isHovered {
                // spec L110: amber dot 7×7 #E8A33D
                Circle()
                    .fill(DesignTokens.swiftUI.accent)
                    .frame(width: 7, height: 7)
            }
            if isHovered {
                // spec L112: × font-size 13, no weight; color #aeaeb2; hover bg rgba(0,0,0,0.08) + color #1d1d1f
                Text("×")
                    .font(.system(size: 13))
                    .foregroundColor(closeHovered
                        ? DesignTokens.swiftUI.titleText
                        : DesignTokens.swiftUI.placeholderText)
                    .frame(width: 16, height: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(closeHovered ? Color.black.opacity(0.08) : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { docManager.requestClose(tab) }
                    .onHover { closeHovered = $0 }
            }
        }
        .frame(width: 16, height: 16)  // always reserved → tab width never jitters
    }
}
