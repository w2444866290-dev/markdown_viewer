import SwiftUI

struct CommandPaletteView: View {
    @EnvironmentObject var docManager: DocumentManager
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @State private var hoveredIndex: Int?
    @State private var eventMonitor: Any?
    @FocusState private var searchFocused: Bool

    private let baseCommands: [(String, String)] = [
        ("新建文档", "⌘N"), ("保存", "⌘S"), ("查找 / 替换", "⌘F"),
        ("打开…", "⌘O"), ("放大字号", "⌘ +"), ("缩小字号", "⌘ -"),
        ("重置字号", "⌘ 0"), ("显示 / 隐藏侧栏", "")
    ]

    // Reopen-last-closed command appended when a tab was recently closed.
    private var reopenCommandLabel: String? {
        guard let name = docManager.lastClosedTab?.name else { return nil }
        return "恢复刚关闭的标签 · \(name)"
    }

    private var commands: [(String, String)] {
        var cmds = baseCommands
        if let label = reopenCommandLabel {
            cmds.append((label, "⌘⇧T"))
        }
        return cmds
    }

    var filteredCommands: [(String, String)] {
        guard !query.isEmpty else { return commands }
        return commands.filter { $0.0.localizedCaseInsensitiveContains(query) }
    }

    private func flattenedFiles(_ nodes: [FileNode]) -> [FileNode] {
        var result: [FileNode] = []
        for node in nodes {
            if node.isDirectory {
                result.append(contentsOf: flattenedFiles(node.children))
            } else {
                result.append(node)
            }
        }
        return result
    }

    /// A palette-listable document: either a file on disk (FileNode) or an open
    /// tab (which may be the unsaved 未命名 doc with no URL).
    private struct PaletteDoc: Identifiable {
        let id: AnyHashable      // tab UUID or FileNode UUID
        let name: String
        let url: URL?            // nil for the unsaved untitled tab
        let tabID: UUID?         // non-nil when this entry is an open tab
    }

    /// Spec #15: the palette doc list must include open tabs and the unsaved
    /// 未命名 doc, not just files on disk. MINIMAL FIX — union docManager.tabs with
    /// the flattened fileTree, deduped by path (or by name for url-less tabs).
    /// TODO(spec #15): full buildDefs parity (extraOrder / pinning) in data-model wave.
    private var allDocs: [PaletteDoc] {
        var result: [PaletteDoc] = []
        var seenPaths = Set<String>()

        // Open tabs first (so the active/untitled doc is reachable), then disk files.
        for tab in docManager.tabs {
            if let path = tab.url?.path { seenPaths.insert(path) }
            result.append(PaletteDoc(id: tab.id, name: tab.name, url: tab.url, tabID: tab.id))
        }
        for node in flattenedFiles(docManager.fileTree) {
            if seenPaths.contains(node.url.path) { continue }
            seenPaths.insert(node.url.path)
            result.append(PaletteDoc(id: node.id, name: node.name, url: node.url, tabID: nil))
        }
        return result
    }

