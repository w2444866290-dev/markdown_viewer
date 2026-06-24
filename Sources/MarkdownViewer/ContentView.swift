import SwiftUI

struct ContentView: View {
    @EnvironmentObject var docManager: DocumentManager

    var body: some View {
        HStack(spacing: 0) {
            if docManager.sidebarOpen {
                SidebarView()
                    .frame(width: docManager.sidebarWidth)
            }

            VStack(spacing: 0) {
                TabBarView()
                ZStack {
                    if docManager.activeTab != nil {
                        EditorView(
                            text: $docManager.editorText,
                            fontIndex: $docManager.fontIndex,
                            isMarkdown: true
                        )
                    } else {
                        emptyState
                    }
                }
            }
        }
        .overlay {
            if docManager.paletteOpen {
                CommandPaletteView()
            }
        }
        .overlay(alignment: .topTrailing) {
            if docManager.findOpen {
                FindBarView()
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
}
