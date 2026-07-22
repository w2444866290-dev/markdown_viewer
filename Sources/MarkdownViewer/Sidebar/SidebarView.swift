import SwiftUI
import AppKit

/// Width bounds shared by pointer dragging and the native accessibility
/// adjustable action on the resize handle.
enum SidebarResizePolicy {
    static let accessibilityStep: CGFloat = 8

    static func clampedWidth(_ proposedWidth: CGFloat) -> CGFloat {
        max(
            DesignTokens.sidebarMinWidth,
            min(DesignTokens.sidebarMaxWidth, proposedWidth)
        )
    }
}

/// The prototype's filter field has no resting focus treatment. A focus ring is
/// therefore reserved for the macOS keyboard-traversal case, never for the
/// window's initial first responder or a pointer click.
enum SidebarFilterFocusPolicy {
    static func isKeyboardTraversal(keyCode: UInt16) -> Bool {
        keyCode == 48 // Tab / Shift-Tab
    }

    static func showsRing(
        isFocused: Bool,
        hasPendingKeyboardTraversal: Bool
    ) -> Bool {
        isFocused && hasPendingKeyboardTraversal
    }
}

/// Sidebar matching spec: 44px spacer → filter → file tree → ⌘K button.
/// Background #F7F7F8, 28px rows with hover/active states, resize handle.
struct SidebarView: View {
    @EnvironmentObject var docManager: DocumentManager
    @State private var hoveredNodeID: String?
    @State private var resizeHover = false
    @State private var resizeDragging = false
    @State private var resizeStartWidth: CGFloat = DesignTokens.sidebarWidth
    /// Kept separately from the visual hover state so a drag that leaves the
    /// narrow hit strip retains the col-resize cursor until its mouse-up.
    @State private var resizeCursorApplied = false
    @State private var paletteHover = false

