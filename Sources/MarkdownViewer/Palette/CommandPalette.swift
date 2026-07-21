import AppKit
import SwiftUI

enum PalettePresentationMetrics {
    static let idealPanelWidth: CGFloat = 460
    static let minimumHorizontalInset: CGFloat = 24
    static let topInset: CGFloat = 96
    static let searchHeight: CGFloat = 46
    static let separatorHeight: CGFloat = 1
    static let listContentMaxHeight: CGFloat = 340
    static let listPadding: CGFloat = 8
    static let veilOpacity: CGFloat = 0.6
    static let entranceDuration: TimeInterval = 0.12
    static let entranceOffset: CGFloat = 4

    static var listOuterMaxHeight: CGFloat {
        listContentMaxHeight + 2 * listPadding
    }

    static var panelMaxHeight: CGFloat {
        searchHeight + separatorHeight + listOuterMaxHeight
    }

    static func panelWidth(for containerWidth: CGFloat) -> CGFloat {
        min(idealPanelWidth, max(0, containerWidth - 2 * minimumHorizontalInset))
    }
}

enum PaletteCommandID: CaseIterable, Equatable {
    case newDocument
    case save
    case findAndReplace
    case togglePreview
    case open
    case increaseFont
    case decreaseFont
    case resetFont
    case toggleSidebar
    case reopenClosedTab
}

struct PaletteCommandDefinition: Identifiable, Equatable {
    let id: PaletteCommandID
    let title: String
    let shortcut: String
}

enum PaletteCommandCatalog {
    static let required: [PaletteCommandDefinition] = [
        .init(id: .newDocument, title: "新建文档", shortcut: "⌘N"),
        .init(id: .save, title: "保存", shortcut: "⌘S"),
        .init(id: .findAndReplace, title: "查找 / 替换", shortcut: "⌘F"),
        .init(id: .togglePreview, title: "切换纯预览 / 编辑", shortcut: "⌘⇧P"),
        .init(id: .open, title: "打开…", shortcut: "⌘O"),
        .init(id: .increaseFont, title: "放大字号", shortcut: "⌘ +"),
        .init(id: .decreaseFont, title: "缩小字号", shortcut: "⌘ -"),
        .init(id: .resetFont, title: "重置字号", shortcut: "⌘ 0"),
        .init(id: .toggleSidebar, title: "显示 / 隐藏侧栏", shortcut: "⌘\\"),
    ]

    static func commands(lastClosedName: String?) -> [PaletteCommandDefinition] {
        guard let lastClosedName else { return required }
        return required + [
            .init(
                id: .reopenClosedTab,
                title: "恢复刚关闭的标签 · \(lastClosedName)",
                shortcut: "⌘⇧T"
            )
        ]
    }
}

enum PaletteFilter {
    static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matches(_ candidate: String, query: String) -> Bool {
        let normalized = normalizedQuery(query)
        return normalized.isEmpty
            || candidate.localizedCaseInsensitiveContains(normalized)
    }
}

enum PaletteKeyCommand: Equatable {
    case moveDown
    case moveUp
    case activate
    case dismiss
}

enum PaletteKeyboard {
    static func command(
        forKeyCode keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = []
    ) -> PaletteKeyCommand? {
        if keyCode == 40,
           modifiers.contains(.command),
           modifiers.isDisjoint(with: [.shift, .control, .option]) {
            return .dismiss
        }
        switch keyCode {
        case 125: return .moveDown
        case 126: return .moveUp
        case 36, 76: return .activate
        case 53: return .dismiss
        default: return nil
        }
    }

    static func movedSelection(from index: Int, itemCount: Int, delta: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        let normalized = ((index % itemCount) + itemCount) % itemCount
        return ((normalized + delta) % itemCount + itemCount) % itemCount
    }

    static func normalizedSelection(_ index: Int, itemCount: Int) -> Int {
        movedSelection(from: index, itemCount: itemCount, delta: 0)
    }
}

