import SwiftUI
import UniformTypeIdentifiers

/// Central state for the Markdown Viewer app.
/// Two-tier text model: while editing, the LIVE text lives in the editor's
/// NSTextView; `tabs[i].text` is a SNAPSHOT reconciled from it only at discrete
/// points (save, tab switch, palette open, terminate) via `reconcileActiveText`,
/// never per keystroke.
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
    /// Tab currently awaiting a confirm-close second click (dirty tabs only).
    @Published var confirmingCloseTabID: UUID?

    // MARK: - Font
    @Published var fontIndex: Int = 1

    // MARK: - Overlays
    @Published var paletteOpen: Bool = false

    /// Set by App to let the command palette toggle findState.
    var findStateToggle: (() -> Void)?
    /// Set by ContentView so the ⌘K palette can ALWAYS-open find (spec #14):
    /// the "查找 / 替换" entry must never close an already-open find, so it routes
    /// through openFind() rather than the toggle.
    var findStateOpen: (() -> Void)?

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

    /// Index of the active tab in `tabs`, or nil if none.
    var activeIdx: Int? { tabs.firstIndex { $0.id == activeTabID } }

    // MARK: - Two-tier text: live in the NSTextView, snapshot in tabs[].text
    //
    // Typing no longer writes back through DocumentManager (that re-rendered the
    // whole ContentView on every keystroke — 性能-1). The LIVE text lives in the
    // editor's NSTextView; `tabs[].text` is a SNAPSHOT reconciled only at discrete
    // points (save, tab switch, palette open, terminate) — never per keystroke.

    /// Set by the editor coordinator on mount (like the find closures): returns the
    /// live text held in the active NSTextView. `reconcileActiveText` pulls through
    /// this to refresh the snapshot.
    var pullActiveText: (() -> String)?

    /// Set by the editor coordinator on mount (like `pullActiveText`): returns the
    /// live vertical scroll offset (document-space y of the viewport top) of the
    /// active editor. Pulled into `tabs[].scrollY` at discrete reconcile points and
    /// read directly by `snapshotSession` so a session save captures the *current*
    /// scroll without a per-frame write-back.
    var pullActiveScrollY: (() -> CGFloat)?

    /// Pull the editor's live text (and scroll offset) into the active tab's
    /// snapshot, each ONLY when it actually differs — self-guarded single `@Published`
    /// mutations. Call at every discrete read point BEFORE reading `tabs[]`.
    func reconcileActiveText() {
        guard let idx = activeIdx else { return }
        if let pull = pullActiveText {
            let live = pull()
            if tabs[idx].text != live { tabs[idx].text = live }
        }
        if let pullY = pullActiveScrollY {
            let y = pullY()
            if tabs[idx].scrollY != y { tabs[idx].scrollY = y }
        }
    }

    /// Flip the active tab to dirty as a discrete transition — one publish. Self-
    /// guards so repeated calls (e.g. every keystroke) never re-publish.
    func markActiveDirty() {
        guard let idx = activeIdx, !tabs[idx].isDirty else { return }
        tabs[idx].isDirty = true
    }

    /// Single entry point for changing the active tab. Reconciles the OUTGOING
    /// tab's live text into its snapshot FIRST (so its edits survive the switch),
    /// then assigns `activeTabID`. ALL `activeTabID` writes route through here.
    func activateTab(_ id: UUID?) {
        reconcileActiveText()
        activeTabID = id
        scheduleSessionSave()
    }

    // MARK: - Actions

    func openTab(for url: URL, text: String) {
        if let existing = tabs.first(where: { $0.url?.path == url.path }) {
            activateTab(existing.id)
            return
        }
        let tab = DocumentTab(url: url, name: url.lastPathComponent, text: text, isDirty: false,
                              isMarkdown: DocumentTab.isMarkdownExtension(of: url))
        tabs.append(tab)
        activateTab(tab.id)
        MVLog.info("open document: \(tab.name)", category: "document")
        Toaster.shared.flash("已打开 " + tab.name)
    }

    func newDocument(text: String = "") {
        let tab = DocumentTab(url: nil, name: "未命名.md", text: text, isDirty: true)
        tabs.append(tab)
        activateTab(tab.id)
        MVLog.info("new document", category: "document")
    }

    /// Two-stage close. A dirty tab's first × shows the "确认关闭?" capsule and
    /// arms a 2.6s reset; a second click within the window (or any click on a
    /// clean tab) closes for real. Designed as the single close entry point so
    /// ⌘W (future C5) can reuse it.
    func requestClose(_ tab: DocumentTab) {
        if tab.isDirty && confirmingCloseTabID != tab.id {
            confirmingCloseTabID = tab.id
            let armedID = tab.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
                guard let self else { return }
                if self.confirmingCloseTabID == armedID {
                    self.confirmingCloseTabID = nil
                }
            }
            return
        }
        doClose(tab)
    }

    func doClose(_ tab: DocumentTab) {
        MVLog.info("close document: \(tab.name)", category: "document")
        // If the closing tab is the active one, pull its LIVE editor text into the
        // snapshot first so a later reopen restores the just-typed (unsaved) text,
        // then capture that fresh snapshot as lastClosedTab.
        if tab.id == activeTabID { reconcileActiveText() }
        let closing = tabs.first { $0.id == tab.id } ?? tab
        let idx = tabs.firstIndex(where: { $0.id == tab.id })
        lastClosedTab = closing
        tabs.removeAll { $0.id == tab.id }
        if confirmingCloseTabID == tab.id { confirmingCloseTabID = nil }
        if activeTabID == tab.id {
            // Activate the tab that slid into the same slot, else the last one.
            // The closed tab is already gone (and reconciled above), so activateTab's
            // reconcile of the outgoing tab is a no-op here — routed for consistency.
            if let idx, !tabs.isEmpty {
                activateTab(tabs[min(idx, tabs.count - 1)].id)
            } else {
                activateTab(nil)
            }
        }
        // Closing a non-active tab changes the tab set without touching activeTabID
        // (so activateTab's save above never fires) — persist the new set here too.
        scheduleSessionSave()
    }

    func reopenClosed() {
        guard let tab = lastClosedTab else { return }
        lastClosedTab = nil
        tabs.append(tab)
        activateTab(tab.id)
    }

    // MARK: - Session persistence
    //
    // Remember where the user left off (open tabs incl. unsaved content, active tab,
    // font, sidebar geometry, opened folder, per-tab scroll) and restore it on the
    // next launch. Saves are DEBOUNCED for high-frequency triggers (typing/scroll)
    // and forced synchronously on terminate; the debounce path builds+writes only
    // and must never mutate `@Published` (no re-render).

    /// Debounced session-save work item — cancelled/rescheduled on every trigger.
    private var sessionSaveWork: DispatchWorkItem?

    /// Build a `Session` from the CURRENT state WITHOUT mutating any `@Published`.
    /// For the ACTIVE tab, pull the LIVE text + scroll offset through the editor
    /// channels into a LOCAL copy so the snapshot is up to date without a per-keystroke
    /// write-back into `tabs[].text` (which would re-render). Non-active tabs use their
    /// already-reconciled snapshots.
    func snapshotSession() -> Session {
        var snap = tabs  // local value copy — mutating it never touches @Published tabs
        if let idx = activeIdx {
            if let pull = pullActiveText { snap[idx].text = pull() }
            if let pullY = pullActiveScrollY { snap[idx].scrollY = pullY() }
        }
        return Session(
            tabs: snap,
            activeTabID: activeTabID,
            fontIndex: fontIndex,
            sidebarWidth: sidebarWidth,
            sidebarOpen: sidebarOpen,
            directoryPath: directoryURL?.path
        )
    }

    /// Persist the current session NOW (synchronous, best-effort). Used by the
    /// terminate hook and by the debounce block.
    func saveSession() {
        SessionStore.save(snapshotSession())
    }

    /// Debounced session save (~1s) for high-frequency triggers (typing, scrolling)
    /// and reused by discrete events. Deliberately mutates NO `@Published` state — it
    /// only (re)schedules a work item that builds a snapshot and writes it, so it can
    /// never itself cause a re-render.
    func scheduleSessionSave() {
        sessionSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveSession()
        }
        sessionSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Rebuild in-memory state from a saved session. Sets tabs/active/font/sidebar;
    /// if the saved folder still exists, rebuilds the sidebar tree from it (no file is
    /// auto-opened — tabs are already restored). Restored dirty tabs keep `isDirty`
    /// and their unsaved text; nothing is written to disk here. `fontIndex` is set
    /// FIRST so the editor seeds the correct body size when it mounts (Phase-1
    /// `lastStyledBodySize` seeding in makeNSView reads the current fontIndex).
    func restore(from s: Session) {
        fontIndex = max(0, min(DesignTokens.bodyFontSizes.count - 1, s.fontIndex))
        sidebarWidth = s.sidebarWidth
        sidebarOpen = s.sidebarOpen
        tabs = s.tabs
        // Fall back to the first tab if the saved active id no longer matches.
        activeTabID = (s.activeTabID.flatMap { id in tabs.first { $0.id == id }?.id })
            ?? tabs.first?.id
        // Rebuild the sidebar tree from the saved folder if it still exists. tabs is
        // already non-empty, so loadDirectory's first-file auto-open never fires.
        if let path = s.directoryPath,
           FileManager.default.fileExists(atPath: path) {
            loadDirectory(URL(fileURLWithPath: path))
        }
        MVLog.info("session restored: \(tabs.count) tab(s), font \(fontIndex)", category: "session")
    }

    // MARK: - Font

    /// Single entry point for body-font changes. Clamps to a valid index,
    /// updates `fontIndex`, and flashes the size (e.g. "正文字号 15.5px").
    func applyFont(_ idx: Int) {
        let clamped = max(0, min(DesignTokens.bodyFontSizes.count - 1, idx))
        fontIndex = clamped
        let size = DesignTokens.bodyFontSizes[clamped]
        // Show "14" for integers and "15.5" for fractions (no trailing ".0").
        let label = size == size.rounded()
            ? String(Int(size))
            : String(Double(size))
        Toaster.shared.flash("正文字号 " + label + "px")
        scheduleSessionSave()
    }

    // MARK: - File I/O

    func openDocument() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.hasDirectoryPath {
            loadDirectory(url)
        } else {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            openTab(for: url, text: text)
        }
    }

    func saveCurrent() {
        // Reconcile the live editor text into the snapshot BEFORE reading it, so we
        // write the current (just-typed, unsaved) content to disk.
        reconcileActiveText()
        guard let tab = activeTab else { return }
        if let url = tab.url {
            do {
                try tab.text.write(to: url, atomically: true, encoding: .utf8)
                if let idx = tabs.firstIndex(where: { $0.id == tab.id }) {
                    tabs[idx].isDirty = false
                }
                Toaster.shared.flash("已保存 " + tab.name)
                scheduleSessionSave()
            } catch {
                return
            }
        } else {
            saveAsCurrent()
        }
    }

    func saveAsCurrent() {
        // Reconcile live editor text into the snapshot before reading tabs[idx].text.
        reconcileActiveText()
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType.plainText, UTType(filenameExtension: "md")!]
        savePanel.nameFieldStringValue = activeTab?.name ?? "未命名.md"
        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }
        if let idx = tabs.firstIndex(where: { $0.id == activeTabID }) {
            do {
                try tabs[idx].text.write(to: url, atomically: true, encoding: .utf8)
                tabs[idx].url = url
                tabs[idx].name = url.lastPathComponent
                tabs[idx].isDirty = false
                Toaster.shared.flash("已保存 " + tabs[idx].name)
                scheduleSessionSave()
            } catch {
                return
            }
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

struct DocumentTab: Identifiable, Codable {
    let id: UUID
    var url: URL?
    var name: String
    var text: String
    var isDirty: Bool
    /// Whether the document renders as live Markdown. Derived from the file
    /// extension: `.md`/`.markdown` → true; untitled/new docs (url == nil) → true;
    /// everything else (e.g. .yaml/.json) → false, shown as plain source.
    var isMarkdown: Bool = true
    /// Persisted vertical scroll offset (document-space y of the viewport top) so a
    /// restored tab reopens where it was left. Kept in sync with the live NSTextView
    /// only at discrete reconcile points (never per scroll frame) — see
    /// DocumentManager.reconcileActiveText / snapshotSession.
    var scrollY: CGFloat = 0

    /// Memberwise init with a defaulted `id` (so decode can supply the persisted id
    /// while the app's own creators — openTab/newDocument — get a fresh one).
    init(id: UUID = UUID(), url: URL?, name: String, text: String,
         isDirty: Bool, isMarkdown: Bool = true, scrollY: CGFloat = 0) {
        self.id = id
        self.url = url
        self.name = name
        self.text = text
        self.isDirty = isDirty
        self.isMarkdown = isMarkdown
        self.scrollY = scrollY
    }

    /// Explicit keys: `id` is persisted (it is otherwise a fresh-per-instance UUID),
    /// and `url` is stored as an optional *path string* rather than a URL container.
    enum CodingKeys: String, CodingKey {
        case id, url, name, text, isDirty, isMarkdown, scrollY
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        // Stored as a plain filesystem path (see encode); nil = untitled/new doc.
        if let path = try c.decodeIfPresent(String.self, forKey: .url) {
            url = URL(fileURLWithPath: path)
        } else {
            url = nil
        }
        name = try c.decode(String.self, forKey: .name)
        text = try c.decode(String.self, forKey: .text)
        isDirty = try c.decode(Bool.self, forKey: .isDirty)
        isMarkdown = try c.decodeIfPresent(Bool.self, forKey: .isMarkdown) ?? true
        scrollY = try c.decodeIfPresent(CGFloat.self, forKey: .scrollY) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(url?.path, forKey: .url)
        try c.encode(name, forKey: .name)
        try c.encode(text, forKey: .text)
        try c.encode(isDirty, forKey: .isDirty)
        try c.encode(isMarkdown, forKey: .isMarkdown)
        try c.encode(scrollY, forKey: .scrollY)
    }

    /// Classify a file URL as Markdown. `nil` (untitled/new) is treated as Markdown.
    static func isMarkdownExtension(of url: URL?) -> Bool {
        guard let url else { return true }
        return ["md", "markdown"].contains(url.pathExtension.lowercased())
    }
}
