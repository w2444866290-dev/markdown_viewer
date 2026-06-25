import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var docManager: DocumentManager
    @ObservedObject var findState: FindState
    @ObservedObject private var toaster = Toaster.shared
    @StateObject private var bridge = EditorBridge()
    // Held via @State (NOT @StateObject/@ObservedObject) on purpose: @State keeps
    // a stable reference WITHOUT subscribing to objectWillChange, so per-frame
    // scroll updates to scrollModel.value never re-render ContentView. Only the
    // isolated EditorStatusBar observes it.
    @State private var scrollModel = ScrollProgressModel()
    @State private var isDragging = false
    @State private var hasInitialized = false

    private var tabPadLeft: CGFloat {
        docManager.sidebarOpen ? 12 : 84
    }

    var body: some View {
        HStack(spacing: 0) {
            if docManager.sidebarOpen {
                SidebarView()
                    .frame(width: docManager.sidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            VStack(spacing: 0) {
                EditorHeader(findState: findState, tabPadLeft: tabPadLeft)
                    .frame(height: 44)
                    .padding(.leading, tabPadLeft)

                ZStack(alignment: .topTrailing) {
                    if docManager.activeTab != nil {
                        ZStack(alignment: .trailing) {
                            EditorView(
                                text: docManager.textBinding,
                                fontIndex: $docManager.fontIndex,
                                findState: findState,
                                bridge: bridge,
                                scrollModel: scrollModel
                            )
                            .id(docManager.activeTabID)

                            OutlineRailView(
                                headings: bridge.headings,
                                activeIndex: bridge.activeHeadingIndex,
                                onJump: { bridge.onJumpToHeading?($0) }
                            )
                        }
                    } else {
                        emptyState
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DesignTokens.swiftUI.paper)
                .overlay(alignment: .bottomTrailing) {
                    EditorStatusBar(scrollModel: scrollModel, bridge: bridge)
                }
                .overlay(alignment: .bottomLeading) {
                    if !bridge.hoveredURL.isEmpty { hoverURLPreview }
                }
            }
        }
        .background(MovableByBackground())
        .background(DesignTokens.swiftUI.paper)
        .ignoresSafeArea()
        .overlay {
            if docManager.paletteOpen {
                CommandPaletteView()
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if findState.isOpen {
                FindBarView(state: findState)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            if isDragging {
                dragOverlay
            }
        }
        .overlay(alignment: .top) {
            if toaster.visible {
                ToastView(message: toaster.message)
                    .padding(.top, 56)
                    .transition(.opacity)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
            handleDrop(providers: providers)
        }
        .animation(.easeInOut(duration: 0.18), value: docManager.sidebarOpen)
        .onAppear {
            guard !hasInitialized else { return }
            hasInitialized = true
            if docManager.tabs.isEmpty {
                docManager.newDocument(text: sampleText)
            }
        }
        .mvTooltipHost()
    }

    // MARK: - Drag overlay

    private var dragOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .stroke(DesignTokens.swiftUI.accent, lineWidth: 2)
                .background(DesignTokens.swiftUI.accent.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            Text("松开以打开 Markdown 文件")
                .font(.system(size: 13))
                .foregroundColor(DesignTokens.swiftUI.titleText)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(DesignTokens.swiftUI.paper)
                .cornerRadius(10)
                // spec L221: 0 0 0 1px rgba(0,0,0,0.05) hairline border hugging the radius
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.14), radius: 14, y: 8)
        }
        .padding(10)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("没有打开的文档")
                .font(.system(size: 14))
                .foregroundColor(DesignTokens.swiftUI.placeholderText)
            Text("在左侧选择文件，或按 ⌘K")
                .font(.system(size: 12))
                .foregroundColor(DesignTokens.swiftUI.disabledText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Link URL preview — spec L213: bottom 14, left 20, 11.5px,
    // #767676, single line ellipsis, max-width 42%, no hit testing.

    private var hoverURLPreview: some View {
        GeometryReader { geo in
            Text(bridge.hoveredURL)
                .font(.system(size: 11.5))
                .foregroundColor(DesignTokens.swiftUI.statusText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: geo.size.width * 0.42, alignment: .leading)
                .padding(.leading, 20)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Drop handling

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let path = String(data: data, encoding: .utf8),
                  let url = URL(string: path) else { return }
            let ext = url.pathExtension.lowercased()
            guard ["md", "markdown", "txt", "text"].contains(ext) else { return }
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                DispatchQueue.main.async {
                    docManager.openTab(for: url, text: text)
                }
            }
        }
        return true
    }

    private let sampleText = """
    # Markdown Viewer

    一个为 macOS 设计的轻量 Markdown 阅读器：打开即读，不打扰。

    ## 特性

    - 安静侧栏与文档树，支持按名称筛选
    - 顶部多标签页，未保存的文档以琥珀点提示
    - 右侧悬浮目录，滚动同步高亮
    - ⌘F 查找与替换，⌘K 命令面板

    ## 快捷键

    | 快捷键 | 功能 |
    |--------|------|
    | ⌘ N | 新建文档 |
    | ⌘ S | 保存 |
    | ⌘ F | 查找 / 替换 |
    | ⌘ K | 命令面板 |
    | ⌘ + | 放大字号 |
    | ⌘ - | 缩小字号 |

    > 设计原则：读起来像一页纸，而不是一个应用。
    """
}

// MARK: - Status bar — isolated so scroll only re-renders THIS view
//
// spec: bottom 14px, right 20px, "{千分位字数} 字 · {行数} 行 · {pct}%",
// font 11.5 monospaced, statusText color, fade out 0.8s after scrolling stops.
//
// Observes ScrollProgressModel (the per-frame scroll sink) and EditorBridge
// (char/line counts, changed only on edit). Because ContentView holds the model
// via @State and does NOT observe it, scrolling re-evaluates only this view.
private struct EditorStatusBar: View {
    @ObservedObject var scrollModel: ScrollProgressModel
    @ObservedObject var bridge: EditorBridge
    @State private var faded = false

    // Shared formatter avoids a fresh allocation on every render.
    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private var wordCount: String {
        Self.numberFormatter.string(from: NSNumber(value: bridge.charCount))
            ?? "\(bridge.charCount)"
    }

    var body: some View {
        Text("\(wordCount) 字 · \(bridge.lineCount) 行 · \(Int(scrollModel.value * 100))%")
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundColor(DesignTokens.swiftUI.statusText)
            .opacity(faded ? 0 : 1)
            .animation(.easeInOut(duration: 0.3), value: faded)
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
            .onReceive(
                scrollModel.$value.debounce(for: .seconds(0.8), scheduler: DispatchQueue.main)
            ) { _ in
                faded = false
            }
            .onReceive(scrollModel.$value) { _ in
                faded = true
            }
    }
}

// MARK: - Editor header (44px): sidebar toggle + tabs + actions

private struct EditorHeader: View {
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
                .padding(.horizontal, 8)
            }

            // Find + Open buttons — spec: gap 2px, 28×26, hover bg rgba(0,0,0,0.05) + #6e6e73
            HStack(spacing: 2) {
                HeaderIconButton(action: { findState.toggleOpen() },
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
        .onTapGesture { docManager.activeTabID = tab.id }
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
