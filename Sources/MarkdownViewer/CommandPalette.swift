import SwiftUI

struct CommandPaletteView: View {
    @EnvironmentObject var docManager: DocumentManager
    @State private var query: String = ""

    private let commands: [(String, String)] = [
        ("新建文档", "⌘N"), ("保存", "⌘S"), ("查找 / 替换", "⌘F"),
        ("打开…", "⌘O"), ("放大字号", "⌘+"), ("缩小字号", "⌘-"),
        ("重置字号", "⌘0"), ("显示 / 隐藏侧栏", "⌘\\")
    ]

    var filteredCommands: [(String, String)] {
        guard !query.isEmpty else { return commands }
        return commands.filter { $0.0.localizedCaseInsensitiveContains(query) }
    }

    var filteredDocs: [FileNode] {
        guard !query.isEmpty else { return [] }
        return docManager.fileTree.filter {
            !$0.isDirectory && $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)
                .onTapGesture { docManager.paletteOpen = false }

            VStack(spacing: 0) {
                Spacer().frame(height: 96)

                VStack(spacing: 0) {
                    TextField("搜索文档或命令…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundColor(DesignTokens.swiftUI.titleText)
                        .padding(.horizontal, 18)
                        .frame(height: 46)

                    Divider().background(DesignTokens.swiftUI.divider)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            if !filteredDocs.isEmpty {
                                sectionHeader("文档")
                                ForEach(filteredDocs) { doc in
                                    paletteRow(doc.name, subtitle: nil, action: {
                                        let url = doc.url
                                        if let text = try? String(contentsOf: url, encoding: .utf8) {
                                            docManager.openTab(for: url, text: text)
                                            docManager.paletteOpen = false
                                        }
                                    })
                                }
                            }
                            if !filteredCommands.isEmpty {
                                sectionHeader(filteredDocs.isEmpty ? "命令" : "命令", topPadding: true)
                                ForEach(filteredCommands, id: \.0) { cmd in
                                    paletteRow(cmd.0, subtitle: cmd.1, action: {
                                        docManager.paletteOpen = false
                                    })
                                }
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 340)
                }
                .frame(width: 460)
                .background(DesignTokens.swiftUI.paper)
                .cornerRadius(14)
                .shadow(color: .black.opacity(0.22), radius: 30, y: 24)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(DesignTokens.swiftUI.ring, lineWidth: 1)
                )
            }
        }
        .background(.ultraThinMaterial)
    }

    private func sectionHeader(_ title: String, topPadding: Bool = false) -> some View {
        Text(title)
            .font(.system(size: 10.5))
            .foregroundColor(DesignTokens.swiftUI.placeholderText)
            .kerning(0.5)
            .padding(.leading, 12)
            .padding(.bottom, 4)
            .padding(.top, topPadding ? 10 : 6)
    }

    private func paletteRow(_ title: String, subtitle: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 13.5))
                    .foregroundColor(DesignTokens.swiftUI.titleText)
                Spacer()
                if let sub = subtitle {
                    Text(sub)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(DesignTokens.swiftUI.placeholderText)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}
