import SwiftUI

@main
struct MarkdownViewerApp: App {
    @StateObject private var docManager = DocumentManager()

    var body: some Scene {
        Window("Markdown 编辑器", id: "main") {
            ContentView()
                .environmentObject(docManager)
                .frame(minWidth: 860, minHeight: 560)
                .background(DesignTokens.swiftUI.paper)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建") { docManager.newDocument() }
                    .keyboardShortcut("n")
            }
            CommandGroup(replacing: .saveItem) {
                Button("保存") { /* save */ }
                    .keyboardShortcut("s")
            }
            CommandMenu("查找") {
                Button("查找 / 替换") { docManager.findOpen.toggle() }
                    .keyboardShortcut("f")
            }
            CommandMenu("查看") {
                Button("命令面板") { docManager.paletteOpen.toggle() }
                    .keyboardShortcut("k")
                Button("显示 / 隐藏侧栏") { docManager.sidebarOpen.toggle() }
                    .keyboardShortcut("\\")
                Divider()
                Button("放大字号") { docManager.fontIndex = min(2, docManager.fontIndex + 1) }
                    .keyboardShortcut("=")
                Button("缩小字号") { docManager.fontIndex = max(0, docManager.fontIndex - 1) }
                    .keyboardShortcut("-")
                Button("重置字号") { docManager.fontIndex = 1 }
                    .keyboardShortcut("0")
            }
        }
    }
}
