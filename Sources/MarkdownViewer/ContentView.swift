import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var docManager: DocumentManager
    @ObservedObject var findState: FindState
    @State private var scrollProgress: Double = 0
    @State private var activeOutlineIndex: Int = 0
    @State private var isDragging = false
    @State private var hasInitialized = false

    var body: some View {
        HStack(spacing: 0) {
            if docManager.sidebarOpen {
                SidebarView()
                    .frame(width: docManager.sidebarWidth)
            }

            VStack(spacing: 0) {
                EditorHeader(findState: findState)
                    .frame(height: 44)

                ZStack(alignment: .topTrailing) {
                    if docManager.activeTab != nil {
                        ZStack(alignment: .trailing) {
                            EditorView(
                                text: docManager.textBinding,
                                fontIndex: $docManager.fontIndex,
                                scrollProgress: $scrollProgress,
                                findState: findState
                            )
                            .id(docManager.activeTabID)

                            OutlineRailView(
                                headings: [],
                                activeIndex: activeOutlineIndex,
                                onJump: { _ in }
                            )
                        }
                    } else {
                        emptyState
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DesignTokens.swiftUI.paper)
                .overlay(alignment: .bottomTrailing) { statusBar }
            }
        }
        .background(MovableByBackground())
        .background(DesignTokens.swiftUI.paper)
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
        .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
            handleDrop(providers: providers)
        }
        .onAppear {
            guard !hasInitialized else { return }
            hasInitialized = true
            if docManager.tabs.isEmpty {
                docManager.newDocument(text: sampleText)
            }
        }
    }

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

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text("\(docManager.currentText.count) 字")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(DesignTokens.swiftUI.statusText)
            Text("\(Int(scrollProgress * 100))%")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(DesignTokens.swiftUI.statusText)
            if docManager.isDirty {
                Circle().fill(DesignTokens.swiftUI.accent).frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

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

// MARK: - Editor header (44px): sidebar toggle + tabs + actions

private struct EditorHeader: View {
    @EnvironmentObject var docManager: DocumentManager
    @ObservedObject var findState: FindState

    var body: some View {
        HStack(spacing: 0) {
            Button(action: { docManager.sidebarOpen.toggle() }) {
                CIcon { CustomIcons.sidebarToggle }
                    .frame(width: 16, height: 13)
                    .foregroundColor(DesignTokens.swiftUI.placeholderText)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(docManager.tabs) { tab in
                        EditorTabPill(tab: tab)
                    }
                    Button(action: { docManager.newDocument() }) {
                        Text("＋")
                            .font(.system(size: 16))
                            .foregroundColor(DesignTokens.swiftUI.placeholderText)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
            }

            HStack(spacing: 2) {
                Button(action: { findState.toggleOpen() }) {
                    CIcon { CustomIcons.find }
                        .frame(width: 14, height: 14)
                        .foregroundColor(DesignTokens.swiftUI.placeholderText)
                        .frame(width: 28, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: { docManager.openFile() }) {
                    CIcon { CustomIcons.openFolder }
                        .frame(width: 15, height: 14)
                        .foregroundColor(DesignTokens.swiftUI.placeholderText)
                        .frame(width: 28, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.trailing, 12)
        }
    }
}

private struct EditorTabPill: View {
    @EnvironmentObject var docManager: DocumentManager
    let tab: DocumentTab
    @State private var isHovered = false

    var isActive: Bool { tab.id == docManager.activeTabID }

    var body: some View {
        HStack(spacing: 0) {
            // Dirty dot (hidden when hovering, shows × instead)
            if tab.isDirty && !isHovered {
                Circle().fill(DesignTokens.swiftUI.accent)
                    .frame(width: 7, height: 7)
                    .padding(.trailing, 6)
            }

            Text(tab.name)
                .font(.system(size: 12.5))
                .fontWeight(isActive ? .semibold : .regular)
                .foregroundColor(isActive
                    ? DesignTokens.swiftUI.titleText
                    : DesignTokens.swiftUI.tertiaryText)

            // Close button on hover
            if isHovered {
                Text("×")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DesignTokens.swiftUI.placeholderText)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
                    .onTapGesture { docManager.closeTab(tab) }
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive
                    ? Color.black.opacity(0.06)
                    : (isHovered ? Color.black.opacity(0.04) : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { docManager.activeTabID = tab.id }
        .onHover { isHovered = $0 }
    }
}
