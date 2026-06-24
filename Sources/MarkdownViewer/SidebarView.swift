import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var docManager: DocumentManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarHeader()
            SidebarFilter()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(docManager.fileTree) { node in
                        SidebarNodeView(node: node, depth: 0)
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .background(DesignTokens.swiftUI.sidebarFill)
    }
}

private struct SidebarHeader: View {
    @EnvironmentObject var docManager: DocumentManager

    var body: some View {
        HStack(spacing: 4) {
            Button(action: { docManager.sidebarOpen.toggle() }) {
                CIcon { CustomIcons.sidebarToggle }
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("切换侧栏")

            Spacer()

            Text(docManager.directoryURL?.lastPathComponent ?? "文件")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DesignTokens.swiftUI.secondaryText)
                .lineLimit(1)

            Spacer()

            Button(action: { docManager.openDirectory() }) {
                CIcon { CustomIcons.openFolder }
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("打开文件夹")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

private struct SidebarFilter: View {
    @EnvironmentObject var docManager: DocumentManager

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(DesignTokens.swiftUI.placeholderText)
            TextField("筛选…", text: $docManager.sideFilter)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(DesignTokens.swiftUI.tickRest)
        .cornerRadius(4)
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }
}

private struct SidebarNodeView: View {
    let node: FileNode
    let depth: Int
    @EnvironmentObject var docManager: DocumentManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                if !node.isDirectory { docManager.openFileNode(node) }
            }) {
                HStack(spacing: 5) {
                    if node.isDirectory {
                        CIcon { CustomIcons.sidebarFolder(size: NSSize(width: 16, height: 16)) }
                            .frame(width: 16, height: 16)
                    } else {
                        CIcon { CustomIcons.docFile(size: NSSize(width: 16, height: 16)) }
                            .frame(width: 16, height: 16)
                    }
                    Text(node.name)
                        .font(.system(size: 12.5))
                        .foregroundColor(DesignTokens.swiftUI.secondaryText)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.leading, CGFloat(10 + depth * 14))
                .padding(.trailing, 10)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if node.isDirectory {
                ForEach(node.children) { child in
                    SidebarNodeView(node: child, depth: depth + 1)
                }
            }
        }
    }
}
