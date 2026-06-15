import AppKit
import UniformTypeIdentifiers

enum DesignTokens {
    static let paper = NSColor(hex: 0xFFFFFF)
    static let sidebar = NSColor(hex: 0xF7F7F8)
    static let appBackground = NSColor(hex: 0xF2F2F4)
    static let codeBackground = NSColor(hex: 0xFAFAFA)
    static let titleText = NSColor(hex: 0x1D1D1F)
    static let bodyText = NSColor(hex: 0x333336)
    static let secondaryText = NSColor(hex: 0x6E6E73)
    static let tertiaryText = NSColor(hex: 0x86868B)
    static let placeholderText = NSColor(hex: 0xAEAEB2)
    static let disabledText = NSColor(hex: 0xC7C7CC)
    static let divider = NSColor(hex: 0xF0F0F1)
    static let line = NSColor(hex: 0xF4F4F5)
    static let accent = NSColor(hex: 0xE8A33D)
    static let link = NSColor(hex: 0x2A6FDB)

    static let hover = NSColor.black.withAlphaComponent(0.05)
    static let sidebarHover = NSColor.black.withAlphaComponent(0.045)
    static let pressed = NSColor.black.withAlphaComponent(0.08)
    static let selected = NSColor.black.withAlphaComponent(0.06)
    static let ring = NSColor.black.withAlphaComponent(0.05)

    static let sidebarWidth: CGFloat = 216
    static let paperWidth: CGFloat = 540
    static let tabBarHeight: CGFloat = 44
}

extension NSColor {
    convenience init(hex: Int, alpha: CGFloat = 1) {
        self.init(
            calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

final class PaperTextView: NSTextView {
    override func layout() {
        super.layout()
        updatePaperGeometry()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updatePaperGeometry()
    }

    private func updatePaperGeometry() {
        let availableWidth = max(bounds.width, 1)
        let paperWidth = min(DesignTokens.paperWidth, max(240, availableWidth - 140))
        textContainer?.widthTracksTextView = false
        textContainer?.containerSize = NSSize(width: paperWidth, height: CGFloat.greatestFiniteMagnitude)
        textContainerInset = NSSize(width: max(70, (availableWidth - paperWidth) / 2), height: 44)
    }
}

final class SidebarRowView: NSTableRowView {
    private var mouseInside = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        mouseInside = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        mouseInside = false
        needsDisplay = true
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        DesignTokens.selected.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if !isSelected && mouseInside {
            DesignTokens.sidebarHover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
    }
}

struct PaletteCommand {
    let id: String
    let title: String
    let shortcut: String
    let keywords: String
}

final class CommandPaletteSearchField: NSSearchField {
    weak var paletteView: CommandPaletteView?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125:
            paletteView?.moveSelection(delta: 1)
        case 126:
            paletteView?.moveSelection(delta: -1)
        case 36, 76:
            paletteView?.runSelected()
        case 53:
            paletteView?.cancel()
        default:
            super.keyDown(with: event)
        }
    }
}

final class CommandPaletteView: NSView, NSSearchFieldDelegate {
    private let commands: [PaletteCommand]
    private var filteredCommands: [PaletteCommand]
    private var selectedIndex = 0
    private let runCommand: (String) -> Void
    private let cancelCommand: () -> Void
    private let searchField = CommandPaletteSearchField()
    private let stack = NSStackView()

    init(commands: [PaletteCommand], runCommand: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.commands = commands
        self.filteredCommands = commands
        self.runCommand = runCommand
        self.cancelCommand = cancel
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 306))
        build()
        renderCommandRows()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    func focusSearch(in window: NSWindow?) {
        window?.makeFirstResponder(searchField)
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter(searchField.stringValue)
    }

    func moveSelection(delta: Int) {
        guard !filteredCommands.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + filteredCommands.count) % filteredCommands.count
        renderCommandRows()
    }

    func runSelected() {
        guard filteredCommands.indices.contains(selectedIndex) else { return }
        runCommand(filteredCommands[selectedIndex].id)
    }

    func cancel() {
        cancelCommand()
    }

    func setQueryForTesting(_ query: String) {
        searchField.stringValue = query
        applyFilter(query)
    }

    func moveSelectionForTesting(delta: Int) {
        moveSelection(delta: delta)
    }

    var visibleCommandIdentifiersForTesting: [String] {
        filteredCommands.map(\.id)
    }

    var selectedCommandIdentifierForTesting: String? {
        guard filteredCommands.indices.contains(selectedIndex) else { return nil }
        return filteredCommands[selectedIndex].id
    }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = DesignTokens.paper.withAlphaComponent(0.92).cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = DesignTokens.ring.cgColor

        searchField.paletteView = self
        searchField.placeholderString = "搜索命令..."
        searchField.font = NSFont.systemFont(ofSize: 14)
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = DesignTokens.divider.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "命令")
        label.font = NSFont.systemFont(ofSize: 10.5)
        label.textColor = DesignTokens.placeholderText
        label.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(searchField)
        addSubview(divider)
        addSubview(label)
        addSubview(stack)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            searchField.heightAnchor.constraint(equalToConstant: 46),

            divider.topAnchor.constraint(equalTo: searchField.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            label.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),

            stack.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        ])
    }

    private func applyFilter(_ rawQuery: String) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filteredCommands = commands
        } else {
            filteredCommands = commands.filter { command in
                let haystack = "\(command.title) \(command.shortcut) \(command.keywords)"
                return haystack.localizedCaseInsensitiveContains(query)
            }
        }
        selectedIndex = filteredCommands.isEmpty ? 0 : min(selectedIndex, filteredCommands.count - 1)
        renderCommandRows()
    }

    private func renderCommandRows() {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        if filteredCommands.isEmpty {
            let empty = NSTextField(labelWithString: "没有匹配命令")
            empty.font = NSFont.systemFont(ofSize: 13)
            empty.textColor = DesignTokens.placeholderText
            empty.alignment = .center
            empty.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(empty)
            empty.heightAnchor.constraint(equalToConstant: 64).isActive = true
            return
        }

        for (index, command) in filteredCommands.enumerated() {
            stack.addArrangedSubview(commandRow(command, isSelected: index == selectedIndex))
        }
    }

    private func commandRow(_ command: PaletteCommand, isSelected: Bool) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(runCommandButton(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(command.id)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.backgroundColor = isSelected ? DesignTokens.hover.cgColor : NSColor.clear.cgColor
        button.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: command.title)
        titleLabel.font = NSFont.systemFont(ofSize: 13.5)
        titleLabel.textColor = DesignTokens.titleText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let shortcutLabel = NSTextField(labelWithString: command.shortcut)
        shortcutLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        shortcutLabel.textColor = DesignTokens.placeholderText
        shortcutLabel.alignment = .right
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false

        button.addSubview(titleLabel)
        button.addSubview(shortcutLabel)

        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 36),
            titleLabel.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -12),
            shortcutLabel.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -12),
            shortcutLabel.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            shortcutLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])

        return button
    }

    @objc private func runCommandButton(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        runCommand(id)
    }
}

final class FileTreeNode: NSObject {
    let url: URL
    let name: String
    let relativePath: String
    let isDirectory: Bool
    let isMarkdown: Bool
    let isEditableText: Bool
    weak var parent: FileTreeNode?
    var children: [FileTreeNode]

    init(
        url: URL,
        name: String,
        relativePath: String,
        isDirectory: Bool,
        isMarkdown: Bool,
        isEditableText: Bool,
        parent: FileTreeNode?,
        children: [FileTreeNode] = []
    ) {
        self.url = url
        self.name = name
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.isMarkdown = isMarkdown
        self.isEditableText = isEditableText
        self.parent = parent
        self.children = children
    }
}

struct MarkdownSelfTestCase {
    let id: String
    let title: String
    let subtitle: String
    let bold: String
    let italic: String
    let strike: String
    let inlineCode: String
    let linkText: String
    let imageAlt: String
    let quote: String
    let unordered: String
    let ordered: String
    let taskDone: String
    let taskTodo: String
    let tableHeaders: [String]
    let tableRows: [[String]]
    let codeNeedle: String

    var markdown: String {
        let renderedTableRows = tableRows.map { "| \($0.joined(separator: " | ")) |" }.joined(separator: "\n")

        return """
        # \(title)

        这是一份用于校验 Live Markdown 编辑的文档，包含 **\(bold)**、*\(italic)*、~~\(strike)~~、`\(inlineCode)` 和 [\(linkText)](https://example.com/\(id))。

        ## \(subtitle)

        > \(quote)

        - \(unordered)
        1. \(ordered)
        - [x] \(taskDone)
        - [ ] \(taskTodo)

        | \(tableHeaders.joined(separator: " | ")) |
        | \(Array(repeating: "---", count: tableHeaders.count).joined(separator: " | ")) |
        \(renderedTableRows)

        ![\(imageAlt)](./\(id).png)

        ---

        ```swift
        print("\(codeNeedle)")
        ```
        """
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MarkdownWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MarkdownWindowController()
        windowController = controller
        configureMenu(target: controller)
        controller.showWindow()
        openStartupTargetIfNeeded(with: controller)
        NSApp.activate(ignoringOtherApps: true)

        if let outputDirectory = selfTestOutputDirectory() {
            controller.runSelfTest(outputDirectory: outputDirectory)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        windowController?.canClose() == false ? .terminateCancel : .terminateNow
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        windowController?.openExternalFile(URL(fileURLWithPath: filename)) ?? false
    }

    private func openStartupTargetIfNeeded(with controller: MarkdownWindowController) {
        guard let path = firstNonFlagArgument() else { return }
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }

        if isDirectory.boolValue {
            _ = controller.openExternalDirectory(url)
        } else {
            _ = controller.openExternalFile(url)
        }
    }

    private func firstNonFlagArgument() -> String? {
        var skipNext = false

        for argument in CommandLine.arguments.dropFirst() {
            if skipNext {
                skipNext = false
                continue
            }

            if argument == "--self-test" {
                skipNext = true
                continue
            }

            if !argument.hasPrefix("--") {
                return argument
            }
        }

        return nil
    }

