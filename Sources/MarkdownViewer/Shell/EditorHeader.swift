import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum EditorHeaderLayout {
    static let previewControlWidth: CGFloat = 41
    static let editControlWidth: CGFloat = 51

    static func previewModeControlWidth(isPreviewMode: Bool) -> CGFloat {
        isPreviewMode ? editControlWidth : previewControlWidth
    }
}

/// Non-typographic interaction geometry shared by the tab strip controls.
/// These values mirror the authoritative prototype without coupling rendering
/// to WebKit text rasterization.
enum EditorHeaderVisualPolicy {
    static let tabHeight: CGFloat = 28
    static let tabCornerRadius: CGFloat = 6
    static let tabCloseSlot: CGFloat = 16
    static let dirtyIndicatorDiameter: CGFloat = 7
    static let actionHoverOpacity: Double = 0.05
    static let activeTabOpacity: Double = 0.06
    static let pressedOpacity: Double = 0.08
    static let confirmCloseHeight: CGFloat = 18
}

// MARK: - Editor header (44px): sidebar toggle + tabs + actions

struct EditorHeader: View {
    @EnvironmentObject var docManager: DocumentManager
    @ObservedObject var findState: FindState
    let tabPadLeft: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            // Sidebar toggle — spec: 26×26, radius 6, color #aeaeb2, hover bg rgba(0,0,0,0.05) + #6e6e73
            HeaderIconButton(action: { docManager.toggleSidebar() },
                             frame: CGSize(width: 26, height: 26),
                             identifier: "toggle-sidebar",
                             tip: "显示 / 隐藏侧栏") { color in
                    CIcon { CustomIcons.sidebarToggle }
                        .frame(width: 16, height: 13)
                        .offset(y: 0.5)
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
                                     identifier: "new-document",
                                     tip: "新建文档 · ⌘N") { color in
                        Text("＋")
                            .font(.system(size: 16))
                            .foregroundColor(color)
                    }
                }
            }

            // Preview + Find + Open controls share the authoritative 2pt gap.
            HStack(spacing: 2) {
                if docManager.activeTab?.isMarkdown == true {
                    PreviewModeButton()
                }

                HeaderIconButton(action: { findState.openFind() },
                                 frame: CGSize(width: 28, height: 26),
                                 identifier: "open-find",
                                 tip: "查找 / 替换 · ⌘F") { color in
                    CIcon { CustomIcons.find }
                        .frame(width: 14, height: 14)
                        .foregroundColor(color)
                }

                HeaderIconButton(action: { docManager.openDocument() },
                                 frame: CGSize(width: 28, height: 26),
                                 identifier: "open-document",
                                 tip: "打开 · ⌘O") { color in
                CIcon { CustomIcons.openFolder }
                    .frame(width: 15, height: 14)
                    // An odd-width SVG in an even-width control has the same
                    // half-point centring rule as the reference SVG.
                    .offset(x: 0.5)
                    .foregroundColor(color)
                }
            }
        }
        .padding(.trailing, 12)
    }
}

private struct PreviewModeButton: View {
    @EnvironmentObject var docManager: DocumentManager
    @State private var hovered = false

    var body: some View {
        Button(action: { docManager.togglePreviewMode() }) {
            Text(docManager.previewMode ? "✐ 编辑" : "预览")
                .font(.system(size: 11.5))
                .foregroundColor(
                    hovered
                        ? DesignTokens.swiftUI.secondaryText
                        : (docManager.previewMode
                            ? DesignTokens.swiftUI.accent
                            : DesignTokens.swiftUI.placeholderText)
                )
                .frame(
                    width: EditorHeaderLayout.previewModeControlWidth(
                        isPreviewMode: docManager.previewMode
                    ),
                    height: 26
                )
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            hovered
                                ? Color.black.opacity(EditorHeaderVisualPolicy.actionHoverOpacity)
                                : (docManager.previewMode
                                    ? DesignTokens.swiftUI.accent.opacity(0.12)
                                    : Color.clear)
                        )
                )
                .debugVisualAnchor("preview-control-frame")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("toggle-preview")
        .accessibilityLabel(docManager.previewMode ? "返回编辑模式" : "切换到纯预览")
        .accessibilityValue(docManager.previewMode ? "已启用" : "未启用")
        .mvFocusVisible()
        .onHover { hovered = $0 }
        .mvNativeCursor(.pointingHand)
        .mvTip(docManager.previewMode ? "返回编辑 · ⌘⇧P" : "纯预览（隐藏语法）· ⌘⇧P")
    }
}

