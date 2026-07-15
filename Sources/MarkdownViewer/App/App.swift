import SwiftUI

enum AppShortcutID: CaseIterable, Hashable {
    case newDocument
    case save
    case open
    case closeTab
    case find
    case commandPalette
    case toggleSidebar
    case increaseFont
    case decreaseFont
    case resetFont
    case togglePreview
    case reopenClosedTab
}

struct AppShortcutDefinition {
    let id: AppShortcutID
    let key: KeyEquivalent
    let modifiers: EventModifiers
}

enum AppShortcutCatalog {
    static let newDocument = AppShortcutDefinition(id: .newDocument, key: "n", modifiers: .command)
    static let save = AppShortcutDefinition(id: .save, key: "s", modifiers: .command)
    static let open = AppShortcutDefinition(id: .open, key: "o", modifiers: .command)
    static let closeTab = AppShortcutDefinition(id: .closeTab, key: "w", modifiers: .command)
    static let find = AppShortcutDefinition(id: .find, key: "f", modifiers: .command)
    static let commandPalette = AppShortcutDefinition(id: .commandPalette, key: "k", modifiers: .command)
    static let toggleSidebar = AppShortcutDefinition(id: .toggleSidebar, key: "\\", modifiers: .command)
    static let increaseFont = AppShortcutDefinition(id: .increaseFont, key: "+", modifiers: .command)
    static let decreaseFont = AppShortcutDefinition(id: .decreaseFont, key: "-", modifiers: .command)
    static let resetFont = AppShortcutDefinition(id: .resetFont, key: "0", modifiers: .command)
    static let togglePreview = AppShortcutDefinition(
        id: .togglePreview,
        key: "p",
        modifiers: [.command, .shift]
    )
    static let reopenClosedTab = AppShortcutDefinition(
        id: .reopenClosedTab,
        key: "t",
        modifiers: [.command, .shift]
    )

    static let required: [AppShortcutDefinition] = [
        newDocument,
        save,
        open,
        closeTab,
        find,
        commandPalette,
        toggleSidebar,
        increaseFont,
        decreaseFont,
        resetFont,
        togglePreview,
        reopenClosedTab,
    ]
}

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
        WindowGroup(id: "main") {
            ContentView(findState: findState)
                .environmentObject(docManager)
                .onAppear { docManager.findStateToggle = { findState.openFind() } }
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
                .ignoresSafeArea()
        }
        .windowStyle(.hiddenTitleBar)
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(
            width: AppEnv.visualTest ? AppEnv.visualTestWindowSize.width : 1_180,
            height: AppEnv.visualTest ? AppEnv.visualTestWindowSize.height : 760
        )
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("撤销") { docManager.undoActiveEdit() }
                    .keyboardShortcut("z")
                Button("重做") { docManager.redoActiveEdit() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .newItem) {
                Button("新建") { docManager.newDocument() }
                    .keyboardShortcut(
                        AppShortcutCatalog.newDocument.key,
                        modifiers: AppShortcutCatalog.newDocument.modifiers
                    )
            }
            CommandGroup(replacing: .saveItem) {
                Button("保存") { docManager.saveCurrent() }
                    .keyboardShortcut(
                        AppShortcutCatalog.save.key,
                        modifiers: AppShortcutCatalog.save.modifiers
                    )
                Button("另存为…") { docManager.saveAsCurrent() }
                    .keyboardShortcut("s", modifiers: [.shift, .command])
            }
            CommandGroup(after: .newItem) {
                Button("打开…") { docManager.openDocument() }
                    .keyboardShortcut(
                        AppShortcutCatalog.open.key,
                        modifiers: AppShortcutCatalog.open.modifiers
                    )
            }
            CommandMenu("查找") {
                Button("查找 / 替换") { findState.openFind() }
                    .keyboardShortcut(
                        AppShortcutCatalog.find.key,
                        modifiers: AppShortcutCatalog.find.modifiers
                    )
            }
            CommandMenu("查看") {
                Button("命令面板") { docManager.toggleCommandPalette() }
                    .keyboardShortcut(
                        AppShortcutCatalog.commandPalette.key,
                        modifiers: AppShortcutCatalog.commandPalette.modifiers
                    )
                Button(docManager.previewMode ? "返回编辑" : "纯预览") {
                    docManager.togglePreviewMode()
                }
                .keyboardShortcut(
                    AppShortcutCatalog.togglePreview.key,
                    modifiers: AppShortcutCatalog.togglePreview.modifiers
                )
                .disabled(docManager.activeTab?.isMarkdown != true)
                Button("显示 / 隐藏侧栏") { docManager.toggleSidebar() }
                    .keyboardShortcut(
                        AppShortcutCatalog.toggleSidebar.key,
                        modifiers: AppShortcutCatalog.toggleSidebar.modifiers
                    )
                Divider()
                Button("关闭标签页") {
                    if let tab = docManager.activeTab { docManager.requestClose(tab) }
                }
                .keyboardShortcut(
                    AppShortcutCatalog.closeTab.key,
                    modifiers: AppShortcutCatalog.closeTab.modifiers
                )
                .disabled(docManager.activeTab == nil)
                Button("恢复关闭的标签") { docManager.reopenClosed() }
                    .keyboardShortcut(
                        AppShortcutCatalog.reopenClosedTab.key,
                        modifiers: AppShortcutCatalog.reopenClosedTab.modifiers
                    )
                    .disabled(docManager.lastClosedTab == nil)
                Divider()
                Button("放大字号") { docManager.applyFont(docManager.fontIndex + 1) }
                    .keyboardShortcut(
                        AppShortcutCatalog.increaseFont.key,
                        modifiers: AppShortcutCatalog.increaseFont.modifiers
                    )
                Button("缩小字号") { docManager.applyFont(docManager.fontIndex - 1) }
                    .keyboardShortcut(
                        AppShortcutCatalog.decreaseFont.key,
                        modifiers: AppShortcutCatalog.decreaseFont.modifiers
                    )
                Button("重置字号") { docManager.applyFont(1) }
                    .keyboardShortcut(
                        AppShortcutCatalog.resetFont.key,
                        modifiers: AppShortcutCatalog.resetFont.modifiers
                    )
            }
        }
    }
}
