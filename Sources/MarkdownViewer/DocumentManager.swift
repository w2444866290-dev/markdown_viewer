import SwiftUI
import UniformTypeIdentifiers

/// Central state for the Markdown Viewer app.
/// The active document's text is the single source of truth — stored
/// in tabs[i].text.  A convenience Binding<String> is provided for
/// SwiftUI views to read/write through.
@MainActor
final class DocumentManager: ObservableObject {
    // MARK: - Sidebar
    @Published var sidebarWidth: CGFloat = DesignTokens.sidebarWidth
    @Published var sidebarOpen: Bool = true
    @Published var sideFilter: String = ""
    @Published var directoryURL: URL?
    @Published var fileTree: [FileNode] = []
    @Published var expandedFolders: Set<UUID> = []

    // MARK: - Tabs (single source of truth)
    @Published var tabs: [DocumentTab] = []
    @Published var activeTabID: UUID?
    @Published var lastClosedTab: DocumentTab?

    // MARK: - Font
    @Published var fontIndex: Int = 1

    // MARK: - Overlays
    @Published var paletteOpen: Bool = false
    @Published var toastMessage: String = ""
    @Published var showToast: Bool = false

    /// Set by App to let the command palette toggle findState.
    var findStateToggle: (() -> Void)?

    // MARK: - Derived

    var activeTab: DocumentTab? {
        tabs.first { $0.id == activeTabID }
    }

    /// Non-optional convenience
    var currentText: String { activeTab?.text ?? "" }
    var isDirty: Bool { activeTab?.isDirty ?? false }

    var visibleFiles: [FileNode] {
        guard !sideFilter.isEmpty else { return fileTree }
        let q = sideFilter.lowercased()
        return fileTree.filter { $0.name.lowercased().contains(q) && !$0.isDirectory }
    }

    // MARK: - Binding for EditorView (single source of truth)

    var textBinding: Binding<String> {
        Binding<String>(
            get: { [weak self] in self?.activeTab?.text ?? "" },
            set: { [weak self] newValue in
                guard let self, let id = self.activeTabID,
                      let idx = self.tabs.firstIndex(where: { $0.id == id }) else { return }
                self.objectWillChange.send()
                self.tabs[idx].text = newValue
                self.tabs[idx].isDirty = true
            }
        )
    }

    // MARK: - Actions

    func openTab(for url: URL, text: String) {
        if let existing = tabs.first(where: { $0.url?.path == url.path }) {
            activeTabID = existing.id
            return
        }
        let tab = DocumentTab(url: url, name: url.lastPathComponent, text: text, isDirty: false)
        tabs.append(tab)
        activeTabID = tab.id
    }

    func newDocument(text: String = "# 未命名\n\n") {
        let tab = DocumentTab(url: nil, name: "未命名.md", text: text, isDirty: false)
        tabs.append(tab)
        activeTabID = tab.id
    }

    func closeTab(_ tab: DocumentTab) {
        lastClosedTab = tab
        tabs.removeAll { $0.id == tab.id }
        if activeTabID == tab.id {
            activeTabID = tabs.last?.id
        }
    }

    func reopenClosed() {
        guard let tab = lastClosedTab else { return }
        lastClosedTab = nil
        tabs.append(tab)
        activeTabID = tab.id
    }

    // MARK: - File I/O

    func saveCurrent() {
        guard let tab = activeTab else { return }
        if let url = tab.url {
            try? tab.text.write(to: url, atomically: true, encoding: .utf8)
            if let idx = tabs.firstIndex(where: { $0.id == tab.id }) {
                tabs[idx].isDirty = false
            }
        } else {
            saveAsCurrent()
        }
    }

    func saveAsCurrent() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType.plainText, UTType(filenameExtension: "md")!]
        savePanel.nameFieldStringValue = activeTab?.name ?? "未命名.md"
        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }
        if let idx = tabs.firstIndex(where: { $0.id == activeTabID }) {
            try? tabs[idx].text.write(to: url, atomically: true, encoding: .utf8)
            tabs[idx].url = url
            tabs[idx].name = url.lastPathComponent
            tabs[idx].isDirty = false
        }
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.plainText, UTType(filenameExtension: "md")!]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        openTab(for: url, text: text)
    }

    func openDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "选择一个文件夹以加载其中的文档"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Resolve to directory if user selected a file inside it
        var dirURL = url
        if !dirURL.hasDirectoryPath {
            dirURL = url.deletingLastPathComponent()
        }
        loadDirectory(dirURL)
    }

    func loadDirectory(_ url: URL) {
        directoryURL = url
        fileTree = buildFileTree(at: url)
        if let first = firstTextFile(in: fileTree), tabs.isEmpty {
            if let text = try? String(contentsOf: first, encoding: .utf8) {
                openTab(for: first, text: text)
            }
        }
    }

    func openFileNode(_ node: FileNode) {
        guard !node.isDirectory, let text = try? String(contentsOf: node.url, encoding: .utf8) else { return }
        openTab(for: node.url, text: text)
    }

    private func buildFileTree(at url: URL) -> [FileNode] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return urls.compactMap { childURL -> FileNode? in
            let isDir = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                return FileNode(url: childURL, name: childURL.lastPathComponent, isDirectory: true, children: buildFileTree(at: childURL))
            }
            guard isTextFile(childURL) else { return nil }
            return FileNode(url: childURL, name: childURL.lastPathComponent, isDirectory: false)
        }.sorted { ($0.isDirectory && !$1.isDirectory) || $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func firstTextFile(in nodes: [FileNode]) -> URL? {
        for node in nodes {
            if !node.isDirectory { return node.url }
            if let found = firstTextFile(in: node.children) { return found }
        }
        return nil
    }

    private func isTextFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["md", "markdown", "mdown", "mkd", "txt", "text", "yaml", "yml", "json", "toml", "swift", "sh", "py", "js", "ts", "html", "css", "xml", "rb", "go", "rs", "java", "kt"].contains(ext)
    }

    // MARK: - Vim-like navigation

    struct VimNavState { var mode: VimMode = .normal }
    enum VimMode { case normal, insert }
    @Published var vim = VimNavState()
}

// MARK: - Models

struct FileNode: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    var isDirectory: Bool
    var children: [FileNode] = []
}

struct DocumentTab: Identifiable {
    let id = UUID()
    var url: URL?
    var name: String
    var text: String
    var isDirty: Bool
}
