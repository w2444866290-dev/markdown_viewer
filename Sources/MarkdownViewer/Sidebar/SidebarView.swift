import SwiftUI
import AppKit

/// Sidebar matching spec: 44px spacer → filter → file tree → ⌘K button.
/// Background #F7F7F8, 28px rows with hover/active states, resize handle.
struct SidebarView: View {
    @EnvironmentObject var docManager: DocumentManager
    @State private var hoveredNodeID: String?
    @State private var resizeHover = false
    @State private var resizeDragging = false
    @State private var resizeStartWidth: CGFloat = DesignTokens.sidebarWidth
    @State private var paletteHover = false

    /// Spec (design L1250): while a drag is IN PROGRESS the resize line turns the
    /// macOS accent-drag blue rgba(10,132,255,0.6). LOCAL to this view - it's the
    /// only place this drag-accent appears, so it stays out of the shared tokens
    /// (mirrors FindBarView's local spec colors).
    private static let dragLine = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255).opacity(0.6)

    // Sidebar filter query. LOCAL @State (not on the DocumentManager EnvironmentObject)
    // on purpose: only SidebarView reads it, so keeping it here means each keystroke
    // re-renders ONLY the sidebar instead of the whole ContentView tree (性能-5). The
    // filter is session-only (never persisted), so a local reset on relaunch matches
    // the previous behaviour. `filteredNodes` derives from docManager.fileTree + this.
    @State private var sideFilter: String = ""

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
                TextField("筛选文档", text: $sideFilter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundColor(DesignTokens.swiftUI.titleText)
                    .focused($filterFocused)
                    .accessibilityIdentifier("sidebar-filter")
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color.black.opacity(0.04))
                    .cornerRadius(6)
                    .padding(.top, 2)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    // Reset keyboard selection whenever the filter query changes.
                    .onChange(of: sideFilter) { _ in kbSel = 0 }
                    .onChange(of: filterFocused) { focused in
                        if focused { installKeyMonitor() } else { removeKeyMonitor() }
                    }
                    .onDisappear { removeKeyMonitor() }

                // File tree — spec: padding 4px 10px 12px, gap 1px
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        // While filtering, the flat match list can contain same-named
                        // files from different folders — pass each match its parent
                        // folder path (relative to the opened root) so the row can
                        // disambiguate them. Browse mode conveys folders by
                        // indentation, so no path is passed there (`nil`).
                        let filtering = SidebarFilterPolicy.isFiltering(sideFilter)
                        ForEach(filteredNodes) { node in
                            SidebarNodeRow(
                                node: node,
                                depth: 0,
                                hoveredNodeID: $hoveredNodeID,
                                kbSelectedID: kbSelectedNodeID,
                                relativePath: filtering
                                    ? SidebarFilterPolicy.displayRelativePath(
                                        for: node,
                                        workspaceRoot: docManager.directoryURL
                                    )
                                    : nil
                            )
                        }
                        if filtering && filteredNodes.isEmpty {
                            Text("没有匹配的文档")
                                .font(.system(size: 12.5))
                                .foregroundColor(DesignTokens.swiftUI.placeholderText)
                                .frame(height: 32)
                                .padding(.horizontal, 8)
                                .accessibilityIdentifier(
                                    MarkdownAccessibilitySurface.sidebarFilterEmpty
                                )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .padding(.bottom, 8)
                }

                // ⌘K button — spec: 38px, color #9a9a9e, hover #6e6e73
                Button(action: { docManager.openCommandPalette() }) {
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
                .accessibilityIdentifier("open-command-palette")
                .onHover { paletteHover = $0 }
                .mvTip("所有命令与文档 · ⌘K")

            }
            .background(DesignTokens.swiftUI.sidebar)

            // Resize handle — spec: absolute right -4px, 9px wide, 1px line
            Color.clear
                .frame(width: 9)
                .contentShape(Rectangle())
                .allowsHitTesting(true)
                .accessibilityIdentifier("sidebar-resize-handle")
                .accessibilityLabel("调整侧栏宽度")
                .onHover { resizeHover = $0 }
                .overlay(
                    Rectangle()
                        // Three-state (spec L1250): dragging -> accent blue, hover ->
                        // subtle black line, rest -> transparent. Stays blue for the
                        // whole drag (resizeDragging) even as the cursor leaves the 9px
                        // strip, and reverts to hover/rest on release.
                        .fill(resizeDragging
                            ? Self.dragLine
                            : (resizeHover ? Color.black.opacity(0.18) : Color.clear))
                        .frame(width: 1)
                        // This line is visual only. The authoritative drag starts on
                        // its centre, so allowing it to participate in hit testing
                        // would shield the 9 pt interaction surface below it.
                        .allowsHitTesting(false)
                )
                .gesture(
                    // Global coordinates remain stable while changing the width moves
                    // this handle through the local coordinate space.
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            if !resizeDragging {
                                resizeDragging = true
                                resizeStartWidth = docManager.sidebarWidth
                                DebugPointerTrace.shared.recordSidebarResize(
                                    "sidebar-resize-began",
                                    width: resizeStartWidth
                                )
                            }
                            let newWidth = max(
                                DesignTokens.sidebarMinWidth,
                                min(DesignTokens.sidebarMaxWidth,
                                    resizeStartWidth + value.translation.width
                                )
                            )
                            docManager.sidebarWidth = newWidth
                            DebugPointerTrace.shared.recordSidebarResize(
                                "sidebar-resize-changed",
                                width: newWidth
                            )
                            // Phase-2: persist the new sidebar width (debounced, fires
                            // ~1s after the drag settles).
                            docManager.scheduleSessionSave()
                        }
                        .onEnded { value in
                            let startWidth = resizeDragging
                                ? resizeStartWidth
                                : docManager.sidebarWidth
                            let finalWidth = max(
                                DesignTokens.sidebarMinWidth,
                                min(DesignTokens.sidebarMaxWidth,
                                    startWidth + value.translation.width
                                )
                            )
                            docManager.sidebarWidth = finalWidth
                            resizeDragging = false
                            DebugPointerTrace.shared.recordSidebarResize(
                                "sidebar-resize-ended",
                                width: finalWidth
                            )
                            docManager.scheduleSessionSave()
                        }
                )
                .offset(x: 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(MarkdownAccessibilitySurface.sidebarSurface)
    }

    // Browse mode renders the nested `fileTree`; filtered mode renders a FLAT
    // list of every file (any depth) — spec `sideVisibleFiles()` filters the
    // flat `buildDefs()` list regardless of folder nesting.
    private var filteredNodes: [FileNode] {
        SidebarFilterPolicy.visibleNodes(
            in: docManager.fileTree,
            query: sideFilter,
            workspaceRoot: docManager.directoryURL
        )
    }

    // Files eligible for keyboard navigation — spec `sideVisibleFiles()`.
    // Highlight only appears while filtering (matching the spec's `kbName`,
    // which is null unless the filter query is non-empty). In filter mode
    // `filteredNodes` is already the flattened, all-files-only match list, so
    // keyboard nav traverses the same nested matches the rows display.
    private var kbVisibleFiles: [FileNode] {
        !SidebarFilterPolicy.isFiltering(sideFilter)
            ? []
            : filteredNodes.filter { !$0.isDirectory }
    }

    // The node id of the current keyboard selection, clamped to range.
    private var kbSelectedNodeID: String? {
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
    @Binding var hoveredNodeID: String?
    /// Node currently selected via filter keyboard navigation (spec `kbName`).
    let kbSelectedID: String?
    /// While filtering, the file's full path relative to the opened root is
    /// shown dimmed beside the name to distinguish same-named matches.
    /// Root files retain the prototype's leading `./`; browse mode passes nil.
    let relativePath: String?
    @EnvironmentObject var docManager: DocumentManager

    private var isExpanded: Bool { docManager.expandedFolders.contains(node.id) }
    private var isActive: Bool {
        docManager.isActiveFileNode(node)
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
                    docManager.scheduleSessionSave()
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
                        // Keep the name whole; the path hint truncates first.
                        .layoutPriority(1)
                    // Filter-only: dimmed full relative path so same-named matches
                    // are distinguishable. It stays on the row's trailing side and
                    // tail-truncates like the authoritative prototype.
                    if let relativePath, !relativePath.isEmpty {
                        Spacer(minLength: 0)
                        Text(relativePath)
                            .font(.system(size: 11.5))
                            .foregroundColor(DesignTokens.swiftUI.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(
                                maxWidth: max(
                                    0,
                                    (docManager.sidebarWidth - 20) * 0.48
                                ),
                                alignment: .trailing
                            )
                    }
                    if relativePath == nil || relativePath?.isEmpty == true {
                        Spacer()
                    }
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
            .accessibilityIdentifier(
                MarkdownAccessibilitySurface.sidebarNode(
                    url: node.url,
                    workspaceRoot: docManager.directoryURL,
                    isDirectory: node.isDirectory
                )
            )
            .onHover { hovering in
                hoveredNodeID = hovering ? node.id : nil
            }

            if node.isDirectory && isExpanded {
                ForEach(node.children) { child in
                    // Browse-mode nesting: hierarchy is shown by indentation, so
                    // nested rows never carry a path hint.
                    SidebarNodeRow(node: child, depth: depth + 1, hoveredNodeID: $hoveredNodeID, kbSelectedID: kbSelectedID, relativePath: nil)
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
        docManager.fileNodeHasDirtyTab(node)
    }
}
