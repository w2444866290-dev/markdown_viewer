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
                TabBarView(findState: findState)
                ZStack(alignment: .topTrailing) {
                    if docManager.activeTab != nil {
                        ZStack(alignment: .trailing) {
                            EditorView(
                                text: docManager.textBinding,
                                fontIndex: $docManager.fontIndex,
                                scrollProgress: $scrollProgress,
                                findState: findState
                            )

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
                .overlay(alignment: .bottomTrailing) {
                    statusBar
                }
            }
        }
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
                // Open a default document so the editor is never blank.
                let sample = """
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
                docManager.newDocument()
                // Replace the default text with our sample
                if let idx = docManager.tabs.firstIndex(where: { $0.id == docManager.activeTabID }) {
                    docManager.tabs[idx].text = sample
                }
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
}