struct CommandPaletteView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject var docManager: DocumentManager
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @State private var eventMonitor: Any?
    @State private var panelEntered = false
    @State private var pointingCursorIsPushed = false
    @FocusState private var searchFocused: Bool

    private var commands: [PaletteCommandDefinition] {
        PaletteCommandCatalog.commands(lastClosedName: docManager.lastClosedTab?.name)
    }

    var filteredCommands: [PaletteCommandDefinition] {
        commands.filter { PaletteFilter.matches($0.title, query: query) }
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

    /// The palette includes open tabs and unsaved untitled documents in addition
    /// to workspace files, with canonical on-disk paths deduplicated.
    private var allDocs: [PaletteDoc] {
        var result: [PaletteDoc] = []
        var consumedTabIDs = Set<UUID>()

        // Preserve the workspace's visible order and attach an already-open tab to
        // its file entry. URL-less documents remain reachable after known files.
        for node in flattenedFiles(docManager.fileTree) {
            let openTab = docManager.tabs.first { tab in
                docManager.tabRepresentsFileNode(tab, node: node)
            }
            if let openTab { consumedTabIDs.insert(openTab.id) }
            result.append(PaletteDoc(
                id: openTab.map { AnyHashable($0.id) } ?? AnyHashable(node.id),
                name: node.name,
                url: node.url,
                tabID: openTab?.id
            ))
        }
        for tab in docManager.tabs where !consumedTabIDs.contains(tab.id) {
            result.append(PaletteDoc(id: tab.id, name: tab.name, url: tab.url, tabID: tab.id))
        }
        return result
    }

    private var filteredDocs: [PaletteDoc] {
        allDocs.filter { PaletteFilter.matches($0.name, query: query) }
    }

    var totalItems: Int { filteredDocs.count + filteredCommands.count }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                // The captured reference renders this as a literal 60% veil
                // over the existing document. Do not insert an AppKit material
                // view here: in a SwiftUI overlay it composites as an opaque
                // material surface instead of sampling this document window.
                Color(red: 248/255, green: 248/255, blue: 250/255)
                    .opacity(PalettePresentationMetrics.veilOpacity)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { docManager.closeCommandPalette() }
                    .accessibilityLabel("关闭命令面板")
                    .accessibilityAddTraits(.isButton)

                VStack(spacing: 0) {
                    Spacer().frame(height: PalettePresentationMetrics.topInset)

                    VStack(spacing: 0) {
                        TextField("搜索文档或命令…", text: $query)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .foregroundColor(DesignTokens.swiftUI.titleText)
                            .padding(.horizontal, 18)
                            .frame(height: PalettePresentationMetrics.searchHeight)
                            .focused($searchFocused)
                            .onChange(of: query) { _ in
                                releasePointingCursor()
                                selectedIndex = 0
                            }

                        Rectangle()
                            .fill(DesignTokens.swiftUI.divider)
                            .frame(height: PalettePresentationMetrics.separatorHeight)

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
                                                docManager.closeCommandPalette()
                                            }
                                        )
                                    }
                                }
                                if !filteredCommands.isEmpty {
                                    let offset = filteredDocs.count
                                    sectionHeader("命令", topPadding: true)
                                    ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { idx, cmd in
                                        paletteRow(
                                            title: cmd.title,
                                            subtitle: cmd.shortcut,
                                            index: offset + idx,
                                            action: { execute(cmd.id) }
                                        )
                                    }
                                }
                                if filteredDocs.isEmpty && filteredCommands.isEmpty {
                                    Text("没有匹配的文档或命令")
                                        .font(.system(size: 12.5))
                                        .foregroundColor(DesignTokens.swiftUI.placeholderText)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 18)
                                }
                            }
                            .padding(PalettePresentationMetrics.listPadding)
                        }
                        // CSS max-height applies to its content box, with 8pt padding
                        // outside that limit. Preserve the resulting 356pt outer height.
                        .frame(maxHeight: PalettePresentationMetrics.listOuterMaxHeight)
                        .accessibilityLabel("命令面板结果")
                    }
                    .frame(width: PalettePresentationMetrics.panelWidth(for: geometry.size.width))
                    .background(DesignTokens.swiftUI.paper)
                    .cornerRadius(14)
                    .shadow(color: .black.opacity(0.22), radius: 30, x: 0, y: 24)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(DesignTokens.swiftUI.ring, lineWidth: 1)
                    )
                    .debugVisualAnchor("palette-panel-frame")
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                    .onTapGesture { searchFocused = true }
                    // `overlayIn` in the prototype animates this panel only,
                    // not the dimming veil behind it.
                    .opacity(panelEntered ? 1 : 0)
                    .offset(y: panelEntered ? 0 : -PalettePresentationMetrics.entranceOffset)

                    Spacer(minLength: 0)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            installKeyMonitor()
            panelEntered = reduceMotion
            DispatchQueue.main.async {
                MotionPolicy.perform(
                    reduceMotion: reduceMotion,
                    animation: .easeOut(duration: PalettePresentationMetrics.entranceDuration)
                ) {
                    panelEntered = true
                }
            }
            guard AppEnv.allowsAutomaticFocusRequests else { return }
            DispatchQueue.main.async { searchFocused = true }  // autofocus the field
        }
        .onChange(of: totalItems) { itemCount in
            selectedIndex = PaletteKeyboard.normalizedSelection(
                selectedIndex,
                itemCount: itemCount
            )
        }
        .onDisappear {
            panelEntered = false
            releasePointingCursor()
            removeKeyMonitor()
        }
    }

    private func execute(_ command: PaletteCommandID) {
        docManager.closeCommandPalette()
        switch command {
        case .newDocument: docManager.newDocument()
        case .save: docManager.saveCurrent()
        // The find entry always opens and focuses the panel. It never toggles it closed.
        case .findAndReplace: docManager.findStateOpen?()
        case .togglePreview: docManager.togglePreviewMode()
        case .open: docManager.openDocument()
        case .increaseFont: docManager.applyFont(docManager.fontIndex + 1)
        case .decreaseFont: docManager.applyFont(docManager.fontIndex - 1)
        case .resetFont: docManager.applyFont(1)
        case .toggleSidebar: docManager.toggleSidebar()
        case .reopenClosedTab: docManager.reopenClosed()
        }
    }

    private func activateSelected() {
        let itemCount = totalItems
        guard itemCount > 0 else { return }
        let index = PaletteKeyboard.normalizedSelection(
            selectedIndex,
            itemCount: itemCount
        )
        if index < filteredDocs.count {
            openPaletteDoc(filteredDocs[index])
        } else {
            let cmd = filteredCommands[index - filteredDocs.count]
            execute(cmd.id)
        }
        docManager.closeCommandPalette()
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
        guard eventMonitor == nil else { return }
        let handler = PaletteKeyHandler(
            onDown: {
                selectedIndex = PaletteKeyboard.movedSelection(
                    from: selectedIndex,
                    itemCount: totalItems,
                    delta: 1
                )
            },
            onUp: {
                selectedIndex = PaletteKeyboard.movedSelection(
                    from: selectedIndex,
                    itemCount: totalItems,
                    delta: -1
                )
            },
            onEnter: { if totalItems > 0 { activateSelected() } },
            onEscape: { docManager.closeCommandPalette() }
        )
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // This view is only installed while the in-window palette is
            // present. Do not require a temporary child NSPanel: keyboard
            // navigation now belongs to the owning document window as well.
            guard event.window != nil,
                  let command = PaletteKeyboard.command(
                    forKeyCode: event.keyCode,
                    modifiers: event.modifierFlags
                  ) else {
                return event
            }
            switch command {
            case .moveDown: handler.onDown()
            case .moveUp: handler.onUp()
            case .activate: handler.onEnter()
            case .dismiss: handler.onEscape()
            }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
        eventMonitor = nil
    }

    private func updatePointingCursor(_ hovering: Bool) {
        guard hovering != pointingCursorIsPushed else { return }
        pointingCursorIsPushed = hovering
        if hovering {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
    }

    private func releasePointingCursor() {
        guard pointingCursorIsPushed else { return }
        pointingCursorIsPushed = false
        NSCursor.pop()
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
                    .fill(isSelected ? Color.black.opacity(0.05) : .clear)
            )
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            // The reference explicitly uses `cursor: pointer` for command and
            // document rows. SwiftUI's plain button style preserves the visual
            // geometry but does not guarantee that cursor on macOS.
            if hovering {
                selectedIndex = index
            }
            updatePointingCursor(hovering)
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
