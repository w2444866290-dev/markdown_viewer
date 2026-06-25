import SwiftUI

@main
struct MarkdownViewerApp: App {
    @StateObject private var docManager = DocumentManager()
    @StateObject private var findState = FindState()

    var body: some Scene {
        WindowGroup {
            ContentView(findState: findState)
                .environmentObject(docManager)
                .onAppear { docManager.findStateToggle = { findState.toggleOpen() } }
                .frame(minWidth: 860, minHeight: 560)
                .ignoresSafeArea()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建") { docManager.newDocument() }
                    .keyboardShortcut("n")
            }
            CommandGroup(replacing: .saveItem) {
                Button("保存") { docManager.saveCurrent() }
                    .keyboardShortcut("s")
                Button("另存为…") { docManager.saveAsCurrent() }
                    .keyboardShortcut("s", modifiers: [.shift, .command])
            }
            CommandGroup(after: .newItem) {
                Button("打开…") { docManager.openDocument() }
                    .keyboardShortcut("o")
            }
            CommandMenu("查找") {
                Button("查找 / 替换") { findState.toggleOpen() }
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