    /// Spec (design L1250): while a drag is IN PROGRESS the resize line turns the
    /// macOS accent-drag blue rgba(10,132,255,0.6). LOCAL to this view - it's the
    /// only place this drag-accent appears, so it stays out of the shared tokens
    /// (mirrors FindBarView's local spec colors).
    private static let dragLine = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255).opacity(0.6)
    /// The explicit source focus treatment is local to the sidebar filter.
    private static let filterFocusRing = Color(red: 0, green: 122 / 255, blue: 1).opacity(0.45)

    // Sidebar filter query. LOCAL @State (not on the DocumentManager EnvironmentObject)
    // on purpose: only SidebarView reads it, so keeping it here means each keystroke
    // re-renders ONLY the sidebar instead of the whole ContentView tree (性能-5). The
    // filter is session-only (never persisted), so a local reset on relaunch matches
    // the previous behaviour. `filteredNodes` derives from docManager.fileTree + this.
    @State private var sideFilter: String = ""

    // Filter keyboard navigation (spec JS `onSideFilterKey` / `kbName`).
    @FocusState private var filterFocused: Bool
    @State private var filterFocusRingVisible = false
    @State private var pendingKeyboardFocusTraversal = false
    @State private var kbSel = 0
    @State private var keyMonitor: Any?
    @State private var focusMonitor: Any?

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(alignment: .leading, spacing: 0) {
                // 44px spacer for traffic lights
                Color.clear.frame(height: 44)

                // Filter — spec: plain input, no icon, padding 0 10px
                // The prototype leaves the input's placeholder at WebKit's
                // `darkgray` (#A9A9A9), while entered text uses --mv-fg.
                // Supplying the prompt separately preserves those two visual
                // roles instead of dimming the active foreground color.
                TextField(
                    "",
                    text: $sideFilter,
                    prompt: Text("筛选文档")
                        .foregroundColor(Color(red: 169 / 255, green: 169 / 255, blue: 169 / 255))
                )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundColor(DesignTokens.swiftUI.titleText)
                    .focused($filterFocused)
                    .accessibilityIdentifier("sidebar-filter")
                    .accessibilityLabel("筛选文档")
                    .accessibilityHint("输入以筛选文档。使用上下箭头选择，回车打开。")
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color.black.opacity(0.04))
                    .cornerRadius(6)
                    // Prototype focus-visible: 2 px #007AFF at 45% with a 1 px
                    // outward offset. Overlaying it keeps the 28 px control frame
                    // and the source layout's 2/12/8 parent spacing unchanged.
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(
                                filterFocusRingVisible
                                    ? Self.filterFocusRing
                                    : .clear,
                                lineWidth: 2
                            )
                            .padding(-3)
                    )
                    .padding(.top, 2)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    // Reset keyboard selection whenever the filter query changes.
                    .onChange(of: sideFilter) { _ in kbSel = 0 }
                    .onChange(of: filterFocused) { focused in
                        if focused {
                            filterFocusRingVisible = SidebarFilterFocusPolicy.showsRing(
                                isFocused: true,
                                hasPendingKeyboardTraversal: pendingKeyboardFocusTraversal
                            )
                            pendingKeyboardFocusTraversal = false
                            installKeyMonitor()
                        } else {
                            filterFocusRingVisible = false
                            removeKeyMonitor()
                        }
                    }
                    .onAppear { installFocusMonitor() }
                    .onDisappear {
                        removeKeyMonitor()
                        removeFocusMonitor()
                    }

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
                            // WebKit floors the source rgba(0,0,0,0.05) blend
                            // against #F7F7F8 to #EAEAEB. SwiftUI rounds it up
                            // at 0.05, so this equivalent compositing alpha
                            // keeps the rendered pixels at the source value.
                            .background(Color.black.opacity(0.051))
                            .cornerRadius(6)
                        Text("全部命令")
                            .font(.system(size: 11.5))
                    }
                    .foregroundColor(paletteHover
                        ? DesignTokens.swiftUI.secondaryText
                        : DesignTokens.swiftUI.paletteKbd)
                    .padding(.horizontal, 16)
                    .frame(height: 38)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    // The source flex row lands on the lower physical pixel in
                    // its 38 pt container. Preserve that shared half-point snap
                    // for the keycap and label rather than tuning either string.
                    .offset(y: 0.5)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("open-command-palette")
                .mvFocusVisible()
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
                .accessibilityValue("\(Int(docManager.sidebarWidth.rounded())) 点")
                .accessibilityHint("左右拖动以调整侧栏宽度")
                .accessibilityAdjustableAction { direction in
                    let adjustment: CGFloat
                    switch direction {
                    case .increment:
                        adjustment = SidebarResizePolicy.accessibilityStep
                    case .decrement:
                        adjustment = -SidebarResizePolicy.accessibilityStep
                    @unknown default:
                        return
                    }
                    docManager.sidebarWidth = SidebarResizePolicy.clampedWidth(
                        docManager.sidebarWidth + adjustment
                    )
                    docManager.scheduleSessionSave()
                }
                .onHover { hovering in
                    resizeHover = hovering
                    setResizeCursor(active: hovering || resizeDragging)
                }
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
                            setResizeCursor(active: true)
                            let newWidth = SidebarResizePolicy.clampedWidth(
                                resizeStartWidth + value.translation.width
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
                            let finalWidth = SidebarResizePolicy.clampedWidth(
                                startWidth + value.translation.width
                            )
                            docManager.sidebarWidth = finalWidth
                            resizeDragging = false
                            setResizeCursor(active: resizeHover)
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
        .onDisappear {
            setResizeCursor(active: false)
            removeFocusMonitor()
        }
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

    /// Observe keyboard traversal before AppKit moves the first responder. The
    /// pending value is consumed by `filterFocused` on that same interaction;
    /// it intentionally expires on the next main-loop turn when Tab moved to a
    /// different control. This is safe during SwiftUI state updates because it
    /// never asks `NSApplication` for its transient current event.
    private func installFocusMonitor() {
        guard focusMonitor == nil else { return }
        focusMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            guard SidebarFilterFocusPolicy.isKeyboardTraversal(keyCode: event.keyCode) else {
                return event
            }
            pendingKeyboardFocusTraversal = true
            DispatchQueue.main.async {
                if pendingKeyboardFocusTraversal {
                    pendingKeyboardFocusTraversal = false
                }
            }
            return event
        }
    }

    private func removeFocusMonitor() {
        if let m = focusMonitor { NSEvent.removeMonitor(m); focusMonitor = nil }
        pendingKeyboardFocusTraversal = false
    }

    /// Uses the native AppKit resize cursor and balances exactly one push/pop.
    /// This avoids turning the draggable separator into a visual-only substitute,
    /// and avoids overwriting the document's I-beam/hand cursor after mouse-up.
    private func setResizeCursor(active: Bool) {
        guard active != resizeCursorApplied else { return }
        if active {
            NSCursor.resizeLeftRight.push()
        } else {
            NSCursor.pop()
        }
        resizeCursorApplied = active
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
        // The prototype lays out the tree as one flat flex column with a 1 pt
        // gap between every visible row. Children are recursive here, so the
        // parent stack must supply that same gap before each child as well.
        // With zero spacing nested rows accumulated upward by 1 pt per level.
        VStack(alignment: .leading, spacing: 1) {
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
                            // The source's fixed-width flex child has no
                            // text-align override, so this glyph is leading
                            // aligned rather than SwiftUI's default centering.
                            .frame(width: 9, alignment: .leading)
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
                            // The row conveys this state as one accessible unit below.
                            // Keeping the decorative dot out of the child tree prevents
                            // VoiceOver from announcing a nameless second element.
                            .accessibilityHidden(true)
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
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(accessibilityHint)
            .accessibilityAddTraits(
                (isActive || isKbSelected) ? [.isButton, .isSelected] : [.isButton]
            )
            // The source attaches this title to the dirty marker. The native row
            // remains one keyboard-accessible button, so expose the same hint at
            // its hit target without adding a noninteractive visual surrogate.
            .help(nodeHasDirtyTab ? "未保存 · ⌘S 保存" : "")
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

    private var accessibilityLabel: String {
        node.isDirectory ? "文件夹 \(node.name)" : "文档 \(node.name)"
    }

    private var accessibilityValue: String {
        var states: [String] = []
        if isActive { states.append("当前文档") }
        else if isKbSelected { states.append("键盘选中") }
        if nodeHasDirtyTab { states.append("未保存") }
        return states.isEmpty ? "未选中" : states.joined(separator: "，")
    }

    private var accessibilityHint: String {
        if node.isDirectory {
            return isExpanded ? "收起文件夹" : "展开文件夹"
        }
        return "打开文档"
    }
}
