import SwiftUI

/// Sidebar: 44px spacer → filter → file tree → ⌘K button.
/// Matches spec: #F7F7F8 bg, 28px rows, 1px gap.
struct SidebarView: View {
    @EnvironmentObject var docManager: DocumentManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 44px spacer for traffic lights
            Color.clear.frame(height: 44)

            // Filter — spec: padding 2px 12px 8px
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(DesignTokens.swiftUI.placeholderText)
                TextField("筛选文档", text: $docManager.sideFilter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color.black.opacity(0.04))
            .cornerRadius(6)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            // File tree — spec: padding 4px 10px 12px, gap 1px
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(filteredNodes) { node in
                        SidebarNodeRow(node: node, depth: 0)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .padding(.bottom, 8)
            }

            // ⌘K "全部命令" — spec: 38px, #9a9a9e, 11.5px
            Button(action: { docManager.paletteOpen = true }) {
                HStack(spacing: 7) {
                    Text("⌘K")
                        .font(.system(size: 10.5, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.05))
                        .cornerRadius(6)
                    Text("全部命令")
                        .font(.system(size: 11.5))
                }
                .foregroundColor(DesignTokens.swiftUI.disabledText) // #9a9a9e ≈ disabledText
                .padding(.horizontal, 16)
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(DesignTokens.swiftUI.sidebar)
    }

    private var filteredNodes: [FileNode] {
        if docManager.sideFilter.isEmpty {
            return docManager.fileTree
        }
        let q = docManager.sideFilter.lowercased()
        return docManager.fileTree.filter {
            !$0.isDirectory && $0.name.lowercased().contains(q)
        }
    }
}

// MARK: - Sidebar node row

private struct SidebarNodeRow: View {
    let node: FileNode
    let depth: Int
    @EnvironmentObject var docManager: DocumentManager

    private var isExpanded: Bool { docManager.expandedFolders.contains(node.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                if node.isDirectory {
                    if isExpanded {
                        docManager.expandedFolders.remove(node.id)
                    } else {
                        docManager.expandedFolders.insert(node.id)
                    }
                } else {
                    docManager.openFileNode(node)
                }
            }) {
                HStack(spacing: 7) {
                    if node.isDirectory {
                        Text(isExpanded ? "▾" : "▸")
                            .font(.system(size: 9))
                            .foregroundColor(DesignTokens.swiftUI.placeholderText.opacity(0.7))
                            .frame(width: 9)
                        CIcon { CustomIcons.sidebarFolder(size: NSSize(width: 13, height: 11)) }
                            .frame(width: 13, height: 11)
                    } else {
                        CIcon { CustomIcons.docFile(size: NSSize(width: 10, height: 12)) }
                            .frame(width: 10, height: 12)
                    }
                    Text(node.name)
                        .font(.system(size: 13))
                        .foregroundColor(DesignTokens.swiftUI.fileRowText)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.leading, CGFloat(depth * 14 + (node.isDirectory ? 2 : 2)))
                .padding(.trailing, 8)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if node.isDirectory && isExpanded {
                ForEach(node.children) { child in
                    SidebarNodeRow(node: child, depth: depth + 1)
                }
            }
        }
    }
}
