import SwiftUI
import UniformTypeIdentifiers

/// Central state for the Markdown Viewer app.
@MainActor
final class DocumentManager: ObservableObject {
    // MARK: - Sidebar
    @Published var sidebarWidth: CGFloat = DesignTokens.sidebarWidth
    @Published var sidebarOpen: Bool = true
    @Published var sideFilter: String = ""
    @Published var directoryURL: URL?
    @Published var fileTree: [FileNode] = []

    // MARK: - Tabs
    @Published var tabs: [DocumentTab] = []
    @Published var activeTabID: UUID?
    @Published var lastClosedTab: DocumentTab?

    // MARK: - Font
    @Published var fontIndex: Int = 1

    // MARK: - Overlays
    @Published var paletteOpen: Bool = false
    @Published var findOpen: Bool = false
    @Published var toastMessage: String = ""
    @Published var showToast: Bool = false

    // MARK: - Editor (shared across tabs)
    @Published var editorText: String = ""
    @Published var isDirty: Bool = false

    var activeTab: DocumentTab? {
        tabs.first { $0.id == activeTabID }
    }

    var visibleFiles: [FileNode] {
        guard !sideFilter.isEmpty else { return fileTree }
        let q = sideFilter.lowercased()
        return fileTree.filter { $0.name.lowercased().contains(q) && !$0.isDirectory }
    }

    // MARK: - Actions
    func openTab(for url: URL, text: String) {
        if let existing = tabs.first(where: { $0.url?.path == url.path }) {
            activeTabID = existing.id
            editorText = text
            return
        }
        let tab = DocumentTab(url: url, name: url.lastPathComponent, text: text, isDirty: false)
        tabs.append(tab)
        activeTabID = tab.id
        editorText = text
        isDirty = false
    }

    func newDocument() {
        let tab = DocumentTab(url: nil, name: "未命名.md", text: "# 未命名\n\n", isDirty: true)
        tabs.append(tab)
        activeTabID = tab.id
        editorText = tab.text
        isDirty = true
    }

    func closeTab(_ tab: DocumentTab) {
        lastClosedTab = tab
        tabs.removeAll { $0.id == tab.id }
        if activeTabID == tab.id {
            activeTabID = tabs.last?.id
            editorText = tabs.last?.text ?? ""
            isDirty = tabs.last?.isDirty ?? false
        }
    }

    func reopenClosed() {
        guard let tab = lastClosedTab else { return }
        lastClosedTab = nil
        tabs.append(tab)
        activeTabID = tab.id
        editorText = tab.text
        isDirty = tab.isDirty
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
}

// MARK: - Models

struct FileNode: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    var children: [FileNode] = []
}

struct DocumentTab: Identifiable {
    let id = UUID()
    var url: URL?
    var name: String
    var text: String
    var isDirty: Bool
    var scrollOffset: CGFloat = 0
}
