import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var docManager: DocumentManager
    @State private var hoveredItem: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 44)

            TextField("筛选文档", text: $docManager.sideFilter)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(DesignTokens.swiftUI.fieldFill)
                .cornerRadius(6)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(docManager.fileTree) { node in
                        SidebarRow(node: node, level: 0)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }

            HStack(spacing: 7) {
                Text("⌘K")
                    .font(.system(size: 10.5, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(DesignTokens.swiftUI.hover)
                    .cornerRadius(6)
                Text("全部命令")
                    .font(.system(size: 11.5))
                Spacer()
            }
            .foregroundColor(Color(hex: 0x9A9A9E))
            .padding(.horizontal, 16)
            .frame(height: 38)
            .contentShape(Rectangle())
            .onTapGesture { docManager.paletteOpen = true }
        }
        .frame(minWidth: 176, maxWidth: 440)
        .background(DesignTokens.swiftUI.sidebar)
    }
}

struct SidebarRow: View {
    let node: FileNode
    let level: Int

    var body: some View {
        Button(action: {
            if !node.isDirectory {
                let url = node.url
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    // TODO: wire up docManager.openTab
                }
            }
        }) {
            HStack(spacing: 7) {
                if node.isDirectory {
                    Image(nsImage: CustomIcons.sidebarFolder(size: NSSize(width: 13, height: 11)))
                } else {
                    Image(nsImage: CustomIcons.docFile(size: NSSize(width: 10, height: 12)))
                }
                Text(node.name)
                    .font(.system(size: 13))
                    .foregroundColor(DesignTokens.swiftUI.fileRowText)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .padding(.leading, CGFloat(level * 16))
            .background(Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)

        if !node.children.isEmpty {
            ForEach(node.children) { child in
                SidebarRow(node: child, level: level + 1)
            }
        }
    }
}