// MARK: - Header button style (hover: bg rgba(0,0,0,0.05), color #6e6e73)

private struct HeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                .fill(configuration.isPressed
                        ? Color.black.opacity(EditorHeaderVisualPolicy.pressedOpacity)
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
    let identifier: String
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
                        .fill(hover
                            ? Color.black.opacity(EditorHeaderVisualPolicy.actionHoverOpacity)
                            : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(HeaderButtonStyle())
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(tip)
        .mvFocusVisible()
        .mvTip(tip)
        .onHover { hover = $0 }
        .mvNativeCursor(.pointingHand)
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
        .frame(height: EditorHeaderVisualPolicy.tabHeight)
        .background(
            RoundedRectangle(cornerRadius: EditorHeaderVisualPolicy.tabCornerRadius)
                .fill(isActive
                    ? Color.black.opacity(EditorHeaderVisualPolicy.activeTabOpacity)
                    : (isHovered
                        ? Color.black.opacity(EditorHeaderVisualPolicy.actionHoverOpacity)
                        : .clear))
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tab-\(tab.id.uuidString)")
        .accessibilityLabel(tab.name)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : [.isButton])
        .accessibilityValue(tab.isDirty ? "有未保存的更改" : "已保存")
        .accessibilityHint(isConfirming ? "再次激活将关闭并丢弃未保存的更改" : "激活文档")
        .accessibilityAction { docManager.activateTab(tab.id) }
        // Route through activateTab so the OUTGOING tab's live edits reconcile first.
        .onTapGesture { docManager.activateTab(tab.id) }
        .onHover { isHovered = $0 }
        .mvNativeCursor(.pointingHand)
    }

    // spec L105: red pill "确认关闭?" — height 18, padding 0 7px, radius 6,
    // font 11/500, color #C7482E, bg rgba(199,72,46,0.10), line-height 1.
    private var confirmCapsule: some View {
        Button(action: { docManager.requestClose(tab) }) {
            Text("确认关闭?")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DesignTokens.swiftUI.danger)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .frame(height: EditorHeaderVisualPolicy.confirmCloseHeight)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(DesignTokens.swiftUI.danger.opacity(0.10))
                )
                .contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tab-confirm-close-\(tab.id.uuidString)")
            .accessibilityLabel("确认关闭 \(tab.name)")
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
                    .frame(
                        width: EditorHeaderVisualPolicy.dirtyIndicatorDiameter,
                        height: EditorHeaderVisualPolicy.dirtyIndicatorDiameter
                    )
                    .help("未保存 · ⌘S 保存")
            }
            if isHovered {
                // spec L112: × font-size 13, no weight; color #aeaeb2; hover bg rgba(0,0,0,0.08) + color #1d1d1f
                Button(action: { docManager.requestClose(tab) }) {
                    Text("×")
                        .font(.system(size: 13))
                        .foregroundColor(closeHovered
                            ? DesignTokens.swiftUI.titleText
                            : DesignTokens.swiftUI.placeholderText)
                        .frame(width: 16, height: 16)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(closeHovered
                                    ? Color.black.opacity(EditorHeaderVisualPolicy.pressedOpacity)
                                    : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tab-close-\(tab.id.uuidString)")
                    .accessibilityLabel("关闭 \(tab.name)")
                    .help("关闭 · ⌘W")
                    .onHover { closeHovered = $0 }
            }
        }
        .frame(
            width: EditorHeaderVisualPolicy.tabCloseSlot,
            height: EditorHeaderVisualPolicy.tabCloseSlot
        )  // always reserved → tab width never jitters
    }
}