    private func selfTestOutputDirectory() -> URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--self-test"),
              arguments.indices.contains(index + 1) else {
            return nil
        }

        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    private func configureMenu(target: MarkdownWindowController) {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)

        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "退出 Markdown 编辑器",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)

        let fileMenu = NSMenu(title: "文件")
        fileItem.submenu = fileMenu

        let newItem = NSMenuItem(title: "新建", action: #selector(MarkdownWindowController.newDocument(_:)), keyEquivalent: "n")
        newItem.target = target
        fileMenu.addItem(newItem)

        let openFileItem = NSMenuItem(title: "打开文件...", action: #selector(MarkdownWindowController.openFile(_:)), keyEquivalent: "o")
        openFileItem.target = target
        fileMenu.addItem(openFileItem)

        let openFolderItem = NSMenuItem(title: "打开目录...", action: #selector(MarkdownWindowController.openDirectory(_:)), keyEquivalent: "O")
        openFolderItem.keyEquivalentModifierMask = [.command, .shift]
        openFolderItem.target = target
        fileMenu.addItem(openFolderItem)

        fileMenu.addItem(.separator())

        let saveItem = NSMenuItem(title: "保存", action: #selector(MarkdownWindowController.saveDocument(_:)), keyEquivalent: "s")
        saveItem.target = target
        fileMenu.addItem(saveItem)

        let saveAsItem = NSMenuItem(title: "另存为...", action: #selector(MarkdownWindowController.saveDocumentAs(_:)), keyEquivalent: "S")
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]
        saveAsItem.target = target
        fileMenu.addItem(saveAsItem)

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)

        let viewMenu = NSMenu(title: "查看")
        viewItem.submenu = viewMenu

        let commandItem = NSMenuItem(title: "命令面板", action: #selector(MarkdownWindowController.showCommandPalette(_:)), keyEquivalent: "k")
        commandItem.target = target
        viewMenu.addItem(commandItem)

        let sidebarItem = NSMenuItem(title: "显示/隐藏侧栏", action: #selector(MarkdownWindowController.toggleSidebar(_:)), keyEquivalent: "\\")
        sidebarItem.target = target
        viewMenu.addItem(sidebarItem)

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)

        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    }
}

final class MarkdownWindowController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSTextViewDelegate, NSWindowDelegate {
    private let window: NSWindow
    private let rootView = NSView()
    private let sidebarView = NSView()
    private let directoryLabel = NSTextField(labelWithString: "未选择目录")
    private let searchField = NSSearchField()
    private let outlineView = NSOutlineView()
    private let outlineScrollView = NSScrollView()
    private let documentTitleLabel = NSTextField(labelWithString: "未命名.md")
    private let documentMetaLabel = NSTextField(labelWithString: "0 字 · 0 行")
    private let statusLabel = NSTextField(labelWithString: "就绪")
    private let tabBarView = NSView()
    private let dirtyDotView = NSView()
    private let commandButton = NSButton(title: "⌘K  全部命令", target: nil, action: nil)
    private let editorScrollView = NSScrollView()
    private let editorTextView = PaperTextView(frame: .zero)

    private var bodySplitView: NSSplitView?
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var tabBarLeftPaddingConstraint: NSLayoutConstraint?
    private var commandPanel: NSPanel?
    private var currentDirectoryURL: URL?
    private var fileTreeRoots: [FileTreeNode] = []
    private var filteredTreeRoots: [FileTreeNode] = []
    private var currentFileURL: URL?
    private var currentDocumentIsMarkdown = true
    private var lastSavedText = ""
    private var suppressSelectionHandling = false
    private var isApplyingMarkdownStyle = false
    private let debugLayout = ProcessInfo.processInfo.environment["MARKDOWN_VIEWER_DEBUG_LAYOUT"] == "1"

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        super.init()

        window.title = "Markdown 编辑器"
        window.minSize = NSSize(width: 860, height: 560)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.backgroundColor = DesignTokens.paper
        window.center()
        let initialContentSize = window.contentView?.bounds.size ?? NSSize(width: 1180, height: 760)
        rootView.frame = NSRect(origin: .zero, size: initialContentSize)
        rootView.autoresizingMask = [.width, .height]
        window.contentView = rootView
        window.delegate = self

        buildInterface()
        configureInitialDocument()
    }

    func showWindow() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editorTextView)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.logLayout("after-show")
        }
    }

    func canClose() -> Bool {
        confirmDiscardChangesIfNeeded()
    }

    func openExternalFile(_ url: URL) -> Bool {
        guard confirmDiscardChangesIfNeeded() else { return false }
        loadDocument(from: url)
        return true
    }

    func openExternalDirectory(_ url: URL) -> Bool {
        guard confirmDiscardChangesIfNeeded() else { return false }
        loadDirectory(url)
        return true
    }

    func runSelfTest(outputDirectory: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            let passed = self.performSelfTest(outputDirectory: outputDirectory)
            fflush(stdout)
            fflush(stderr)
            exit(passed ? 0 : 1)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmDiscardChangesIfNeeded()
    }

    @objc func newDocument(_ sender: Any?) {
        guard confirmDiscardChangesIfNeeded() else { return }
        currentFileURL = nil
        currentDocumentIsMarkdown = true
        editorTextView.string = "# 未命名\n\n"
        lastSavedText = ""
        applyCurrentDocumentStyling()
        updateDocumentState(status: "新文档已创建")
        editorTextView.window?.makeFirstResponder(editorTextView)
    }

    @objc func openFile(_ sender: Any?) {
        guard confirmDiscardChangesIfNeeded() else { return }

        let panel = NSOpenPanel()
        panel.title = "打开 Markdown 文档"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = markdownContentTypes()

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadDocument(from: url)
    }

    @objc func openDirectory(_ sender: Any?) {
        guard confirmDiscardChangesIfNeeded() else { return }

        let panel = NSOpenPanel()
        panel.title = "打开 Markdown 目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadDirectory(url)
    }

    @objc @discardableResult func saveDocument(_ sender: Any?) -> Bool {
        if let url = currentFileURL {
            return writeCurrentDocument(to: url)
        }

        return saveDocumentAs(sender)
    }

    @objc @discardableResult func saveDocumentAs(_ sender: Any?) -> Bool {
        let panel = NSSavePanel()
        panel.title = "保存 Markdown 文档"
        panel.nameFieldStringValue = currentFileURL?.lastPathComponent ?? "未命名.md"

        if let type = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [type]
        }

        if let currentDirectoryURL {
            panel.directoryURL = currentDirectoryURL
        }

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let success = writeCurrentDocument(to: url)
        if success {
            currentFileURL = url
            refreshDirectoryIfNeeded(selecting: url)
        }
        return success
    }

    @objc func showCommandPalette(_ sender: Any?) {
        if let commandPanel, commandPanel.isVisible {
            commandPanel.close()
            self.commandPanel = nil
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 306),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.backgroundColor = DesignTokens.paper.withAlphaComponent(0.92)
        panel.isOpaque = false
        panel.hasShadow = true
        let paletteView = buildCommandPaletteView()
        panel.contentView = paletteView

        let windowFrame = window.frame
        let panelOrigin = NSPoint(
            x: windowFrame.midX - panel.frame.width / 2,
            y: windowFrame.maxY - 122 - panel.frame.height
        )
        panel.setFrameOrigin(panelOrigin)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        paletteView.focusSearch(in: panel)
        commandPanel = panel
    }

    @objc func toggleSidebar(_ sender: Any?) {
        guard let sidebarWidthConstraint else { return }
        let shouldHide = !sidebarView.isHidden
        sidebarView.isHidden = shouldHide
        sidebarWidthConstraint.constant = shouldHide ? 0 : DesignTokens.sidebarWidth
        tabBarLeftPaddingConstraint?.constant = shouldHide ? 84 : 12
        statusLabel.stringValue = shouldHide ? "侧栏已隐藏" : "侧栏已显示"
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileTreeNode else {
            return filteredTreeRoots.count
        }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? FileTreeNode {
            return node.children[index]
        }
        return filteredTreeRoots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FileTreeNode else { return false }
        return node.isDirectory && !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?) -> Any? {
        guard let node = item as? FileTreeNode else { return nil }
        return node.name
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        SidebarRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileTreeNode else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("FileTreeCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier

        let textField: NSTextField
        if let existing = cell.textField {
            textField = existing
        } else {
            textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        textField.stringValue = node.name
        textField.font = node.isDirectory ? NSFont.systemFont(ofSize: 13, weight: .regular) : NSFont.systemFont(ofSize: 13)
        textField.textColor = node.isDirectory ? DesignTokens.placeholderText : DesignTokens.bodyText
        textField.lineBreakMode = .byTruncatingMiddle

        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionHandling else { return }

        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileTreeNode else { return }

        if node.isDirectory {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
            return
        }

        guard node.isEditableText else {
            updateDocumentState(status: "不能用文本方式打开 \(node.name)")
            return
        }

        if sameFileURL(node.url, currentFileURL) { return }

        guard confirmDiscardChangesIfNeeded() else {
            selectCurrentFileInOutline()
            return
        }

        loadDocument(from: node.url)
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFileFilter()
    }

    func textDidChange(_ notification: Notification) {
        applyCurrentDocumentStyling()
        updateDocumentState(status: "正在编辑")
    }

    private func buildCommandPaletteView() -> CommandPaletteView {
        CommandPaletteView(commands: paletteCommands) { [weak self] id in
            self?.runPaletteCommand(id)
        } cancel: { [weak self] in
            self?.closeCommandPalette()
        }
    }

    private var paletteCommands: [PaletteCommand] {
        [
            PaletteCommand(id: "new", title: "新建文档", shortcut: "⌘N", keywords: "new 新建 markdown"),
            PaletteCommand(id: "openFile", title: "打开文件", shortcut: "⌘O", keywords: "open file 打开 文件"),
            PaletteCommand(id: "openDirectory", title: "打开目录", shortcut: "⇧⌘O", keywords: "open folder directory 目录 文件夹"),
            PaletteCommand(id: "save", title: "保存", shortcut: "⌘S", keywords: "save 保存"),
            PaletteCommand(id: "saveAs", title: "另存为", shortcut: "⇧⌘S", keywords: "save as 另存"),
            PaletteCommand(id: "sidebar", title: "显示 / 隐藏侧栏", shortcut: "⌘\\", keywords: "sidebar toggle 侧栏 目录")
        ]
    }

    private func closeCommandPalette() {
        commandPanel?.close()
        commandPanel = nil
    }

    private func runPaletteCommand(_ id: String) {
        closeCommandPalette()
        switch id {
        case "new":
            newDocument(self)
        case "openFile":
            openFile(self)
        case "openDirectory":
            openDirectory(self)
        case "save":
            _ = saveDocument(self)
        case "saveAs":
            _ = saveDocumentAs(self)
        case "sidebar":
            toggleSidebar(self)
        default:
            break
        }
    }

    private func buildInterface() {
        rootView.translatesAutoresizingMaskIntoConstraints = true
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = DesignTokens.paper.cgColor

        let bodySplitView = buildBodySplitView()
        self.bodySplitView = bodySplitView

        rootView.addSubview(bodySplitView)

        NSLayoutConstraint.activate([
            bodySplitView.topAnchor.constraint(equalTo: rootView.topAnchor),
            bodySplitView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            bodySplitView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            bodySplitView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])

        DispatchQueue.main.async { [weak self] in
            self?.rootView.needsLayout = true
            self?.rootView.layoutSubtreeIfNeeded()
            self?.logLayout("after-build-interface")
        }
    }

    private func buildTopBar() -> NSView {
        let topBar = NSVisualEffectView()
        topBar.material = .headerView
        topBar.blendingMode = .withinWindow
        topBar.translatesAutoresizingMaskIntoConstraints = false

        let buttonStack = NSStackView()
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        buttonStack.addArrangedSubview(makeToolbarButton(title: "新建", symbol: "doc.badge.plus", action: #selector(newDocument(_:))))
        buttonStack.addArrangedSubview(makeToolbarButton(title: "打开文件", symbol: "doc", action: #selector(openFile(_:))))
        buttonStack.addArrangedSubview(makeToolbarButton(title: "打开目录", symbol: "folder", action: #selector(openDirectory(_:))))
        buttonStack.addArrangedSubview(makeToolbarButton(title: "保存", symbol: "square.and.arrow.down", action: #selector(saveDocument(_:))))
        buttonStack.addArrangedSubview(makeToolbarButton(title: "另存为", symbol: "square.and.arrow.down.on.square", action: #selector(saveDocumentAs(_:))))

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        titleStack.translatesAutoresizingMaskIntoConstraints = false

        documentTitleLabel.font = NSFont.boldSystemFont(ofSize: 16)
        documentTitleLabel.lineBreakMode = .byTruncatingMiddle
        documentMetaLabel.font = NSFont.systemFont(ofSize: 12)
        documentMetaLabel.textColor = .secondaryLabelColor
        titleStack.addArrangedSubview(documentTitleLabel)
        titleStack.addArrangedSubview(documentMetaLabel)

        topBar.addSubview(buttonStack)
        topBar.addSubview(titleStack)

        NSLayoutConstraint.activate([
            buttonStack.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            buttonStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            titleStack.leadingAnchor.constraint(equalTo: buttonStack.trailingAnchor, constant: 18),
            titleStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: topBar.trailingAnchor, constant: -16)
        ])

        return topBar
    }

    private func buildBodySplitView() -> NSSplitView {
        let bodySplitView = NSSplitView()
        bodySplitView.isVertical = true
        bodySplitView.dividerStyle = .thin
        bodySplitView.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = buildSidebar()
        let editorPane = buildEditorPane()

        bodySplitView.addArrangedSubview(sidebar)
        bodySplitView.addArrangedSubview(editorPane)

        let widthConstraint = sidebar.widthAnchor.constraint(equalToConstant: DesignTokens.sidebarWidth)
        widthConstraint.isActive = true
        sidebarWidthConstraint = widthConstraint
        return bodySplitView
    }

    private func buildSidebar() -> NSView {
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.wantsLayer = true
        sidebarView.layer?.backgroundColor = DesignTokens.sidebar.cgColor

        directoryLabel.font = NSFont.systemFont(ofSize: 12)
        directoryLabel.textColor = DesignTokens.secondaryText
        directoryLabel.lineBreakMode = .byTruncatingMiddle

        searchField.placeholderString = "筛选文档"
        searchField.delegate = self
        searchField.font = NSFont.systemFont(ofSize: 12.5)
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = true
        searchField.backgroundColor = NSColor.black.withAlphaComponent(0.04)
        searchField.wantsLayer = true
        searchField.layer?.cornerRadius = 6

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileTreeColumn"))
        column.title = "文件"
        column.width = 188
        column.minWidth = 160
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.headerView = nil
        outlineView.rowHeight = 28
        outlineView.style = .sourceList
        outlineView.backgroundColor = DesignTokens.sidebar
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.allowsEmptySelection = true
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.autosaveExpandedItems = false
        outlineView.selectionHighlightStyle = .regular

        outlineScrollView.documentView = outlineView
        outlineScrollView.hasVerticalScroller = true
        outlineScrollView.drawsBackground = false
        outlineScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)

        commandButton.target = self
        commandButton.action = #selector(showCommandPalette(_:))
        commandButton.bezelStyle = .regularSquare
        commandButton.isBordered = false
        commandButton.alignment = .left
        commandButton.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        commandButton.contentTintColor = DesignTokens.tertiaryText

        let topSpacer = NSView()
        topSpacer.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(topSpacer)
        stack.addArrangedSubview(directoryLabel)
        stack.addArrangedSubview(searchField)
        stack.addArrangedSubview(outlineScrollView)
        stack.addArrangedSubview(commandButton)

        topSpacer.translatesAutoresizingMaskIntoConstraints = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        outlineScrollView.translatesAutoresizingMaskIntoConstraints = false
        commandButton.translatesAutoresizingMaskIntoConstraints = false

        sidebarView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: sidebarView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: sidebarView.bottomAnchor, constant: -8),

            topSpacer.heightAnchor.constraint(equalToConstant: DesignTokens.tabBarHeight),
            topSpacer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            directoryLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            searchField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 28),
            outlineScrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            outlineScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            commandButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            commandButton.heightAnchor.constraint(equalToConstant: 38)
        ])

        return sidebarView
    }

    private func buildEditorPane() -> NSView {
        configureEditorTextView()

        editorScrollView.documentView = editorTextView
        editorScrollView.hasVerticalScroller = true
        editorScrollView.hasHorizontalScroller = false
        editorScrollView.drawsBackground = true
        editorScrollView.backgroundColor = DesignTokens.paper

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = DesignTokens.paper.cgColor

        let tabBar = buildTabBar()
        container.addSubview(editorScrollView)
        container.addSubview(tabBar)
        container.addSubview(statusLabel)

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        editorScrollView.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        statusLabel.textColor = DesignTokens.tertiaryText
        statusLabel.alignment = .right

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: container.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: DesignTokens.tabBarHeight),

            editorScrollView.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            editorScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            editorScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            editorScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            statusLabel.heightAnchor.constraint(equalToConstant: 18)
        ])

        return container
    }

    private func buildTabBar() -> NSView {
        tabBarView.translatesAutoresizingMaskIntoConstraints = false
        tabBarView.wantsLayer = true
        tabBarView.layer?.backgroundColor = DesignTokens.paper.cgColor

        let toggleButton = makeGhostIconButton(symbol: "sidebar.left", title: "显示 / 隐藏侧栏", action: #selector(toggleSidebar(_:)))
        toggleButton.toolTip = "显示 / 隐藏侧栏 · ⌘\\"

        let tabCapsule = NSView()
        tabCapsule.translatesAutoresizingMaskIntoConstraints = false
        tabCapsule.wantsLayer = true
        tabCapsule.layer?.backgroundColor = DesignTokens.hover.cgColor
        tabCapsule.layer?.cornerRadius = 6

        documentTitleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        documentTitleLabel.textColor = DesignTokens.titleText
        documentTitleLabel.lineBreakMode = .byTruncatingMiddle
        documentTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        dirtyDotView.translatesAutoresizingMaskIntoConstraints = false
        dirtyDotView.wantsLayer = true
        dirtyDotView.layer?.backgroundColor = DesignTokens.accent.cgColor
        dirtyDotView.layer?.cornerRadius = 3.5

        tabCapsule.addSubview(documentTitleLabel)
        tabCapsule.addSubview(dirtyDotView)

        let newButton = makeGhostButton(title: "＋", action: #selector(newDocument(_:)))
        newButton.toolTip = "新建文档 · ⌘N"
        let openButton = makeGhostButton(title: "打开", action: #selector(openFile(_:)))
        openButton.toolTip = "打开文件 · ⌘O"
        let commandTopButton = makeGhostButton(title: "⌘K", action: #selector(showCommandPalette(_:)))
        commandTopButton.toolTip = "所有命令与文档 · ⌘K"

        [toggleButton, tabCapsule, newButton, openButton, commandTopButton].forEach {
            tabBarView.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        let toggleLeading = toggleButton.leadingAnchor.constraint(equalTo: tabBarView.leadingAnchor, constant: 12)
        tabBarLeftPaddingConstraint = toggleLeading

        NSLayoutConstraint.activate([
            toggleLeading,
            toggleButton.centerYAnchor.constraint(equalTo: tabBarView.centerYAnchor),
            toggleButton.widthAnchor.constraint(equalToConstant: 26),
            toggleButton.heightAnchor.constraint(equalToConstant: 26),

            tabCapsule.leadingAnchor.constraint(equalTo: toggleButton.trailingAnchor, constant: 8),
            tabCapsule.centerYAnchor.constraint(equalTo: tabBarView.centerYAnchor),
            tabCapsule.heightAnchor.constraint(equalToConstant: 28),
            tabCapsule.widthAnchor.constraint(greaterThanOrEqualToConstant: 118),
            tabCapsule.widthAnchor.constraint(lessThanOrEqualToConstant: 240),

            documentTitleLabel.leadingAnchor.constraint(equalTo: tabCapsule.leadingAnchor, constant: 12),
            documentTitleLabel.centerYAnchor.constraint(equalTo: tabCapsule.centerYAnchor),
            documentTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: dirtyDotView.leadingAnchor, constant: -8),

            dirtyDotView.trailingAnchor.constraint(equalTo: tabCapsule.trailingAnchor, constant: -10),
            dirtyDotView.centerYAnchor.constraint(equalTo: tabCapsule.centerYAnchor),
            dirtyDotView.widthAnchor.constraint(equalToConstant: 7),
            dirtyDotView.heightAnchor.constraint(equalToConstant: 7),

            newButton.leadingAnchor.constraint(equalTo: tabCapsule.trailingAnchor, constant: 2),
            newButton.centerYAnchor.constraint(equalTo: tabBarView.centerYAnchor),
            newButton.widthAnchor.constraint(equalToConstant: 26),
            newButton.heightAnchor.constraint(equalToConstant: 26),

            commandTopButton.trailingAnchor.constraint(equalTo: tabBarView.trailingAnchor, constant: -12),
            commandTopButton.centerYAnchor.constraint(equalTo: tabBarView.centerYAnchor),
            commandTopButton.widthAnchor.constraint(equalToConstant: 42),
            commandTopButton.heightAnchor.constraint(equalToConstant: 26),

            openButton.trailingAnchor.constraint(equalTo: commandTopButton.leadingAnchor, constant: -4),
            openButton.centerYAnchor.constraint(equalTo: tabBarView.centerYAnchor),
            openButton.widthAnchor.constraint(equalToConstant: 44),
            openButton.heightAnchor.constraint(equalToConstant: 26)
        ])

        return tabBarView
    }

    private func configureEditorTextView() {
        editorTextView.delegate = self
        editorTextView.frame = NSRect(x: 0, y: 0, width: 860, height: 640)
        editorTextView.isRichText = false
        editorTextView.importsGraphics = false
        editorTextView.allowsUndo = true
        editorTextView.font = LiveMarkdownStyler.bodyFont
        editorTextView.textColor = DesignTokens.bodyText
        editorTextView.backgroundColor = DesignTokens.paper
        editorTextView.insertionPointColor = DesignTokens.titleText
        editorTextView.textContainerInset = NSSize(width: 70, height: 44)
        editorTextView.isAutomaticQuoteSubstitutionEnabled = false
        editorTextView.isAutomaticDashSubstitutionEnabled = false
        editorTextView.isAutomaticTextReplacementEnabled = false
        editorTextView.isVerticallyResizable = true
        editorTextView.isHorizontallyResizable = false
        editorTextView.autoresizingMask = [.width]
        editorTextView.textContainer?.widthTracksTextView = false
        editorTextView.textContainer?.containerSize = NSSize(width: DesignTokens.paperWidth, height: CGFloat.greatestFiniteMagnitude)
        editorTextView.linkTextAttributes = [
            .foregroundColor: DesignTokens.link,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
    }

    private func configureInitialDocument() {
        currentDocumentIsMarkdown = true
        editorTextView.string = "# 未命名\n\n"
        lastSavedText = editorTextView.string
        applyFileFilter()
        applyCurrentDocumentStyling()
        updateDocumentState(status: "就绪")
    }

    private func makeToolbarButton(title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.controlSize = .regular
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.setButtonType(.momentaryPushIn)
        return button
    }

    private func makeGhostButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.font = NSFont.systemFont(ofSize: 12.5)
        button.contentTintColor = DesignTokens.tertiaryText
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.backgroundColor = NSColor.clear.cgColor
        return button
    }

    private func makeGhostIconButton(symbol: String, title: String, action: Selector) -> NSButton {
        let button = makeGhostButton(title: "", action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageOnly
        return button
    }

    private func loadDirectory(_ url: URL) {
        currentDirectoryURL = url
        directoryLabel.stringValue = url.lastPathComponent
        fileTreeRoots = buildFileTree(in: url)
        applyFileFilter()
        updateDocumentState(status: "找到 \(countEditableTextFiles(in: fileTreeRoots)) 个可编辑文本文件")

        if let first = firstEditableTextFile(in: fileTreeRoots) {
            loadDocument(from: first.url)
        }
    }

    private func loadDocument(from url: URL) {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            currentFileURL = url
            currentDocumentIsMarkdown = isMarkdownFile(url)
            editorTextView.string = text
            lastSavedText = text
            applyCurrentDocumentStyling()
            updateDocumentState(status: "已打开 \(url.lastPathComponent)")
            selectCurrentFileInOutline()
        } catch {
            showAlert(title: "无法打开文件", message: error.localizedDescription)
            updateDocumentState(status: "打开失败")
        }
    }

    private func writeCurrentDocument(to url: URL) -> Bool {
        do {
            let text = editorTextView.string
            try text.write(to: url, atomically: true, encoding: .utf8)
            currentFileURL = url
            lastSavedText = text
            updateDocumentState(status: "已保存 \(url.lastPathComponent)")
            return true
        } catch {
            showAlert(title: "保存失败", message: error.localizedDescription)
            updateDocumentState(status: "保存失败")
            return false
        }
    }

    private func refreshDirectoryIfNeeded(selecting url: URL) {
        guard let currentDirectoryURL else { return }

        fileTreeRoots = buildFileTree(in: currentDirectoryURL)
        applyFileFilter()
        selectCurrentFileInOutline()
    }

    private func applyFileFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if query.isEmpty {
            filteredTreeRoots = fileTreeRoots
        } else {
            filteredTreeRoots = fileTreeRoots.compactMap { node in
                filteredClone(of: node, matching: query, parent: nil)
            }
        }

        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        selectCurrentFileInOutline()
    }

    private func selectCurrentFileInOutline() {
        suppressSelectionHandling = true
        defer { suppressSelectionHandling = false }

        guard let currentFileURL,
              let node = findNode(with: currentFileURL, in: filteredTreeRoots) else {
            outlineView.deselectAll(nil)
            return
        }

        expandParents(of: node)
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    private func buildFileTree(in directoryURL: URL) -> [FileTreeNode] {
        let fileManager = FileManager.default
        let basePath = directoryURL.standardizedFileURL.path
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isPackageKey]

        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let nodes = urls.compactMap { url in
            buildFileTreeNode(url: url, basePath: basePath, parent: nil)
        }

        return nodes.sorted(by: compareFileTreeNodes)
    }

    private func buildFileTreeNode(url: URL, basePath: String, parent: FileTreeNode?) -> FileTreeNode? {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey]) else {
            return nil
        }

        if values.isPackage == true {
            return nil
        }

        let isDirectory = values.isDirectory == true
        let isRegularFile = values.isRegularFile == true

        if isDirectory {
            let node = FileTreeNode(
                url: url,
                name: url.lastPathComponent,
                relativePath: relativePath(for: url, basePath: basePath),
                isDirectory: true,
                isMarkdown: false,
                isEditableText: false,
                parent: parent
            )
            let childURLs = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            node.children = childURLs.compactMap { childURL in
                buildFileTreeNode(url: childURL, basePath: basePath, parent: node)
            }.sorted(by: compareFileTreeNodes)
            return node
        }

        guard isRegularFile, isBrowsableTextFile(url) else { return nil }

        return FileTreeNode(
            url: url,
            name: url.lastPathComponent,
            relativePath: relativePath(for: url, basePath: basePath),
            isDirectory: false,
            isMarkdown: isMarkdownFile(url),
            isEditableText: isEditableTextFile(url),
            parent: parent
        )
    }

    private func relativePath(for url: URL, basePath: String) -> String {
        let standardizedPath = url.standardizedFileURL.path
        if standardizedPath.hasPrefix(basePath + "/") {
            return String(standardizedPath.dropFirst(basePath.count + 1))
        }
        return url.lastPathComponent
    }

    private func compareFileTreeNodes(_ lhs: FileTreeNode, _ rhs: FileTreeNode) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory && !rhs.isDirectory
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private func filteredClone(of node: FileTreeNode, matching query: String, parent: FileTreeNode?) -> FileTreeNode? {
        let childClones = node.children.compactMap { child in
            filteredClone(of: child, matching: query, parent: nil)
        }
        let matches = node.name.lowercased().contains(query) || node.relativePath.lowercased().contains(query)
        guard matches || !childClones.isEmpty else { return nil }

        let clone = FileTreeNode(
            url: node.url,
            name: node.name,
            relativePath: node.relativePath,
            isDirectory: node.isDirectory,
            isMarkdown: node.isMarkdown,
            isEditableText: node.isEditableText,
            parent: parent
        )
        clone.children = childClones
        clone.children.forEach { $0.parent = clone }
        return clone
    }

    private func findNode(with url: URL, in nodes: [FileTreeNode]) -> FileTreeNode? {
        for node in nodes {
            if sameFileURL(node.url, url) {
                return node
            }
            if let found = findNode(with: url, in: node.children) {
                return found
            }
        }
        return nil
    }

    private func findNode(relativePath: String, in nodes: [FileTreeNode]) -> FileTreeNode? {
        for node in nodes {
            if node.relativePath == relativePath {
                return node
            }
            if let found = findNode(relativePath: relativePath, in: node.children) {
                return found
            }
        }
        return nil
    }

    private func sameFileURL(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    private func expandParents(of node: FileTreeNode) {
        var parent = node.parent
        while let current = parent {
            outlineView.expandItem(current)
            parent = current.parent
        }
    }

    private func firstEditableTextFile(in nodes: [FileTreeNode]) -> FileTreeNode? {
        for node in nodes {
            if node.isEditableText {
                return node
            }
        }

        for node in nodes {
            if let found = firstEditableTextFile(in: node.children) {
                return found
            }
        }
        return nil
    }

    private func countEditableTextFiles(in nodes: [FileTreeNode]) -> Int {
        nodes.reduce(0) { partial, node in
            partial + (node.isEditableText ? 1 : 0) + countEditableTextFiles(in: node.children)
        }
    }

    private func isMarkdownFile(_ url: URL) -> Bool {
        let supportedExtensions = ["md", "markdown", "mdown", "mkd"]
        return supportedExtensions.contains(url.pathExtension.lowercased())
    }

    private func isBrowsableTextFile(_ url: URL) -> Bool {
        isEditableTextFile(url)
    }

    private func isEditableTextFile(_ url: URL) -> Bool {
        if isMarkdownFile(url) { return true }
        let supportedExtensions = [
            "txt", "text", "yaml", "yml", "json", "toml", "ini", "conf", "config", "env",
            "xml", "html", "css", "js", "jsx", "ts", "tsx", "py", "swift", "sh", "bash",
            "zsh", "rb", "go", "rs", "java", "kt", "c", "h", "cpp", "hpp"
        ]
        return supportedExtensions.contains(url.pathExtension.lowercased())
    }

    private func markdownContentTypes() -> [UTType] {
        var types: [UTType] = []

        for ext in ["md", "markdown", "mdown", "mkd", "txt"] {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }

        return types
    }

    private func confirmDiscardChangesIfNeeded() -> Bool {
        guard isDirty else { return true }

        let alert = NSAlert()
        alert.messageText = "当前文档尚未保存"
        alert.informativeText = "你可以先保存，也可以放弃这些修改。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveDocument(nil)
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    private var isDirty: Bool {
        editorTextView.string != lastSavedText
    }

    private func updateDocumentState(status: String? = nil) {
        let text = editorTextView.string
        let characterCount = text.count
        let lineCount = text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
        let name = currentFileURL?.lastPathComponent ?? "未命名.md"
        let dirtyPrefix = isDirty ? "• " : ""

        documentTitleLabel.stringValue = name
        documentMetaLabel.stringValue = "\(characterCount) 字 · \(lineCount) 行"
        window.title = "\(dirtyPrefix)\(name) - Markdown 编辑器"
        dirtyDotView.isHidden = !isDirty

        if let status {
            if status.contains("已保存") || status.contains("已打开") || status.contains("自测") || status == "就绪" || status == "正在编辑" {
                statusLabel.stringValue = "\(characterCount) 字 · \(lineCount) 行"
            } else {
                statusLabel.stringValue = status
            }
        } else {
            statusLabel.stringValue = "\(characterCount) 字 · \(lineCount) 行"
        }
    }

    private func applyCurrentDocumentStyling() {
        if currentDocumentIsMarkdown {
            applyLiveMarkdownStyling()
        } else {
            applyPlainTextStyling()
        }
    }

    private func applyLiveMarkdownStyling() {
        guard !isApplyingMarkdownStyle else { return }
        guard let textStorage = editorTextView.textStorage else { return }

        isApplyingMarkdownStyle = true
        let selectedRanges = editorTextView.selectedRanges
        LiveMarkdownStyler.apply(to: textStorage)
        editorTextView.selectedRanges = selectedRanges
        editorTextView.typingAttributes = LiveMarkdownStyler.typingAttributes()
        isApplyingMarkdownStyle = false
    }

    private func applyPlainTextStyling() {
        guard !isApplyingMarkdownStyle else { return }
        guard let textStorage = editorTextView.textStorage else { return }

        isApplyingMarkdownStyle = true
        let selectedRanges = editorTextView.selectedRanges
        let attrs = plainTextAttributes()
        if textStorage.length > 0 {
            textStorage.setAttributes(attrs, range: NSRange(location: 0, length: textStorage.length))
        }
        editorTextView.selectedRanges = selectedRanges
        editorTextView.typingAttributes = attrs
        isApplyingMarkdownStyle = false
    }

    private func plainTextAttributes() -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = 4
        return [
            .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
            .foregroundColor: DesignTokens.bodyText,
            .paragraphStyle: style
        ]
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func logLayout(_ label: String) {
        guard debugLayout else { return }
        rootView.layoutSubtreeIfNeeded()
        let lines = [
            "[MarkdownViewer][\(label)] window.frame=\(window.frame)",
            "[MarkdownViewer][\(label)] contentLayoutRect=\(window.contentLayoutRect)",
            "[MarkdownViewer][\(label)] root.frame=\(rootView.frame)",
            "[MarkdownViewer][\(label)] sidebar.frame=\(sidebarView.frame)",
            "[MarkdownViewer][\(label)] editorScroll.frame=\(editorScrollView.frame)",
            "[MarkdownViewer][\(label)] editor.frame=\(editorTextView.frame)"
        ]
        fputs(lines.joined(separator: "\n") + "\n", stderr)
    }

    private func performSelfTest(outputDirectory: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            fputs("[MarkdownViewer][self-test] cannot create output directory: \(error.localizedDescription)\n", stderr)
            return false
        }

        var failures: [String] = []
        failures.append(contentsOf: validateDirectoryTreeSelfTest(outputDirectory: outputDirectory))
        failures.append(contentsOf: validateDesignSystemLayout())
        failures.append(contentsOf: validateCommandPalette())

        let cases = selfTestCases()

        for (index, testCase) in cases.enumerated() {
            currentFileURL = nil
            currentDocumentIsMarkdown = true
            editorTextView.string = testCase.markdown
            lastSavedText = editorTextView.string
            applyLiveMarkdownStyling()
            updateDocumentState(status: "Live Markdown 自测 \(index + 1)/\(cases.count)")

            rootView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            logLayout("self-test-\(testCase.id)")
            writeSnapshot(named: "snapshot-\(testCase.id).png", outputDirectory: outputDirectory)

            failures.append(contentsOf: validateSelfTestCase(testCase, index: index))
        }

        if failures.isEmpty {
            print("[MarkdownViewer][self-test] PASS cases=\(cases.count) root=\(rootView.bounds) sidebar=\(sidebarView.frame) editor=\(editorScrollView.frame) liveStyling=ok")
            return true
        }

        fputs("[MarkdownViewer][self-test] FAIL\n" + failures.joined(separator: "\n") + "\n", stderr)
        return false
    }

    private func validateDesignSystemLayout() -> [String] {
        var failures: [String] = []
        let prefix = "[design-system]"
        rootView.layoutSubtreeIfNeeded()

        if abs(sidebarView.frame.width - DesignTokens.sidebarWidth) > 2 && !sidebarView.isHidden {
            failures.append("\(prefix) sidebar width should be \(DesignTokens.sidebarWidth), got \(sidebarView.frame.width)")
        }
        if abs(tabBarView.frame.height - DesignTokens.tabBarHeight) > 1 {
            failures.append("\(prefix) tab bar height should be \(DesignTokens.tabBarHeight), got \(tabBarView.frame.height)")
        }
        if let textContainer = editorTextView.textContainer,
           abs(textContainer.containerSize.width - DesignTokens.paperWidth) > 2 {
            failures.append("\(prefix) paper width should be \(DesignTokens.paperWidth), got \(textContainer.containerSize.width)")
        }
        if commandButton.superview == nil {
            failures.append("\(prefix) sidebar command palette entry is missing")
        }
        if editorTextView.backgroundColor != DesignTokens.paper {
            failures.append("\(prefix) editor background should be paper white")
        }
        guard let tabBarLeftPaddingConstraint else {
            failures.append("\(prefix) missing tab bar left padding constraint")
            return failures
        }
        if !sidebarView.isHidden {
            toggleSidebar(self)
            rootView.layoutSubtreeIfNeeded()
            if abs(tabBarLeftPaddingConstraint.constant - 84) > 1 {
                failures.append("\(prefix) collapsed sidebar should leave 84px for traffic lights, got \(tabBarLeftPaddingConstraint.constant)")
            }
            toggleSidebar(self)
            rootView.layoutSubtreeIfNeeded()
        }
        if !sidebarView.isHidden && abs(tabBarLeftPaddingConstraint.constant - 12) > 1 {
            failures.append("\(prefix) expanded sidebar tab padding should be 12px, got \(tabBarLeftPaddingConstraint.constant)")
        }

        return failures
    }

    private func validateCommandPalette() -> [String] {
        var failures: [String] = []
        let prefix = "[command-palette]"
        let palette = buildCommandPaletteView()
        let identifiers = collectButtonIdentifiers(in: palette)
        for expected in ["new", "openFile", "openDirectory", "save", "saveAs", "sidebar"] {
            if !identifiers.contains(expected) {
                failures.append("\(prefix) missing command \(expected)")
            }
        }
        if palette.frame.width != 460 {
            failures.append("\(prefix) wrong palette width: \(palette.frame.width)")
        }
        palette.setQueryForTesting("目录")
        if palette.visibleCommandIdentifiersForTesting != ["openDirectory", "sidebar"] {
            failures.append("\(prefix) search for directory should find openDirectory and sidebar, got \(palette.visibleCommandIdentifiersForTesting)")
        }
        palette.moveSelectionForTesting(delta: 1)
        if palette.selectedCommandIdentifierForTesting != "sidebar" {
            failures.append("\(prefix) arrow navigation should select sidebar after moving down")
        }
        palette.setQueryForTesting("另存")
        if palette.visibleCommandIdentifiersForTesting != ["saveAs"] {
            failures.append("\(prefix) search for save as should find saveAs, got \(palette.visibleCommandIdentifiersForTesting)")
        }
        palette.setQueryForTesting("zz-no-match")
        if !palette.visibleCommandIdentifiersForTesting.isEmpty {
            failures.append("\(prefix) empty search should have no commands")
        }
        return failures
    }

    private func collectButtonIdentifiers(in view: NSView) -> Set<String> {
        var result = Set<String>()
        if let button = view as? NSButton, let id = button.identifier?.rawValue {
            result.insert(id)
        }
        for subview in view.subviews {
            result.formUnion(collectButtonIdentifiers(in: subview))
        }
        return result
    }

    private func validateDirectoryTreeSelfTest(outputDirectory: URL) -> [String] {
        var failures: [String] = []
        let prefix = "[directory-tree]"
        let fixtureRoot = outputDirectory.appendingPathComponent("directory-tree-fixture", isDirectory: true)
        let skillRoot = fixtureRoot.appendingPathComponent("alarm-investigation-loop", isDirectory: true)
        let agentsRoot = skillRoot.appendingPathComponent("agents", isDirectory: true)
        let skillURL = skillRoot.appendingPathComponent("SKILL.md")
        let yamlURL = agentsRoot.appendingPathComponent("openai.yaml")
        let nestedMarkdownURL = agentsRoot.appendingPathComponent("README.md")

        do {
            try FileManager.default.removeItem(at: fixtureRoot)
        } catch {
            if FileManager.default.fileExists(atPath: fixtureRoot.path) {
                failures.append("\(prefix) cannot reset fixture: \(error.localizedDescription)")
                return failures
            }
        }

        do {
            try FileManager.default.createDirectory(at: agentsRoot, withIntermediateDirectories: true)
            try "# Alarm Investigation Loop\n\n| 项 | 值 |\n| --- | --- |\n| agents | openai.yaml |\n".write(to: skillURL, atomically: true, encoding: .utf8)
            try "name: openai\nmodel: gpt-test\n".write(to: yamlURL, atomically: true, encoding: .utf8)
            try "# Nested Agent Notes\n\n- yaml visible\n".write(to: nestedMarkdownURL, atomically: true, encoding: .utf8)
        } catch {
            failures.append("\(prefix) cannot create fixture: \(error.localizedDescription)")
            return failures
        }

        loadDirectory(skillRoot)
        rootView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        writeSnapshot(named: "snapshot-directory-tree.png", outputDirectory: outputDirectory)

        if directoryLabel.stringValue != "alarm-investigation-loop" {
            failures.append("\(prefix) wrong directory label: \(directoryLabel.stringValue)")
        }
        if !sameFileURL(currentFileURL, skillURL) {
            failures.append("\(prefix) should auto-open top-level SKILL.md before nested yaml")
        }
        if currentDocumentIsMarkdown == false {
            failures.append("\(prefix) SKILL.md should be treated as markdown")
        }
        if findNode(relativePath: "agents", in: filteredTreeRoots)?.isDirectory != true {
            failures.append("\(prefix) agents directory is not visible")
        }
        if findNode(relativePath: "agents/openai.yaml", in: filteredTreeRoots)?.isEditableText != true {
            failures.append("\(prefix) agents/openai.yaml is not visible as editable text")
        }
        if findNode(relativePath: "agents/README.md", in: filteredTreeRoots)?.isMarkdown != true {
            failures.append("\(prefix) nested markdown file is not visible")
        }

        if let yamlNode = findNode(relativePath: "agents/openai.yaml", in: filteredTreeRoots) {
            expandParents(of: yamlNode)
            let row = outlineView.row(forItem: yamlNode)
            if row < 0 {
                failures.append("\(prefix) openai.yaml has no visible outline row")
            } else {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                if !sameFileURL(currentFileURL, yamlURL) {
                    failures.append("\(prefix) selecting openai.yaml did not open it")
                }
                if currentDocumentIsMarkdown {
                    failures.append("\(prefix) yaml should be opened as plain text")
                }
                if !editorTextView.string.contains("model: gpt-test") {
                    failures.append("\(prefix) yaml content was not loaded")
                }
                editorTextView.string += "owner: self-test\n"
                applyCurrentDocumentStyling()
                if !saveDocument(nil) {
                    failures.append("\(prefix) saving edited yaml failed")
                } else {
                    let savedText = (try? String(contentsOf: yamlURL, encoding: .utf8)) ?? ""
                    if !savedText.contains("owner: self-test") {
                        failures.append("\(prefix) saved yaml content was not persisted")
                    }
                }
            }
        }

        searchField.stringValue = "openai"
        applyFileFilter()
        if findNode(relativePath: "agents/openai.yaml", in: filteredTreeRoots) == nil {
            failures.append("\(prefix) search cannot find nested yaml file")
        }
        if findNode(relativePath: "SKILL.md", in: filteredTreeRoots) != nil {
            failures.append("\(prefix) search should hide unrelated root markdown file")
        }
        searchField.stringValue = ""
        applyFileFilter()

        return failures
    }

    private func selfTestCases() -> [MarkdownSelfTestCase] {
        [
            MarkdownSelfTestCase(
                id: "cycle-a",
                title: "知识边界检查",
                subtitle: "资料可信度",
                bold: "Knowledge Cutoff",
                italic: "谨慎措辞",
                strike: "绝对保证",
                inlineCode: "source_id",
                linkText: "证据链接",
                imageAlt: "架构示意图",
                quote: "没有来源的结论需要降级展示。",
                unordered: "核对发布时间",
                ordered: "记录来源",
                taskDone: "表格渲染",
                taskTodo: "截图复核",
                tableHeaders: ["缺陷", "解释", "黑话名"],
                tableRows: [
                    ["知识会过期", "模型只学到训练截止日期之前的资料", "Knowledge Cutoff"],
                    ["会一本正经地胡说", "接龙接得太顺，没资料时它会编出很真的答案", "Hallucination"],
                    ["不给来源", "它说的话你无法核实，因为它自己也不知道这句话从哪学来的", "Source Missing"]
                ],
                codeNeedle: "verify evidence"
            ),
            MarkdownSelfTestCase(
                id: "cycle-b",
                title: "旅行清单",
                subtitle: "轻装计划",
                bold: "证件",
                italic: "雨具",
                strike: "超重行李",
                inlineCode: "carry_on",
                linkText: "行程单",
                imageAlt: "路线草图",
                quote: "先订可取消，再确认天气。",
                unordered: "护照和充电器",
                ordered: "同步离线地图",
                taskDone: "酒店确认",
                taskTodo: "换少量现金",
                tableHeaders: ["物品", "用途", "状态"],
                tableRows: [
                    ["相机", "记录长途旅行里的风景和票据", "已装包"],
                    ["雨衣", "山区天气突然变化时保持干爽", "待购买"],
                    ["充电宝", "给手机、耳机和手表续航", "已充满"]
                ],
                codeNeedle: "pack light"
            ),
            MarkdownSelfTestCase(
                id: "cycle-c",
                title: "发布检查",
                subtitle: "回归项目",
                bold: "签名",
                italic: "兼容性",
                strike: "手工猜测",
                inlineCode: "codesign",
                linkText: "构建日志",
                imageAlt: "发布截图",
                quote: "连续三次不同样例通过才允许发布。",
                unordered: "验证 Universal 架构",
                ordered: "打包 zip",
                taskDone: "自测脚本",
                taskTodo: "用户复验",
                tableHeaders: ["检查项", "命令", "结果"],
                tableRows: [
                    ["Info.plist", "plutil -lint outputs/MarkdownViewer.app", "OK"],
                    ["签名", "codesign --verify --deep --strict", "OK"],
                    ["架构", "lipo -info MarkdownViewer", "Universal"]
                ],
                codeNeedle: "ship it"
            )
        ]
    }

    private func validateSelfTestCase(_ testCase: MarkdownSelfTestCase, index: Int) -> [String] {
        var failures: [String] = []
        let prefix = "[case \(index + 1) \(testCase.id)]"

        if rootView.bounds.height < 650 {
            failures.append("\(prefix) root view height too small: \(rootView.bounds.height)")
        }
        if sidebarView.frame.height < 600 {
            failures.append("\(prefix) sidebar height too small: \(sidebarView.frame.height)")
        }
        if editorScrollView.frame.width < 700 {
            failures.append("\(prefix) live editor width too small: \(editorScrollView.frame.width)")
        }
        if !editorTextView.isEditable {
            failures.append("\(prefix) live editor is not editable")
        }
        if !editorTextView.string.contains("**\(testCase.bold)**") {
            failures.append("\(prefix) raw bold markdown markers were lost")
        }
        if !hasHeadingStyle(for: testCase.title) {
            failures.append("\(prefix) heading style was not applied")
        }
        if !hasHiddenHeadingMarker() {
            failures.append("\(prefix) heading marker is still visible")
        }
        if !hasBoldStyle(for: testCase.bold) {
            failures.append("\(prefix) bold inline style was not applied")
        }
        if !hasItalicStyle(for: testCase.italic) {
            failures.append("\(prefix) italic inline style was not applied")
        }
        if !hasStrikethroughStyle(for: testCase.strike) {
            failures.append("\(prefix) strikethrough style was not applied")
        }
        if !hasLinkStyle(for: testCase.linkText) {
            failures.append("\(prefix) link style was not applied")
        }
        if !hasMonospaceStyle(for: testCase.codeNeedle) {
            failures.append("\(prefix) fenced code style was not applied")
        }
        if !hasMonospaceStyle(for: testCase.inlineCode) {
            failures.append("\(prefix) inline code style was not applied")
        }
        if !hasQuoteStyle(for: testCase.quote) {
            failures.append("\(prefix) quote style was not applied")
        }
        if !hasHiddenQuoteMarker(for: testCase.quote) {
            failures.append("\(prefix) quote marker is still visible")
        }
        if !hasTableHeaderStyle(for: testCase.tableHeaders[0]) {
            failures.append("\(prefix) table header style was not applied")
        }
        if !hasAlignedTableColumns(headers: testCase.tableHeaders, rows: testCase.tableRows) {
            failures.append("\(prefix) table columns are not visually aligned")
        }
        if !hasHiddenTableSeparator() {
            failures.append("\(prefix) table separator row is still visible")
        }
        if !hasHiddenTablePipes() {
            failures.append("\(prefix) table pipes are still visible")
        }
        if !hasHiddenMarkup("**") {
            failures.append("\(prefix) bold markdown markers are still visible")
        }
        if !hasHiddenMarkup("`\(testCase.inlineCode)`", content: testCase.inlineCode) {
            failures.append("\(prefix) inline code backticks are still visible")
        }
        if !hasHiddenLinkDestination(for: testCase.linkText) {
            failures.append("\(prefix) link destination is still visible")
        }
        if !hasHiddenHorizontalRule() {
            failures.append("\(prefix) horizontal rule markdown is still visible")
        }
        if !hasHiddenCodeFence() {
            failures.append("\(prefix) fenced code markers are still visible")
        }
        if !hasImageAltStyle(for: testCase.imageAlt) {
            failures.append("\(prefix) image alt text style was not applied")
        }

        return failures
    }

    private func writeSnapshot(named name: String, outputDirectory: URL) {
        rootView.layoutSubtreeIfNeeded()
        guard let bitmap = rootView.bitmapImageRepForCachingDisplay(in: rootView.bounds) else {
            fputs("[MarkdownViewer][self-test] cannot create bitmap for \(name)\n", stderr)
            return
        }

        rootView.cacheDisplay(in: rootView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            fputs("[MarkdownViewer][self-test] cannot encode \(name)\n", stderr)
            return
        }

        do {
            try data.write(to: outputDirectory.appendingPathComponent(name))
        } catch {
            fputs("[MarkdownViewer][self-test] cannot write \(name): \(error.localizedDescription)\n", stderr)
        }
    }

    private func hasHeadingStyle(for needle: String) -> Bool {
        guard let storage = editorTextView.textStorage else { return false }
        let nsString = storage.string as NSString
        let range = nsString.range(of: needle)
        guard range.location != NSNotFound else { return false }
        let attrs = storage.attributes(at: range.location, effectiveRange: nil)
        guard let font = attrs[.font] as? NSFont else { return false }
        return font.pointSize >= 26 && font.fontDescriptor.symbolicTraits.contains(.bold)
    }

    private func hasBoldStyle(for needle: String) -> Bool {
        guard let storage = editorTextView.textStorage else { return false }
        let nsString = storage.string as NSString
        let range = nsString.range(of: needle)
        guard range.location != NSNotFound else { return false }
        let attrs = storage.attributes(at: range.location, effectiveRange: nil)
        guard let font = attrs[.font] as? NSFont else { return false }
        return font.fontDescriptor.symbolicTraits.contains(.bold)
    }

    private func hasItalicStyle(for needle: String) -> Bool {
        guard let storage = editorTextView.textStorage else { return false }
        let nsString = storage.string as NSString
        let range = nsString.range(of: needle)
        guard range.location != NSNotFound else { return false }
        let attrs = storage.attributes(at: range.location, effectiveRange: nil)
        guard let font = attrs[.font] as? NSFont else { return false }
        return font.fontDescriptor.symbolicTraits.contains(.italic) || attrs[.obliqueness] != nil
    }

    private func hasStrikethroughStyle(for needle: String) -> Bool {
        guard let storage = editorTextView.textStorage else { return false }
        let nsString = storage.string as NSString
        let range = nsString.range(of: needle)
        guard range.location != NSNotFound else { return false }
        let attrs = storage.attributes(at: range.location, effectiveRange: nil)
        return attrs[.strikethroughStyle] != nil
    }

    private func hasMonospaceStyle(for needle: String) -> Bool {
        guard let storage = editorTextView.textStorage else { return false }
        let nsString = storage.string as NSString
        let range = nsString.range(of: needle)
        guard range.location != NSNotFound else { return false }
        let attrs = storage.attributes(at: range.location, effectiveRange: nil)
        guard let font = attrs[.font] as? NSFont else { return false }
        return font.fontDescriptor.symbolicTraits.contains(.monoSpace)
    }

    private func hasLinkStyle(for needle: String) -> Bool {
        guard let storage = editorTextView.textStorage else { return false }
        let nsString = storage.string as NSString
        let range = nsString.range(of: needle)
        guard range.location != NSNotFound else { return false }
        let attrs = storage.attributes(at: range.location, effectiveRange: nil)
        return attrs[.underlineStyle] != nil
    }

    private func hasQuoteStyle(for needle: String) -> Bool {
        guard let storage = editorTextView.textStorage else { return false }
        let nsString = storage.string as NSString
        let range = nsString.range(of: needle)
        guard range.location != NSNotFound else { return false }
        let attrs = storage.attributes(at: range.location, effectiveRange: nil)
        return attrs[.backgroundColor] != nil
    }

    private func hasTableHeaderStyle(for needle: String) -> Bool {
        guard let storage = editorTextView.textStorage else { return false }
        let nsString = storage.string as NSString
        let range = nsString.range(of: needle)
        guard range.location != NSNotFound else { return false }
        let attrs = storage.attributes(at: range.location, effectiveRange: nil)
        guard let font = attrs[.font] as? NSFont else { return false }
        return font.fontDescriptor.symbolicTraits.contains(.bold) && attrs[.backgroundColor] != nil
    }

    private func hasHiddenTableSeparator() -> Bool {
        guard let storage = editorTextView.textStorage else { return false }
        let nsString = storage.string as NSString
        let range = nsString.range(of: "| --- | --- |")
        guard range.location != NSNotFound else { return false }
        return isVisuallyHidden(range: range, in: storage)
    }

    private func hasAlignedTableColumns(headers: [String], rows: [[String]]) -> Bool {
        guard headers.count >= 2, !rows.isEmpty else { return false }
        guard rows.allSatisfy({ $0.count == headers.count }) else { return false }
        guard let tableStartRange = characterRange(of: headers[0]) else { return false }
        let tableStart = tableStartRange.location

        let headerXs = headers.map { header in
            xPosition(of: header, after: tableStart)
        }
        guard headerXs.allSatisfy({ $0 != nil }) else { return false }

        var rowSearchStart = tableStartRange.location + tableStartRange.length

        for (rowIndex, row) in rows.enumerated() {
            guard let firstCellRange = characterRange(of: row[0], after: rowSearchStart) else {
                return false
            }

            var cellSearchStart = firstCellRange.location
            for columnIndex in 0..<headers.count {
                guard let headerX = headerXs[columnIndex],
                      let cellRange = characterRange(of: row[columnIndex], after: cellSearchStart),
                      let valueX = xPosition(for: cellRange) else {
                    return false
                }

                if abs(headerX - valueX) > 3 {
                    fputs("[MarkdownViewer][table-align] row=\(rowIndex + 1), column=\(headers[columnIndex]), headerX=\(headerX), value=\(row[columnIndex]), valueX=\(valueX), delta=\(abs(headerX - valueX))\n", stderr)
                    return false
                }

                cellSearchStart = cellRange.location + cellRange.length
            }

            rowSearchStart = firstCellRange.location + firstCellRange.length
        }

        return true
    }

    private func characterRange(of needle: String, after start: Int = 0) -> NSRange? {
        let nsString = editorTextView.string as NSString
        guard start < nsString.length else { return nil }
        let range = nsString.range(of: needle, options: [], range: NSRange(location: start, length: nsString.length - start))
        return range.location == NSNotFound ? nil : range
    }

    private func xPosition(of needle: String, after start: Int = 0) -> CGFloat? {
        guard let characterRange = characterRange(of: needle, after: start) else { return nil }
        return xPosition(for: characterRange)
    }

    private func xPosition(for characterRange: NSRange) -> CGFloat? {
        guard let layoutManager = editorTextView.layoutManager,
              let textContainer = editorTextView.textContainer else {
            return nil
        }

        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return nil }

        return layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer).minX
    }

    private func hasHiddenHeadingMarker() -> Bool {
        guard let storage = editorTextView.textStorage else { return false }
        let nsString = storage.string as NSString
        let range = nsString.range(of: "#")
        guard range.location != NSNotFound else { return false }
        return isVisuallyHidden(range: range, in: storage)
    }

    private func hasHiddenQuoteMarker(for quote: String) -> Bool {
        guard let storage = editorTextView.textStorage else { return false }
        let nsString = storage.string as NSString
        let quoteRange = nsString.range(of: quote)
        guard quoteRange.location != NSNotFound else { return false }
        let searchStart = max(0, quoteRange.location - 4)
        let searchRange = NSRange(location: searchStart, length: quoteRange.location - searchStart)
        let markerRange = nsString.range(of: ">", options: [.backwards], range: searchRange)
        guard markerRange.location != NSNotFound else { return false }
        return isVisuallyHidden(range: markerRange, in: storage)
    }

    private func hasHiddenTablePipes() -> Bool {
        guard let storage = editorTextView.textStorage else { return false }
        let nsString = storage.string as NSString
        let tableRange = nsString.range(of: "|")
        guard tableRange.location != NSNotFound else { return false }
        return isVisuallyHidden(range: tableRange, in: storage)
    }

    private func hasHiddenMarkup(_ marker: String) -> Bool {
        guard let storage = editorTextView.textStorage else { return false }
        let nsString = storage.string as NSString
        let range = nsString.range(of: marker)
        guard range.location != NSNotFound else { return false }
        return isVisuallyHidden(range: range, in: storage)
    }

    private func hasHiddenMarkup(_ wrapped: String, content: String) -> Bool {
        guard let storage = editorTextView.textStorage else { return false }
        let nsString = storage.string as NSString
        let wrappedRange = nsString.range(of: wrapped)
        let contentRange = nsString.range(of: content)
        guard wrappedRange.location != NSNotFound,
              contentRange.location != NSNotFound,
              wrappedRange.location < contentRange.location else {
            return false
        }
        let prefix = NSRange(location: wrappedRange.location, length: contentRange.location - wrappedRange.location)
        let suffixStart = contentRange.location + contentRange.length
        let suffix = NSRange(location: suffixStart, length: wrappedRange.location + wrappedRange.length - suffixStart)
        return isVisuallyHidden(range: prefix, in: storage) && isVisuallyHidden(range: suffix, in: storage)
    }

    private func hasHiddenLinkDestination(for linkText: String) -> Bool {
        guard let storage = editorTextView.textStorage else { return false }
        let nsString = storage.string as NSString
        let labelRange = nsString.range(of: linkText)
        guard labelRange.location != NSNotFound else { return false }
        let afterLabel = labelRange.location + labelRange.length
        let searchRange = NSRange(location: afterLabel, length: nsString.length - afterLabel)
        let destinationRange = nsString.range(of: "](https://", options: [], range: searchRange)
        guard destinationRange.location != NSNotFound else { return false }
        let closeRange = nsString.range(of: ")", options: [], range: NSRange(location: destinationRange.location, length: nsString.length - destinationRange.location))
        guard closeRange.location != NSNotFound else { return false }
        let hiddenRange = NSRange(location: destinationRange.location, length: closeRange.location + closeRange.length - destinationRange.location)
        return isVisuallyHidden(range: hiddenRange, in: storage)
    }

    private func hasHiddenHorizontalRule() -> Bool {
        guard let storage = editorTextView.textStorage else { return false }
        let nsString = storage.string as NSString
        let range = nsString.range(of: "\n---\n")
        guard range.location != NSNotFound else { return false }
        let markerRange = NSRange(location: range.location + 1, length: 3)
        return isVisuallyHidden(range: markerRange, in: storage)
    }

    private func hasHiddenCodeFence() -> Bool {
        guard let storage = editorTextView.textStorage else { return false }
        let nsString = storage.string as NSString
        let range = nsString.range(of: "```swift")
        guard range.location != NSNotFound else { return false }
        return isVisuallyHidden(range: range, in: storage)
    }

    private func hasImageAltStyle(for needle: String) -> Bool {
        guard let storage = editorTextView.textStorage else { return false }
        let nsString = storage.string as NSString
        let range = nsString.range(of: needle)
        guard range.location != NSNotFound else { return false }
        let attrs = storage.attributes(at: range.location, effectiveRange: nil)
        guard let font = attrs[.font] as? NSFont else { return false }
        return font.fontDescriptor.symbolicTraits.contains(.italic) || attrs[.obliqueness] != nil
    }

    private func isVisuallyHidden(range: NSRange, in storage: NSTextStorage) -> Bool {
        guard range.length > 0, range.location != NSNotFound else { return false }
        var hidden = true
        storage.enumerateAttributes(in: range) { attrs, _, stop in
            let font = attrs[.font] as? NSFont
            let color = attrs[.foregroundColor] as? NSColor
            let fontHidden = (font?.pointSize ?? 99) <= 2
            let colorHidden = color == NSColor.clear
            if !(fontHidden || colorHidden) {
                hidden = false
                stop.pointee = true
            }
        }
        return hidden
    }
}

enum LiveMarkdownStyler {
    static let bodyFont = NSFont.systemFont(ofSize: 15.5)

    private static let markerFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    private static let codeFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    private static let boldCodeFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
    private static let markerColor = DesignTokens.placeholderText
    private static let mutedColor = DesignTokens.secondaryText
    private static let codeBackground = DesignTokens.codeBackground
    private static let quoteBackground = NSColor.clear

    private static let headingRegex = try! NSRegularExpression(pattern: "^(#{1,6})\\s+(.+)$", options: [.anchorsMatchLines])
    private static let listRegex = try! NSRegularExpression(pattern: "^(\\s*(?:[-*+] |\\d+\\. ))(.+)$", options: [.anchorsMatchLines])
    private static let taskRegex = try! NSRegularExpression(pattern: "^(\\s*[-*+] \\[[ xX]\\] )(.+)$", options: [.anchorsMatchLines])
    private static let strongStarRegex = try! NSRegularExpression(pattern: "\\*\\*([^\\n*]+)\\*\\*")
    private static let strongUnderscoreRegex = try! NSRegularExpression(pattern: "__([^\\n_]+)__")
    private static let italicStarRegex = try! NSRegularExpression(pattern: "(?<!\\*)\\*([^\\n*]+)\\*(?!\\*)")
    private static let strikeRegex = try! NSRegularExpression(pattern: "~~([^\\n~]+)~~")
    private static let inlineCodeRegex = try! NSRegularExpression(pattern: "`([^`\\n]+)`")
    private static let imageRegex = try! NSRegularExpression(pattern: "!\\[([^\\]\\n]*)\\]\\(([^)\\n]+)\\)")
    private static let linkRegex = try! NSRegularExpression(pattern: "\\[([^\\]\\n]+)\\]\\(([^)\\n]+)\\)")

    static func apply(to textStorage: NSTextStorage) {
        let fullRange = NSRange(location: 0, length: textStorage.length)
        guard fullRange.length > 0 else { return }

        textStorage.beginEditing()
        textStorage.setAttributes(baseAttributes(), range: fullRange)
        applyLineStyles(to: textStorage)
        applyInlineStyles(to: textStorage)
        textStorage.endEditing()
    }

    static func typingAttributes() -> [NSAttributedString.Key: Any] {
        baseAttributes()
    }

    private static func applyLineStyles(to textStorage: NSTextStorage) {
        let nsString = textStorage.string as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        let lines = markdownLines(in: nsString, fullRange: fullRange)
        var insideCodeBlock = false
        var index = 0

        while index < lines.count {
            let current = lines[index]
            let substringRange = current.range
            let line = current.text
            guard substringRange.length > 0 else {
                index += 1
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                textStorage.addAttributes(codeBlockAttributes(), range: substringRange)
                textStorage.addAttributes(hiddenMarkupAttributes(), range: substringRange)
                insideCodeBlock.toggle()
                index += 1
                continue
            }

            if insideCodeBlock {
                textStorage.addAttributes(codeBlockAttributes(), range: substringRange)
                index += 1
                continue
            }

            if index + 1 < lines.count,
               looksLikeTableLine(line),
               isTableSeparatorLine(lines[index + 1].text) {
                var tableRows: [(text: String, range: NSRange, isHeader: Bool)] = [
                    (line, substringRange, true)
                ]
                let separatorRange = lines[index + 1].range
                index += 2

                while index < lines.count && looksLikeTableLine(lines[index].text) {
                    tableRows.append((lines[index].text, lines[index].range, false))
                    index += 1
                }

                applyTableBlock(rows: tableRows, separatorRange: separatorRange, to: textStorage)
                continue
            }

            if let heading = firstMatch(headingRegex, in: nsString, exactly: substringRange) {
                let level = heading.range(at: 1).length
                let font = headingFont(level: level)
                textStorage.addAttributes([
                    .font: font,
                    .paragraphStyle: headingParagraphStyle(level: level)
                ], range: substringRange)
                textStorage.addAttributes(hiddenMarkupAttributes(), range: heading.range(at: 1))
                index += 1
                continue
            }

            if trimmed == "---" || trimmed == "***" {
                let style = paragraphStyle(spacingAfter: 12)
                style.minimumLineHeight = 1
                style.maximumLineHeight = 1
                textStorage.addAttributes([
                    .foregroundColor: NSColor.clear,
                    .font: NSFont.systemFont(ofSize: 1),
                    .paragraphStyle: style
                ], range: substringRange)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                let style = paragraphStyle(spacingAfter: 9)
                style.headIndent = 18
                style.firstLineHeadIndent = 18
                textStorage.addAttributes([
                    .foregroundColor: mutedColor,
                    .backgroundColor: quoteBackground,
                    .paragraphStyle: style
                ], range: substringRange)
                if let markerRange = line.range(of: ">") {
                    let nsMarkerRange = NSRange(markerRange, in: line)
                    textStorage.addAttributes(hiddenMarkupAttributes(), range: NSRange(location: substringRange.location + nsMarkerRange.location, length: nsMarkerRange.length))
                }
                index += 1
                continue
            }

            if let task = firstMatch(taskRegex, in: nsString, exactly: substringRange) {
                let markerRange = task.range(at: 1)
                textStorage.addAttributes(markerAttributes(font: boldCodeFont), range: markerRange)
                index += 1
                continue
            }

            if let list = firstMatch(listRegex, in: nsString, exactly: substringRange) {
                let markerRange = list.range(at: 1)
                let style = paragraphStyle(spacingAfter: 3)
                style.headIndent = 24
                textStorage.addAttributes([.paragraphStyle: style], range: substringRange)
                textStorage.addAttributes(markerAttributes(font: markerFont), range: markerRange)
            }

            index += 1
        }
    }

    private static func applyInlineStyles(to textStorage: NSTextStorage) {
        let nsString = textStorage.string as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        applyDelimitedStyle(regex: strongStarRegex, trait: .boldFontMask, textStorage: textStorage, fullRange: fullRange)
        applyDelimitedStyle(regex: strongUnderscoreRegex, trait: .boldFontMask, textStorage: textStorage, fullRange: fullRange)
        applyDelimitedStyle(regex: italicStarRegex, trait: .italicFontMask, textStorage: textStorage, fullRange: fullRange)
        applyStrikethrough(textStorage: textStorage, fullRange: fullRange)

        for match in inlineCodeRegex.matches(in: nsString as String, range: fullRange).reversed() {
            textStorage.addAttributes([
                .font: codeFont,
                .backgroundColor: codeBackground,
                .foregroundColor: DesignTokens.titleText
            ], range: match.range)
            dimMarkup(in: match, contentIndex: 1, textStorage: textStorage)
        }

        for match in imageRegex.matches(in: nsString as String, range: fullRange).reversed() {
            textStorage.addAttributes([
                .foregroundColor: mutedColor,
                .font: NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask),
                .obliqueness: 0.15
            ], range: match.range(at: 1))
            hideImageMarkup(in: match, textStorage: textStorage)
        }

        for match in linkRegex.matches(in: nsString as String, range: fullRange).reversed() {
            if match.range.location > 0 {
                let previousIndex = nsString.character(at: match.range.location - 1)
                if previousIndex == 33 {
                    continue
                }
            }
            textStorage.addAttributes([
                .foregroundColor: DesignTokens.link,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: match.range(at: 1))
            let urlRange = match.range(at: 2)
            textStorage.addAttributes([
                .foregroundColor: mutedColor,
                .font: markerFont
            ], range: urlRange)
            dimMarkup(in: match, contentIndex: 1, textStorage: textStorage)
        }
    }

    private static func applyStrikethrough(textStorage: NSTextStorage, fullRange: NSRange) {
        let source = textStorage.string
        for match in strikeRegex.matches(in: source, range: fullRange).reversed() {
            textStorage.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: mutedColor
            ], range: match.range(at: 1))
            dimMarkup(in: match, contentIndex: 1, textStorage: textStorage)
        }
    }

    private static func applyDelimitedStyle(regex: NSRegularExpression, trait: NSFontTraitMask, textStorage: NSTextStorage, fullRange: NSRange) {
        let source = textStorage.string
        for match in regex.matches(in: source, range: fullRange).reversed() {
            let contentRange = match.range(at: 1)
            applyFontTrait(trait, to: contentRange, in: textStorage)
            dimMarkup(in: match, contentIndex: 1, textStorage: textStorage)
        }
    }

    private static func applyFontTrait(_ trait: NSFontTraitMask, to range: NSRange, in textStorage: NSTextStorage) {
        textStorage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = (value as? NSFont) ?? bodyFont
            let converted = NSFontManager.shared.convert(font, toHaveTrait: trait)
            var attrs: [NSAttributedString.Key: Any] = [.font: converted]
            if trait == .italicFontMask {
                attrs[.obliqueness] = 0.15
            }
            textStorage.addAttributes(attrs, range: subrange)
        }
    }

    private static func dimMarkup(in match: NSTextCheckingResult, contentIndex: Int, textStorage: NSTextStorage) {
        let whole = match.range
        let content = match.range(at: contentIndex)

        if content.location > whole.location {
            textStorage.addAttributes(hiddenMarkupAttributes(), range: NSRange(location: whole.location, length: content.location - whole.location))
        }

        let contentEnd = content.location + content.length
        let wholeEnd = whole.location + whole.length
        if wholeEnd > contentEnd {
            textStorage.addAttributes(hiddenMarkupAttributes(), range: NSRange(location: contentEnd, length: wholeEnd - contentEnd))
        }
    }

    private static func hideImageMarkup(in match: NSTextCheckingResult, textStorage: NSTextStorage) {
        let whole = match.range
        let alt = match.range(at: 1)
        if alt.location > whole.location {
            textStorage.addAttributes(hiddenMarkupAttributes(), range: NSRange(location: whole.location, length: alt.location - whole.location))
        }
        let altEnd = alt.location + alt.length
        let wholeEnd = whole.location + whole.length
        if wholeEnd > altEnd {
            textStorage.addAttributes(hiddenMarkupAttributes(), range: NSRange(location: altEnd, length: wholeEnd - altEnd))
        }
    }

    private static func firstMatch(_ regex: NSRegularExpression, in nsString: NSString, exactly range: NSRange) -> NSTextCheckingResult? {
        regex.firstMatch(in: nsString as String, range: range).flatMap { match in
            match.range.location == range.location && match.range.length == range.length ? match : nil
        }
    }

    private static func markdownLines(in nsString: NSString, fullRange: NSRange) -> [(text: String, range: NSRange)] {
        var lines: [(String, NSRange)] = []
        nsString.enumerateSubstrings(in: fullRange, options: [.byLines, .substringNotRequired]) { _, substringRange, _, _ in
            lines.append((nsString.substring(with: substringRange), substringRange))
        }
        return lines
    }

    private static func looksLikeTableLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|") && (trimmed.hasPrefix("|") || trimmed.hasSuffix("|"))
    }

    private static func isTableSeparatorLine(_ line: String) -> Bool {
        let cells = splitTableCells(line)
        guard cells.count >= 2 else { return false }
        return cells.allSatisfy { cell in
            let normalized = cell.replacingOccurrences(of: ":", with: "")
            return normalized.count >= 3 && normalized.allSatisfy { $0 == "-" }
        }
    }

    private static func applyTableBlock(rows: [(text: String, range: NSRange, isHeader: Bool)], separatorRange: NSRange, to textStorage: NSTextStorage) {
        let parsedRows = rows.map { row in
            (row: row, cells: parseTableCells(line: row.text, lineRange: row.range))
        }
        let columnCount = parsedRows.map { $0.cells.count }.max() ?? 0
        let columnWidths: [CGFloat] = (0..<columnCount).map { columnIndex in
            parsedRows.map { parsedRow in
                guard parsedRow.cells.indices.contains(columnIndex) else { return CGFloat(0) }
                let font = parsedRow.row.isHeader ? boldCodeFont : codeFont
                return measuredWidth(parsedRow.cells[columnIndex].visibleText, font: font)
            }.max() ?? 0
        }

        for parsedRow in parsedRows {
            if parsedRow.row.isHeader {
                applyTableHeader(parsedRow.row.text, range: parsedRow.row.range, cells: parsedRow.cells, columnWidths: columnWidths, to: textStorage)
            } else {
                applyTableRow(parsedRow.row.text, range: parsedRow.row.range, cells: parsedRow.cells, columnWidths: columnWidths, to: textStorage)
            }
        }

        applyHiddenTableSeparator(range: separatorRange, to: textStorage)
    }

    private static func applyTableHeader(_ line: String, range: NSRange, cells: [TableCell], columnWidths: [CGFloat], to textStorage: NSTextStorage) {
        let style = paragraphStyle(spacingBefore: 4, spacingAfter: 0)
        style.headIndent = 8
        style.firstLineHeadIndent = 8
        style.lineBreakMode = .byClipping
        textStorage.addAttributes([
            .font: boldCodeFont,
            .backgroundColor: codeBackground,
            .paragraphStyle: style
        ], range: range)
        alignTableCells(cells, columnWidths: columnWidths, rowFont: boldCodeFont, textStorage: textStorage)
    }

    private static func applyTableRow(_ line: String, range: NSRange, cells: [TableCell], columnWidths: [CGFloat], to textStorage: NSTextStorage) {
        let style = paragraphStyle(spacingBefore: 0, spacingAfter: 0)
        style.headIndent = 8
        style.firstLineHeadIndent = 8
        style.lineBreakMode = .byClipping
        textStorage.addAttributes([
            .font: codeFont,
            .backgroundColor: codeBackground,
            .paragraphStyle: style
        ], range: range)
        alignTableCells(cells, columnWidths: columnWidths, rowFont: codeFont, textStorage: textStorage)
    }

    private static func applyHiddenTableSeparator(range: NSRange, to textStorage: NSTextStorage) {
        let style = paragraphStyle(spacingBefore: 0, spacingAfter: 0)
        style.minimumLineHeight = 1
        style.maximumLineHeight = 1
        textStorage.addAttributes([
            .font: NSFont.systemFont(ofSize: 1),
            .foregroundColor: NSColor.clear,
            .backgroundColor: codeBackground,
            .paragraphStyle: style
        ], range: range)
    }

    private static func alignTableCells(_ cells: [TableCell], columnWidths: [CGFloat], rowFont: NSFont, textStorage: NSTextStorage) {
        let columnGap: CGFloat = 30

        for (index, cell) in cells.enumerated() {
            if cell.contentRange.length > 0 {
                textStorage.addAttributes([.font: rowFont], range: cell.contentRange)
            }

            guard let trailingPipeRange = cell.trailingPipeRange else { continue }
            let currentWidth = measuredWidth(cell.visibleText, font: rowFont)
            let targetWidth = columnWidths.indices.contains(index) ? columnWidths[index] : currentWidth
            let addedSpace = max(columnGap, targetWidth - currentWidth + columnGap)
            var attrs = hiddenMarkupAttributes(font: rowFont)
            if index < cells.count - 1 {
                attrs[.kern] = addedSpace
            }
            textStorage.addAttributes(attrs, range: trailingPipeRange)
        }

        if let first = cells.first?.leadingPipeRange {
            textStorage.addAttributes(hiddenMarkupAttributes(font: rowFont), range: first)
        }
    }

    private struct TableCell {
        let visibleText: String
        let contentRange: NSRange
        let leadingPipeRange: NSRange?
        let trailingPipeRange: NSRange?
    }

    private static func parseTableCells(line: String, lineRange: NSRange) -> [TableCell] {
        let nsLine = line as NSString
        var pipePositions: [Int] = []
        var searchLocation = 0
        while searchLocation < nsLine.length {
            let found = nsLine.range(of: "|", options: [], range: NSRange(location: searchLocation, length: nsLine.length - searchLocation))
            if found.location == NSNotFound { break }
            pipePositions.append(found.location)
            searchLocation = found.location + found.length
        }

        guard !pipePositions.isEmpty else {
            return [
                TableCell(
                    visibleText: line.trimmingCharacters(in: .whitespaces),
                    contentRange: lineRange,
                    leadingPipeRange: nil,
                    trailingPipeRange: nil
                )
            ]
        }

        var boundaries = pipePositions
        if boundaries.first != 0 {
            boundaries.insert(-1, at: 0)
        }
        if boundaries.last != nsLine.length - 1 {
            boundaries.append(nsLine.length)
        }

        var cells: [TableCell] = []
        for index in 0..<(boundaries.count - 1) {
            let startBoundary = boundaries[index]
            let endBoundary = boundaries[index + 1]
            let contentStart = startBoundary + 1
            let contentLength = max(0, endBoundary - contentStart)
            let contentRange = NSRange(location: lineRange.location + contentStart, length: contentLength)
            let text = contentLength > 0 ? nsLine.substring(with: NSRange(location: contentStart, length: contentLength)).trimmingCharacters(in: .whitespaces) : ""
            let leadingPipe = startBoundary >= 0 ? NSRange(location: lineRange.location + startBoundary, length: 1) : nil
            let trailingPipe = endBoundary < nsLine.length && nsLine.character(at: endBoundary) == 124 ? NSRange(location: lineRange.location + endBoundary, length: 1) : nil
            cells.append(TableCell(visibleText: text, contentRange: contentRange, leadingPipeRange: leadingPipe, trailingPipeRange: trailingPipe))
        }

        return cells.filter { !$0.visibleText.isEmpty || $0.trailingPipeRange != nil }
    }

    private static func splitTableCells(_ line: String) -> [String] {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }

        if cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        return cells
    }

    private static func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    private static func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: bodyFont,
            .foregroundColor: DesignTokens.bodyText,
            .paragraphStyle: paragraphStyle()
        ]
    }

    private static func markerAttributes(font: NSFont = markerFont) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: markerColor
        ]
    }

    private static func hiddenMarkupAttributes(font: NSFont = NSFont.systemFont(ofSize: 1)) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor.clear
        ]
    }

    private static func codeBlockAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: codeFont,
            .foregroundColor: DesignTokens.bodyText,
            .backgroundColor: codeBackground,
            .paragraphStyle: paragraphStyle(spacingAfter: 2)
        ]
    }

    private static func headingFont(level: Int) -> NSFont {
        switch level {
        case 1:
            return NSFont.systemFont(ofSize: 26, weight: .semibold)
        case 2:
            return NSFont.systemFont(ofSize: 18, weight: .semibold)
        case 3:
            return NSFont.systemFont(ofSize: 16, weight: .semibold)
        default:
            return NSFont.systemFont(ofSize: 15.5, weight: .semibold)
        }
    }

    private static func headingParagraphStyle(level: Int) -> NSParagraphStyle {
        paragraphStyle(spacingBefore: level == 1 ? 8 : 40, spacingAfter: level == 1 ? 24 : 16)
    }

    private static func paragraphStyle(spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 8) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacingAfter
        return style
    }
}