    private var filteredDocs: [PaletteDoc] {
        guard !query.isEmpty else { return allDocs }
        return allDocs.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var totalItems: Int { filteredDocs.count + filteredCommands.count }

    var body: some View {
        ZStack(alignment: .top) {
            // Backdrop — spec L227: rgba(248,248,250,0.6) + backdrop-filter: blur(6px).
            // The blur is supplied by the host window's NSVisualEffectView(.behindWindow)
            // (see PaletteBlurHost); this Color is only the off-white veil layered on top.
            // The visual-effect material ALSO contributes its own frost, so stacking the
            // literal 0.6 spec value on top of it compounded to near-opaque — the main
            // UI became invisible (QA P0). 0.4 here nets ≈ the spec's 0.6 over the blur
            // while keeping the softened content clearly visible behind it.
            Color(red: 248/255, green: 248/255, blue: 250/255).opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { docManager.paletteOpen = false }

            // Top-aligned: spec L227 anchors the panel 96px below the container top
            // (align-items: flex-start; padding-top: 96px). The trailing Spacer makes
            // this VStack fill the full height so the 96px gap is measured from the
            // real top — without it the VStack hugged its content and the ZStack
            // centred it, dropping the panel toward the middle (QA P0).
            VStack(spacing: 0) {
                Spacer().frame(height: 96)

                VStack(spacing: 0) {
                    // Search input — spec: height 46, border-bottom: 1px solid #F0F0F1
                    TextField("搜索文档或命令…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundColor(DesignTokens.swiftUI.titleText)
                        .padding(.horizontal, 18)
                        .frame(height: 46)
                        .focused($searchFocused)
                        .onChange(of: query) { _ in selectedIndex = 0 }

                    Rectangle()
                        .fill(DesignTokens.swiftUI.divider)
                        .frame(height: 1)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if !filteredDocs.isEmpty {
                                sectionHeader("文档", topPadding: false)
                                ForEach(Array(filteredDocs.enumerated()), id: \.element.id) { idx, doc in
                                    paletteRow(
                                        title: doc.name,
                                        subtitle: nil,
                                        index: idx,
                                        isActiveDoc: isActiveDoc(doc),
                                        action: {
                                            openPaletteDoc(doc)
                                            docManager.paletteOpen = false
                                        }
                                    )
                                }
                            }
                            if !filteredCommands.isEmpty {
                                let offset = filteredDocs.count
                                sectionHeader(
                                    filteredDocs.isEmpty ? "命令" : "命令",
                                    topPadding: !filteredDocs.isEmpty
                                )
                                ForEach(Array(filteredCommands.enumerated()), id: \.offset) { idx, cmd in
                                    paletteRow(
                                        title: cmd.0,
                                        subtitle: cmd.1,
                                        index: offset + idx,
                                        action: { execute(cmd.0) }
                                    )
                                }
                            }
                            if filteredDocs.isEmpty && filteredCommands.isEmpty && !query.isEmpty {
                                Text("没有匹配的文档或命令")
                                    .font(.system(size: 12.5))
                                    .foregroundColor(DesignTokens.swiftUI.placeholderText)
                                    .padding(18)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 340)
                }
                .frame(width: 460)
                .background(DesignTokens.swiftUI.paper)
                .cornerRadius(14)
                .shadow(color: .black.opacity(0.22), radius: 30, x: 0, y: 24)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(DesignTokens.swiftUI.ring, lineWidth: 1)
                )

                Spacer(minLength: 0)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            // Palette open is a discrete reconcile point: pull the editor's live text
            // into the active tab's snapshot so the current unsaved doc is consistent
            // here. A fresh CommandPaletteView is built on every open (PaletteBlurHost),
            // so this fires for ⌘K, the sidebar button, and the double-Shift path alike.
            docManager.reconcileActiveText()
            installKeyMonitor()
            DispatchQueue.main.async { searchFocused = true }  // autofocus the field
        }
        .onDisappear { removeKeyMonitor() }
    }

    private func execute(_ name: String) {
        docManager.paletteOpen = false
        if name.hasPrefix("恢复刚关闭的标签") {
            docManager.reopenClosed()
            return
        }
        switch name {
        case "新建文档":     docManager.newDocument()
        case "保存":         docManager.saveCurrent()
        // Spec #14: always-open (never toggle closed) — same path as ⌘F / header icon.
        case "查找 / 替换":   docManager.findStateOpen?()
        case "打开…":        docManager.openDocument()
        case "放大字号":     docManager.applyFont(docManager.fontIndex + 1)
        case "缩小字号":     docManager.applyFont(docManager.fontIndex - 1)
        case "重置字号":     docManager.applyFont(1)
        case "显示 / 隐藏侧栏": docManager.sidebarOpen.toggle()
        default: break
        }
    }

    private func activateSelected() {
        if selectedIndex < filteredDocs.count {
            openPaletteDoc(filteredDocs[selectedIndex])
        } else {
            let cmd = filteredCommands[selectedIndex - filteredDocs.count]
            execute(cmd.0)
        }
        docManager.paletteOpen = false
    }

    /// Open or re-activate a palette doc. An entry backed by an open tab just
    /// re-activates that tab (works for the url-less 未命名 doc too); a disk-only
    /// entry loads via openFileNode.
    private func openPaletteDoc(_ doc: PaletteDoc) {
        if let tabID = doc.tabID {
            // Route through activateTab so the OUTGOING tab reconciles before switch.
            docManager.activateTab(tabID)
        } else if let url = doc.url {
            docManager.openFileNode(FileNode(url: url, name: doc.name, isDirectory: false))
        }
    }

    private func installKeyMonitor() {
        let handler = PaletteKeyHandler(
            onDown: { if totalItems > 0 { selectedIndex = (selectedIndex + 1) % totalItems } },
            onUp: { if totalItems > 0 { selectedIndex = (selectedIndex - 1 + totalItems) % totalItems } },
            onEnter: { activateSelected() },
            onEscape: { docManager.paletteOpen = false }
        )
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 125: handler.onDown(); return nil
            case 126: handler.onUp(); return nil
            case 36:  handler.onEnter(); return nil
            case 53:  handler.onEscape(); return nil
            default: break
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
    }

    private func sectionHeader(_ title: String, topPadding: Bool) -> some View {
        Text(title)
            .font(.system(size: 10.5))
            .foregroundColor(DesignTokens.swiftUI.placeholderText)
            .kerning(0.5)
            .padding(.leading, 12)
            .padding(.bottom, 4)
            .padding(.top, topPadding ? 10 : 6)
    }

    // Whether this palette doc maps to the currently active tab. Matches by tab
    // id when the entry is an open tab, else by URL against the active tab's URL.
    private func isActiveDoc(_ doc: PaletteDoc) -> Bool {
        guard let activeID = docManager.activeTabID else { return false }
        if let tabID = doc.tabID { return tabID == activeID }
        guard let url = doc.url else { return false }
        return docManager.tabs.first { $0.id == activeID }?.url?.path == url.path
    }

    private func paletteRow(title: String, subtitle: String?, index: Int, isActiveDoc: Bool = false, action: @escaping () -> Void) -> some View {
        let isSelected = index == selectedIndex
        let isHovered = index == hoveredIndex

        return Button(action: action) {
            HStack(spacing: 10) {
                // Doc icon for file items
                if subtitle == nil {
                    CIcon { CustomIcons.docFile(size: NSSize(width: 11, height: 13)) }
                        .frame(width: 11, height: 13)
                }
                Text(title)
                    .font(.system(size: 13.5))
                    .foregroundColor(DesignTokens.swiftUI.titleText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if subtitle == nil, isActiveDoc {
                    Text("当前")
                        .font(.system(size: 10))
                        .foregroundColor(DesignTokens.swiftUI.placeholderText)
                }
                if let sub = subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(DesignTokens.swiftUI.placeholderText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill((isSelected || isHovered)
                        ? Color.black.opacity(0.05) : .clear)
            )
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredIndex = hovering ? index : nil
            if hovering { selectedIndex = index }
        }
    }
}

// MARK: - Key handler for palette (macOS 13 compatible)

private final class PaletteKeyHandler {
    let onDown: () -> Void
    let onUp: () -> Void
    let onEnter: () -> Void
    let onEscape: () -> Void

    init(onDown: @escaping () -> Void, onUp: @escaping () -> Void,
         onEnter: @escaping () -> Void, onEscape: @escaping () -> Void) {
        self.onDown = onDown
        self.onUp = onUp
        self.onEnter = onEnter
        self.onEscape = onEscape
    }
}
