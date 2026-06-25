import SwiftUI

/// Sidebar matching spec: 44px spacer → filter → file tree → ⌘K button.
/// Background #F7F7F8, 28px rows with hover/active states, resize handle.
struct SidebarView: View {
    @EnvironmentObject var docManager: DocumentManager
    @State private var hoveredNodeID: UUID?
    @State private var resizeHover = false
    @GestureState private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .trailing) {
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
                        .foregroundColor(DesignTokens.swiftUI.titleText)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Color.black.opacity(0.04))
                .cornerRadius(6)
                .padding(.top, 2)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

                // File tree — spec: padding 4px 10px 12px, gap 1px
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filteredNodes) { node in
                            SidebarNodeRow(
                                node: node,
                                depth: 0,
                                hoveredNodeID: $hoveredNodeID
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .padding(.bottom, 8)
                }

                // ⌘K button — spec: 38px, color #9a9a9e, hover #6e6e73
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
                    .foregroundColor(DesignTokens.swiftUI.paletteKbd)
                    .padding(.horizontal, 16)
                    .frame(height: 38)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    // No built-in hover color change via modifier; handled by style
                }
            }
            .background(DesignTokens.swiftUI.sidebar)

            // Resize handle — spec: absolute right -4px, 9px wide, 1px line
            Color.clear
                .frame(width: 9)
                .contentShape(Rectangle())
                .allowsHitTesting(true)
                .onHover { resizeHover = $0 }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let newWidth = max(
                                DesignTokens.sidebarMinWidth,
                                min(DesignTokens.sidebarMaxWidth,
                                    docManager.sidebarWidth + value.translation.width
                                )
                            )
                            docManager.sidebarWidth = newWidth
                        }
                )
                .overlay(
                    Rectangle()
                        .fill(resizeHover ? Color.black.opacity(0.18) : Color.clear)
                        .frame(width: 1)
                )
                .offset(x: 4)
        }
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
    @Binding var hoveredNodeID: UUID?
    @EnvironmentObject var docManager: DocumentManager

    private var isExpanded: Bool { docManager.expandedFolders.contains(node.id) }
    private var isActive: Bool {
        !node.isDirectory && docManager.tabs.contains(where: { $0.url == node.url && $0.id == docManager.activeTabID })
    }
    private var isHovered: Bool { hoveredNodeID == node.id }

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
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                        .foregroundColor(rowTextColor)
                        .lineLimit(1)
                    Spacer()
                    if nodeHasDirtyTab {
                        Circle()
                            .fill(DesignTokens.swiftUI.accent)
                            .frame(width: 7, height: 7)
                    }
                }
                .padding(.leading, CGFloat(depth * 14 + 2))
                .padding(.trailing, 8)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(rowBackground)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                hoveredNodeID = hovering ? node.id : nil
            }

            if node.isDirectory && isExpanded {
                ForEach(node.children) { child in
                    SidebarNodeRow(node: child, depth: depth + 1, hoveredNodeID: $hoveredNodeID)
                }
            }
        }
    }

    private var rowBackground: Color {
        if isActive { return Color.black.opacity(0.06) }
        if isHovered { return Color.black.opacity(0.045) }
        return .clear
    }

    private var rowTextColor: Color {
        if node.isDirectory {
            return isHovered
                ? DesignTokens.swiftUI.secondaryText
                : DesignTokens.swiftUI.placeholderText
        }
        if isActive { return DesignTokens.swiftUI.titleText }
        return DesignTokens.swiftUI.fileRowText
    }

    private var nodeHasDirtyTab: Bool {
        docManager.tabs.contains { $0.url == node.url && $0.isDirty }
    }
}