enum MarkdownRenderer {
    private static let bodyFont = NSFont.systemFont(ofSize: 15)
    private static let boldBodyFont = NSFont.boldSystemFont(ofSize: 15)
    private static let italicBodyFont = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
    private static let codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let boldCodeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)

    static func render(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var index = 0

        while index < lines.count {
            let line = lines[index]

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                appendNewlineIfNeeded(to: result)
                index += 1
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                var codeLines: [String] = []
                index += 1
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                appendCodeBlock(codeLines.joined(separator: "\n"), to: result)
                continue
            }

            if let heading = parseHeading(line) {
                appendHeading(level: heading.level, text: heading.text, to: result)
                index += 1
                continue
            }

            if line.trimmingCharacters(in: .whitespaces) == "---" {
                appendRule(to: result)
                index += 1
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                var quoteLines: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    quoteLines.append(String(current.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                appendQuote(quoteLines.joined(separator: " "), to: result)
                continue
            }

            if isTableStart(at: index, lines: lines) {
                var tableLines: [String] = [line, lines[index + 1]]
                index += 2
                while index < lines.count && lines[index].contains("|") && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    tableLines.append(lines[index])
                    index += 1
                }
                appendTable(tableLines, to: result)
                continue
            }

            if let item = parseListItem(line) {
                var items: [(marker: String, text: String)] = [item]
                index += 1
                while index < lines.count, let nextItem = parseListItem(lines[index]) {
                    items.append(nextItem)
                    index += 1
                }
                appendList(items, to: result)
                continue
            }

            var paragraphLines = [line.trimmingCharacters(in: .whitespaces)]
            index += 1
            while index < lines.count && !startsBlock(lines[index], nextLine: index + 1 < lines.count ? lines[index + 1] : nil) {
                let next = lines[index].trimmingCharacters(in: .whitespaces)
                if !next.isEmpty {
                    paragraphLines.append(next)
                }
                index += 1
            }

            appendParagraph(paragraphLines.joined(separator: " "), to: result)
        }

        if result.length == 0 {
            appendParagraph("空白文档", color: .secondaryLabelColor, to: result)
        }

        return result
    }

    private static func startsBlock(_ line: String, nextLine: String?) -> Bool {
        if line.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { return true }
        if parseHeading(line) != nil { return true }
        if line.trimmingCharacters(in: .whitespaces) == "---" { return true }
        if line.trimmingCharacters(in: .whitespaces).hasPrefix(">") { return true }
        if parseListItem(line) != nil { return true }
        if let nextLine, line.contains("|"), isTableSeparator(nextLine) { return true }
        return false
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var level = 0

        for character in trimmed {
            if character == "#" {
                level += 1
            } else {
                break
            }
        }

        guard (1...6).contains(level) else { return nil }
        let markerEnd = trimmed.index(trimmed.startIndex, offsetBy: level)
        guard markerEnd < trimmed.endIndex, trimmed[markerEnd] == " " else { return nil }

        let textStart = trimmed.index(after: markerEnd)
        return (level, String(trimmed[textStart...]))
    }

    private static func parseListItem(_ line: String) -> (marker: String, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        for marker in ["- ", "* ", "+ "] {
            if trimmed.hasPrefix(marker) {
                return ("•", String(trimmed.dropFirst(marker.count)))
            }
        }

        var digits = ""
        var cursor = trimmed.startIndex
        while cursor < trimmed.endIndex && trimmed[cursor].isNumber {
            digits.append(trimmed[cursor])
            cursor = trimmed.index(after: cursor)
        }

        if !digits.isEmpty,
           cursor < trimmed.endIndex,
           trimmed[cursor] == ".",
           trimmed.index(after: cursor) < trimmed.endIndex,
           trimmed[trimmed.index(after: cursor)] == " " {
            let textStart = trimmed.index(cursor, offsetBy: 2)
            return ("\(digits).", String(trimmed[textStart...]))
        }

        return nil
    }

    private static func isTableStart(at index: Int, lines: [String]) -> Bool {
        guard index + 1 < lines.count else { return false }
        return lines[index].contains("|") && isTableSeparator(lines[index + 1])
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard cells.count >= 2 else { return false }
        return cells.allSatisfy { cell in
            let stripped = cell.replacingOccurrences(of: ":", with: "")
            return stripped.count >= 3 && stripped.allSatisfy { $0 == "-" }
        }
    }

    private static func appendHeading(level: Int, text: String, to result: NSMutableAttributedString) {
        appendNewlineIfNeeded(to: result)

        let size: CGFloat
        switch level {
        case 1: size = 28
        case 2: size = 23
        case 3: size = 19
        default: size = 16
        }

        let font = NSFont.boldSystemFont(ofSize: size)
        let style = paragraphStyle(spacingBefore: level == 1 ? 2 : 8, spacingAfter: level == 1 ? 14 : 10)
        let attrs = baseAttributes(font: font, color: .labelColor, paragraphStyle: style)
        result.append(inline(text, attributes: attrs))
        result.append(NSAttributedString(string: "\n"))
    }

    private static func appendParagraph(_ text: String, color: NSColor = .labelColor, to result: NSMutableAttributedString) {
        appendNewlineIfNeeded(to: result)
        let attrs = baseAttributes(font: bodyFont, color: color, paragraphStyle: paragraphStyle(spacingAfter: 10))
        result.append(inline(text, attributes: attrs))
        result.append(NSAttributedString(string: "\n"))
    }

    private static func appendQuote(_ text: String, to result: NSMutableAttributedString) {
        appendNewlineIfNeeded(to: result)
        let style = paragraphStyle(spacingAfter: 12)
        style.headIndent = 18
        style.firstLineHeadIndent = 18
        let attrs = baseAttributes(font: bodyFont, color: .secondaryLabelColor, paragraphStyle: style).merging([
            .backgroundColor: NSColor.controlBackgroundColor
        ]) { lhs, _ in lhs }
        result.append(inline(text, attributes: attrs))
        result.append(NSAttributedString(string: "\n"))
    }

    private static func appendCodeBlock(_ code: String, to result: NSMutableAttributedString) {
        appendNewlineIfNeeded(to: result)
        let style = paragraphStyle(spacingAfter: 12)
        let attrs = baseAttributes(font: codeFont, color: .labelColor, paragraphStyle: style).merging([
            .backgroundColor: NSColor.controlBackgroundColor
        ]) { lhs, _ in lhs }
        result.append(NSAttributedString(string: code + "\n", attributes: attrs))
    }

    private static func appendTable(_ lines: [String], to result: NSMutableAttributedString) {
        appendNewlineIfNeeded(to: result)
        let style = paragraphStyle(spacingAfter: 12)
        let attrs = baseAttributes(font: codeFont, color: .labelColor, paragraphStyle: style).merging([
            .backgroundColor: NSColor.controlBackgroundColor
        ]) { lhs, _ in lhs }
        let headerAttrs = baseAttributes(font: boldCodeFont, color: .labelColor, paragraphStyle: style).merging([
            .backgroundColor: NSColor.controlBackgroundColor
        ]) { lhs, _ in lhs }
        let rows = lines.enumerated()
            .filter { !isTableSeparator($0.element) }
            .map { splitTableCells($0.element) }
        let columnCount = rows.map(\.count).max() ?? 0
        let widths = (0..<columnCount).map { column in
            rows.map { row in row.indices.contains(column) ? row[column].count : 0 }.max() ?? 0
        }

        for (rowIndex, row) in rows.enumerated() {
            let paddedCells = (0..<columnCount).map { column in
                let value = row.indices.contains(column) ? row[column] : ""
                return value.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }
            let rowText = "  " + paddedCells.joined(separator: "    ") + "  \n"
            result.append(NSAttributedString(string: rowText, attributes: rowIndex == 0 ? headerAttrs : attrs))
        }
    }

    private static func appendList(_ items: [(marker: String, text: String)], to result: NSMutableAttributedString) {
        appendNewlineIfNeeded(to: result)
        let style = paragraphStyle(spacingAfter: 4)
        style.firstLineHeadIndent = 0
        style.headIndent = 24
        let attrs = baseAttributes(font: bodyFont, color: .labelColor, paragraphStyle: style)
        let markerAttrs = baseAttributes(font: boldBodyFont, color: .secondaryLabelColor, paragraphStyle: style)

        for item in items {
            result.append(NSAttributedString(string: "\(item.marker) ", attributes: markerAttrs))
            result.append(inline(item.text, attributes: attrs))
            result.append(NSAttributedString(string: "\n"))
        }
    }

    private static func appendRule(to result: NSMutableAttributedString) {
        appendNewlineIfNeeded(to: result)
        let attrs = baseAttributes(font: bodyFont, color: .tertiaryLabelColor, paragraphStyle: paragraphStyle(spacingAfter: 12))
        result.append(NSAttributedString(string: "────────────────────────\n", attributes: attrs))
    }

    private static func splitTableCells(_ line: String) -> [String] {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        if cells.first == "" {
            cells.removeFirst()
        }

        if cells.last == "" {
            cells.removeLast()
        }

        return cells
    }

    private static func appendNewlineIfNeeded(to result: NSMutableAttributedString) {
        guard result.length > 0 else { return }
        let string = result.string
        if !string.hasSuffix("\n") {
            result.append(NSAttributedString(string: "\n"))
        }
    }

    private static func paragraphStyle(spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 8) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacingAfter
        return style
    }

    private static func baseAttributes(font: NSFont, color: NSColor, paragraphStyle: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]
    }

    private static func inline(_ text: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var index = text.startIndex

        while index < text.endIndex {
            if text[index...].hasPrefix("`"),
               let closing = text[text.index(after: index)...].firstIndex(of: "`") {
                let start = text.index(after: index)
                let code = String(text[start..<closing])
                var codeAttrs = attributes
                codeAttrs[.font] = codeFont
                codeAttrs[.backgroundColor] = NSColor.controlBackgroundColor
                result.append(NSAttributedString(string: code, attributes: codeAttrs))
                index = text.index(after: closing)
                continue
            }

            if text[index...].hasPrefix("**") {
                let start = text.index(index, offsetBy: 2)
                if let range = text[start...].range(of: "**") {
                    let content = String(text[start..<range.lowerBound])
                    var boldAttrs = attributes
                    boldAttrs[.font] = boldFont(for: attributes)
                    result.append(NSAttributedString(string: content, attributes: boldAttrs))
                    index = range.upperBound
                    continue
                }
            }

            if text[index...].hasPrefix("*") {
                let start = text.index(after: index)
                if let closing = text[start...].firstIndex(of: "*") {
                    let content = String(text[start..<closing])
                    var italicAttrs = attributes
                    italicAttrs[.font] = italicFont(for: attributes)
                    result.append(NSAttributedString(string: content, attributes: italicAttrs))
                    index = text.index(after: closing)
                    continue
                }
            }

            if text[index...].hasPrefix("![") {
                if let parsed = parseLink(in: text, from: index, image: true) {
                    var imageAttrs = attributes
                    imageAttrs[.foregroundColor] = NSColor.secondaryLabelColor
                    imageAttrs[.font] = italicBodyFont
                    result.append(NSAttributedString(string: "[图片: \(parsed.label)]", attributes: imageAttrs))
                    index = parsed.endIndex
                    continue
                }
            }

            if text[index...].hasPrefix("[") {
                if let parsed = parseLink(in: text, from: index, image: false) {
                    var linkAttrs = attributes
                    linkAttrs[.foregroundColor] = NSColor.linkColor
                    linkAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    linkAttrs[.link] = parsed.url
                    result.append(NSAttributedString(string: parsed.label, attributes: linkAttrs))
                    index = parsed.endIndex
                    continue
                }
            }

            let next = text.index(after: index)
            result.append(NSAttributedString(string: String(text[index..<next]), attributes: attributes))
            index = next
        }

        return result
    }

    private static func parseLink(in text: String, from index: String.Index, image: Bool) -> (label: String, url: String, endIndex: String.Index)? {
        let labelStart = image ? text.index(index, offsetBy: 2) : text.index(after: index)
        guard labelStart < text.endIndex,
              let labelEnd = text[labelStart...].firstIndex(of: "]") else {
            return nil
        }

        let parenStart = text.index(after: labelEnd)
        guard parenStart < text.endIndex,
              text[parenStart] == "(",
              let parenEnd = text[text.index(after: parenStart)...].firstIndex(of: ")") else {
            return nil
        }

        let urlStart = text.index(after: parenStart)
        let label = String(text[labelStart..<labelEnd])
        let url = String(text[urlStart..<parenEnd])
        return (label, url, text.index(after: parenEnd))
    }

    private static func boldFont(for attributes: [NSAttributedString.Key: Any]) -> NSFont {
        let font = attributes[.font] as? NSFont ?? bodyFont
        return NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    private static func italicFont(for attributes: [NSAttributedString.Key: Any]) -> NSFont {
        let font = attributes[.font] as? NSFont ?? bodyFont
        return NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
