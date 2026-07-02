import SwiftUI
import AppKit

/// Sidebar matching spec: 44px spacer → filter → file tree → ⌘K button.
/// Background #F7F7F8, 28px rows with hover/active states, resize handle.
struct SidebarView: View {
    @EnvironmentObject var docManager: DocumentManager
    @State private var hoveredNodeID: UUID?
    @State private var resizeHover = false
    @State private var paletteHover = false
    @GestureState private var dragOffset: CGFloat = 0

    // Filter keyboard navigation (spec JS `onSideFilterKey` / `kbName`).
    @FocusState private var filterFocused: Bool
    @State private var kbSel = 0
    @State private var keyMonitor: Any?

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(alignment: .leading, spacing: 0) {
                // 44px spacer for traffic lights
                Color.clear.frame(height: 44)

                // Filter — spec: plain input, no icon, padding 0 10px
                TextField("筛选文档", text: $docManager.sideFilter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundColor(DesignTokens.swiftUI.titleText)
                    .focused($filterFocused)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color.black.opacity(0.04))
                    .cornerRadius(6)
                    .padding(.top, 2)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    // Reset keyboard selection whenever the filter query changes.
                    .onChange(of: docManager.sideFilter) { _ in kbSel = 0 }
                    .onChange(of: filterFocused) { focused in
                        if focused { installKeyMonitor() } else { removeKeyMonitor() }
                    }
                    .onDisappear { removeKeyMonitor() }

                // File tree — spec: padding 4px 10px 12px, gap 1px
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filteredNodes) { node in
                            SidebarNodeRow(
                                node: node,
                                depth: 0,
                                hoveredNodeID: $hoveredNodeID,
                                kbSelectedID: kbSelectedNodeID
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
                    .foregroundColor(paletteHover
                        ? DesignTokens.swiftUI.secondaryText
                        : DesignTokens.swiftUI.paletteKbd)
                    .padding(.horizontal, 16)
                    .frame(height: 38)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { paletteHover = $0 }
                .mvTip("所有命令与文档 · ⌘K")

                // Build version — quiet marker so the user can SEE which commit is
                // running. Sits directly below the ⌘K button, left-aligned to line
                // up under it. Plain label (no hit testing). Same dev fallback as
                // the packaged build via AppVersion.label.
                Text(AppVersion.label)
                    .font(.system(size: 10.5))
                    .foregroundColor(DesignTokens.swiftUI.paletteKbd)
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
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
                            // Phase-2: persist the new sidebar width (debounced, fires
                            // ~1s after the drag settles).
                            docManager.scheduleSessionSave()
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

    // Browse mode renders the nested `fileTree`; filtered mode renders a FLAT
    // list of every file (any depth) — spec `sideVisibleFiles()` filters the
    // flat `buildDefs()` list regardless of folder nesting.
    private var filteredNodes: [FileNode] {
        if docManager.sideFilter.isEmpty {
            return docManager.fileTree
        }
        let q = docManager.sideFilter.lowercased()
        return flattenFiles(docManager.fileTree).filter {
            $0.name.lowercased().contains(q)
        }
    }

    // Depth-first flatten to all non-directory nodes (spec's flat file list).
    private func flattenFiles(_ nodes: [FileNode]) -> [FileNode] {
        var out: [FileNode] = []
        for node in nodes {
            if node.isDirectory {
                out.append(contentsOf: flattenFiles(node.children))
            } else {
                out.append(node)
            }
        }
        return out
    }

    // Files eligible for keyboard navigation — spec `sideVisibleFiles()`.
    // Highlight only appears while filtering (matching the spec's `kbName`,
    // which is null unless the filter query is non-empty). In filter mode
    // `filteredNodes` is already the flattened, all-files-only match list, so
    // keyboard nav traverses the same nested matches the rows display.
    private var kbVisibleFiles: [FileNode] {
        docManager.sideFilter.isEmpty
            ? []
            : filteredNodes.filter { !$0.isDirectory }
    }

    // The node id of the current keyboard selection, clamped to range.
    private var kbSelectedNodeID: UUID? {
        let vis = kbVisibleFiles
        guard !vis.isEmpty else { return nil }
        return vis[min(max(kbSel, 0), vis.count - 1)].id
    }

    // MARK: - Filter keyboard navigation (spec JS `onSideFilterKey`)

    // The filter TextField is a focusable NSTextField, so plain `.onKeyPress`
    // is unavailable on macOS 13 (Package.swift target). Mirror the local
    // NSEvent monitor pattern used for the Double-Shift palette trigger.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Only intercept while the filter field is focused and filtering.
            guard filterFocused else { return event }
            let vis = kbVisibleFiles
            guard !vis.isEmpty else { return event }
            switch event.keyCode {
            case 125: // ↓ — clamp to last
                kbSel = min(kbSel + 1, vis.count - 1)
                return nil
            case 126: // ↑ — clamp to first
                kbSel = max(kbSel - 1, 0)
                return nil
            case 36, 76: // Return / keypad Enter
                let idx = min(max(kbSel, 0), vis.count - 1)
                docManager.openFileNode(vis[idx])
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}

// MARK: - Sidebar node row

private struct SidebarNodeRow: View {
    let node: FileNode
    let depth: Int
    @Binding var hoveredNodeID: UUID?
    /// Node currently selected via filter keyboard navigation (spec `kbName`).
    let kbSelectedID: UUID?
    @EnvironmentObject var docManager: DocumentManager

    private var isExpanded: Bool { docManager.expandedFolders.contains(node.id) }
    private var isActive: Bool {
        !node.isDirectory && docManager.tabs.contains(where: { $0.url == node.url && $0.id == docManager.activeTabID })
    }
    private var isHovered: Bool { hoveredNodeID == node.id }
    private var isKbSelected: Bool { kbSelectedID == node.id }

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
                .padding(.leading, CGFloat(10 + depth * 16))
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
                    SidebarNodeRow(node: child, depth: depth + 1, hoveredNodeID: $hoveredNodeID, kbSelectedID: kbSelectedID)
                }
            }
        }
    }

    private var rowBackground: Color {
        if isActive { return Color.black.opacity(0.06) }
        // Spec `kbName`: keyboard selection highlight, but never over the
        // active row — rgba(0,0,0,0.05), the project's existing hover token.
        if isKbSelected { return DesignTokens.swiftUI.hover }
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
