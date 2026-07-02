import SwiftUI

@main
struct MarkdownViewerApp: App {
    @StateObject private var docManager = DocumentManager()
    @StateObject private var findState = FindState()

    init() {
        // Earliest point in app startup: arm the in-memory logger's crash flush.
        MVLog.installCrashHandlers()
        MVLog.info("app launched", category: "lifecycle")
    }

    var body: some Scene {
        WindowGroup {
            ContentView(findState: findState)
                .environmentObject(docManager)
                .onAppear { docManager.findStateToggle = { findState.toggleOpen() } }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    // Discrete reconcile point: fold the editor's live text back into
                    // the active tab's snapshot before the app goes away.
                    docManager.reconcileActiveText()
                    // Forced synchronous session write so the latest state (incl. the
                    // just-typed unsaved text and scroll position) survives the quit —
                    // the debounced saves may not have fired yet.
                    docManager.saveSession()
                    MVLog.info("app will terminate", category: "lifecycle")
                }
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
                Button("关闭标签页") {
                    if let tab = docManager.activeTab { docManager.requestClose(tab) }
                }
                .keyboardShortcut("w")
                Button("恢复关闭的标签") { docManager.reopenClosed() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button("放大字号") { docManager.applyFont(docManager.fontIndex + 1) }
                    .keyboardShortcut("=")
                Button("缩小字号") { docManager.applyFont(docManager.fontIndex - 1) }
                    .keyboardShortcut("-")
                Button("重置字号") { docManager.applyFont(1) }
                    .keyboardShortcut("0")
            }
        }
    }
}
