import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Central state for the Markdown Viewer app.
/// Two-tier text model: while editing, the LIVE text lives in the editor's
/// NSTextView; `tabs[i].text` is a SNAPSHOT reconciled from it only at discrete
/// points (save, tab switch, palette open, terminate) via `reconcileActiveText`,
/// never per keystroke.
@MainActor
final class DocumentManager: ObservableObject {
    typealias DocumentWriter = (_ text: String, _ url: URL) throws -> Void
    typealias DocumentReader = (_ url: URL) throws -> String

    private struct DocumentFileContents {
        let text: String
        let hasUTF8BOM: Bool
        let rawData: Data?
    }

    private enum DocumentFileError: Error {
        case invalidUTF8
    }

    private let sessionURL: URL
    private let sessionSaveDelay: TimeInterval
    private let visualTestEnabled: Bool

    init(
        sessionURL: URL = SessionStore.fileURL,
        sessionSaveDelay: TimeInterval = 1.0,
        visualTestEnabled: Bool = AppEnv.visualTest
    ) {
        self.sessionURL = sessionURL
        self.sessionSaveDelay = sessionSaveDelay
        self.visualTestEnabled = visualTestEnabled
    }

    // MARK: - Sidebar
    @Published var sidebarWidth: CGFloat = DesignTokens.sidebarWidth
    @Published var sidebarOpen: Bool = true
    @Published var directoryURL: URL?
    @Published var fileTree: [FileNode] = []
    @Published var expandedFolders: Set<String> = []

    // MARK: - Tabs (single source of truth)
    @Published var tabs: [DocumentTab] = []
    @Published var activeTabID: UUID?
    @Published var lastClosedTab: DocumentTab?
    /// Tab currently awaiting a confirm-close second click (dirty tabs only).
    @Published var confirmingCloseTabID: UUID?
    @Published private(set) var lastSaveFailure: DocumentSaveFailure?
    private var blockEditorStores: [UUID: BlockEditorStore] = [:]
    private var blockEditorStoreGenerations: [UUID: UUID] = [:]
    private var autoFocusBlockEditorTabIDs: Set<UUID> = []
    /// The URL-less in-memory tab loaded from the Debug fixture. Its matching
    /// workspace sidebar row is identified by name without assigning the tab a URL,
    /// so Save still cannot overwrite the bundled read-only fixture.
    private var visualTestFixtureTabID: UUID?

    // MARK: - Font
    @Published var fontIndex: Int = 1

    // MARK: - Reading / editing mode
    @Published var previewMode: Bool = false

    // MARK: - Overlays
    @Published private(set) var paletteOpen: Bool = false

    /// Open the command palette only after the active editor has crossed its
    /// lifecycle boundary. This keeps block drafts, native table fields, and
    /// plain-source selections coherent before the palette takes key focus.
    func openCommandPalette() {
        guard !paletteOpen else { return }
        reconcileActiveText()
        paletteOpen = true
    }

    func closeCommandPalette() {
        guard paletteOpen else { return }
        paletteOpen = false
    }

    func toggleCommandPalette() {
        if paletteOpen {
            closeCommandPalette()
        } else {
            openCommandPalette()
        }
    }

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

    /// Returns the active block store's lossless document, including stable block
    /// IDs. Lifecycle snapshots use this instead of reparsing the source string.
    var pullActiveMarkdownDocument: (() -> MarkdownDocument?)?

    /// Commits an active block source editor or table grid before a lifecycle
    /// boundary reads or switches the document.
    var commitActiveEditing: (() -> Void)?

    /// Set by the editor coordinator on mount (like `pullActiveText`): returns the
    /// live vertical scroll offset (document-space y of the viewport top) of the
    /// active editor. Pulled into `tabs[].scrollY` at discrete reconcile points and
    /// read directly by `snapshotSession` so a session save captures the *current*
    /// scroll without a per-frame write-back.
    var pullActiveScrollY: (() -> CGFloat)?

    /// Returns the live AppKit UTF-16 selection for the active plain-source tab.
    /// It is sampled only at lifecycle boundaries, like text and scroll position.
    var pullActiveSelection: (() -> NSRange?)?

    /// Pull the editor's live text (and scroll offset) into the active tab's
    /// snapshot, each ONLY when it actually differs — self-guarded single `@Published`
    /// mutations. Call at every discrete read point BEFORE reading `tabs[]`.
    func reconcileActiveText() {
        let liveSelection = pullActiveSelection?()
        commitActiveEditing?()
        guard let idx = activeIdx else { return }
        var updated = tabs[idx]
        var changed = false
        if updated.isMarkdown,
           let document = pullActiveMarkdownDocument?() {
            if updated.text != document.source {
                updated.text = document.source
                changed = true
            }
            if updated.markdownDocument != document {
                updated.markdownDocument = document
                changed = true
            }
        } else if let pull = pullActiveText {
            let live = pull()
            if updated.text != live {
                updated.text = live
                updated.markdownDocument = updated.isMarkdown
                    ? MarkdownDocument(source: live)
                    : nil
                changed = true
            }
        }
        if let pullY = pullActiveScrollY {
            let y = pullY()
            if updated.scrollY != y {
                updated.scrollY = y
                changed = true
            }
        }
        if let selection = liveSelection,
           updated.selectionLocation != selection.location
            || updated.selectionLength != selection.length {
            updated.selectionLocation = max(0, selection.location)
            updated.selectionLength = max(0, selection.length)
            changed = true
        }
        if changed {
            tabs[idx] = updated
        }
    }

    /// Flip the active tab to dirty as a discrete transition — one publish. Self-
    /// guards so repeated calls (e.g. every keystroke) never re-publish.
    func markActiveDirty() {
        guard let activeTabID else { return }
        markTabDirty(activeTabID)
    }

    private func markTabDirty(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              !tabs[index].isDirty else { return }
        tabs[index].isDirty = true
    }

    /// Single entry point for changing the active tab. Reconciles the OUTGOING
    /// tab's live text into its snapshot FIRST (so its edits survive the switch),
    /// then assigns `activeTabID`. ALL `activeTabID` writes route through here.
    func activateTab(_ id: UUID?) {
        guard id != activeTabID else { return }
        if let activeTabID {
            blockEditorStores[activeTabID]?.suspendEditingForTabSwitch()
        }
        reconcileActiveText()
        commitActiveEditing = nil
        pullActiveText = nil
        pullActiveMarkdownDocument = nil
        pullActiveScrollY = nil
        pullActiveSelection = nil
        activeTabID = id
        if let id, let store = blockEditorStores[id] {
            store.restoreEditingAfterTabSwitch()
            wireActiveBlockStore(store)
        }
        scheduleSessionSave()
    }

    func blockEditorStore(for tab: DocumentTab) -> BlockEditorStore {
        if let existing = blockEditorStores[tab.id] {
            if tab.id == activeTabID { wireActiveBlockStore(existing) }
            return existing
        }
        let storeGeneration = UUID()
        let store = BlockEditorStore(
            tabID: tab.id,
            document: tab.markdownDocument ?? MarkdownDocument(source: tab.text),
            onDraftDivergence: { [weak self] in
                self?.publishBlockStoreMutation(
                    for: tab.id,
                    generation: storeGeneration
                )
            }
        ) { [weak self] _ in
            self?.publishBlockStoreMutation(
                for: tab.id,
                generation: storeGeneration
            )
        }
        blockEditorStores[tab.id] = store
        blockEditorStoreGenerations[tab.id] = storeGeneration
        if autoFocusBlockEditorTabIDs.remove(tab.id) != nil,
           let firstBlockID = store.document.blocks.first?.id {
            store.beginSourceEditing(blockID: firstBlockID, selection: NSRange(location: 0, length: 0))
        }
        if tab.id == activeTabID { wireActiveBlockStore(store) }
        return store
    }

    private func wireActiveBlockStore(_ store: BlockEditorStore) {
        commitActiveEditing = { [weak store] in
            store?.flushActiveEditingForLifecycleBoundary()
        }
        pullActiveText = { [weak store] in store?.snapshotDocument().source ?? "" }
        pullActiveMarkdownDocument = { [weak store] in store?.snapshotDocument() }
        pullActiveSelection = { [weak store] in store?.snapshotSelection }
    }

    private func publishBlockStoreMutation(for tabID: UUID, generation: UUID) {
        guard blockEditorStoreGenerations[tabID] == generation,
              tabs.first(where: { $0.id == tabID })?.isMarkdown == true else {
            return
        }
        markTabDirty(tabID)
        scheduleSessionSave()
    }

    // MARK: - Actions

    func openTab(
        for url: URL,
        text: String,
        hasUTF8BOM: Bool = false,
        diskBaseline: DocumentDiskBaseline? = nil
    ) {
        let canonical = canonicalPath(for: url)
        if let existing = tabs.first(where: {
            $0.url.map(canonicalPath(for:)) == canonical
        }) {
            activateTab(existing.id)
            return
        }
        let resolvedBaseline = diskBaseline ?? matchingDiskBaseline(
            at: url,
            text: text,
            hasUTF8BOM: hasUTF8BOM
        )
        let tab = DocumentTab(
            url: url,
            name: url.lastPathComponent,
            text: text,
            isDirty: false,
            isMarkdown: DocumentTab.isMarkdownExtension(of: url),
            hasUTF8BOM: hasUTF8BOM,
            diskBaseline: resolvedBaseline
        )
        tabs.append(tab)
        activateTab(tab.id)
        MVLog.info("open document: \(tab.name)", category: "document")
        Toaster.shared.flash("已打开 " + tab.name)
    }

    func newDocument(text: String = "") {
        // A new untitled document is an editing action. Leave the global reading
        // mode before activating the new tab so its auto-focused first block is
        // visible as an editor on the first render.
        if previewMode { previewMode = false }
        let existingNames = Set(tabs.map(\.name))
        var ordinal = 1
        var name = "未命名.md"
        while existingNames.contains(name) {
            ordinal += 1
            name = "未命名 \(ordinal).md"
        }
        let tab = DocumentTab(url: nil, name: name, text: text, isDirty: true)
        tabs.append(tab)
        autoFocusBlockEditorTabIDs.insert(tab.id)
        activateTab(tab.id)
        MVLog.info("new document", category: "document")
    }

    /// Replace the workspace with an editable in-memory copy of a Debug fixture.
    /// The tab deliberately has no file URL, so Save can never overwrite the
    /// read-only fixture bundled into the Debug app.
    func loadVisualTestDocument(name: String, text: String, scrollY: CGFloat) {
        guard visualTestEnabled else { return }
        let tab = DocumentTab(
            url: nil,
            name: name,
            text: text,
            isDirty: false,
            isMarkdown: true,
            scrollY: scrollY
        )
        tabs = [tab]
        visualTestFixtureTabID = tab.id
        blockEditorStores.removeAll()
        blockEditorStoreGenerations.removeAll()
        autoFocusBlockEditorTabIDs.removeAll()
        activeTabID = tab.id
        lastClosedTab = nil
        confirmingCloseTabID = nil
        MVLog.info("visual-test fixture loaded: \(name)", category: "document")
        scheduleSessionSave()
    }

    func togglePreviewMode() {
        togglePreviewMode(toaster: .shared)
    }

    func togglePreviewMode(toaster: Toaster) {
        guard activeTab?.isMarkdown == true else { return }
        reconcileActiveText()
        previewMode.toggle()
        toaster.flash(previewMode ? "纯预览 · 点击笔重新编辑" : "编辑模式")
    }

    func toggleSidebar() {
        sidebarOpen.toggle()
        scheduleSessionSave()
    }

    /// Two-stage close. A dirty tab's first × shows the "确认关闭?" capsule and
    /// arms a 2.6s reset; a second click within the window (or any click on a
    /// clean tab) closes for real. Designed as the single close entry point so
    /// ⌘W (future C5) can reuse it.
    func requestClose(_ tab: DocumentTab) {
        if tab.id == activeTabID {
            reconcileActiveText()
        }
        guard let current = tabs.first(where: { $0.id == tab.id }) else { return }
        if current.isDirty && confirmingCloseTabID != current.id {
            confirmingCloseTabID = current.id
            let armedID = current.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
                guard let self else { return }
                if self.confirmingCloseTabID == armedID {
                    self.confirmingCloseTabID = nil
                }
            }
            return
        }
        doClose(current)
    }

    func doClose(_ tab: DocumentTab) {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        MVLog.info("close document: \(tab.name)", category: "document")
        // If the closing tab is the active one, pull its LIVE editor text into the
        // snapshot first so a later reopen restores the just-typed (unsaved) text,
        // then capture that fresh snapshot as lastClosedTab.
        if tab.id == activeTabID { reconcileActiveText() }
        let closing = tabs[idx]
        lastClosedTab = closing
        tabs.removeAll { $0.id == tab.id }
        blockEditorStores.removeValue(forKey: tab.id)
        blockEditorStoreGenerations.removeValue(forKey: tab.id)
        autoFocusBlockEditorTabIDs.remove(tab.id)
        if confirmingCloseTabID == tab.id { confirmingCloseTabID = nil }
        if activeTabID == tab.id {
            // Activate the tab that slid into the same slot, else the last one.
            // The closed tab is already gone (and reconciled above), so activateTab's
            // reconcile of the outgoing tab is a no-op here — routed for consistency.
            if !tabs.isEmpty {
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
        guard !tabs.contains(where: { $0.id == tab.id }) else { return }
        tabs.append(tab)
        activateTab(tab.id)
    }

    /// Route undo through AppKit first so an active text field gets first refusal,
    /// then fall back to the active block document's per-tab undo history.
    @discardableResult
    func undoActiveEdit(
        sendingFirstResponderAction send: ((Selector) -> Bool)? = nil
    ) -> Bool {
        let action = NSSelectorFromString("undo:")
        let handled = send?(action)
            ?? NSApplication.shared.sendAction(action, to: nil, from: nil)
        if handled { return true }
        guard let id = activeTabID,
              let store = blockEditorStores[id],
              store.undoManager.canUndo else { return false }
        store.undoManager.undo()
        return true
    }

    /// Route redo through AppKit first, with the active block store as a fallback.
    @discardableResult
    func redoActiveEdit(
        sendingFirstResponderAction send: ((Selector) -> Bool)? = nil
    ) -> Bool {
        let action = NSSelectorFromString("redo:")
        let handled = send?(action)
            ?? NSApplication.shared.sendAction(action, to: nil, from: nil)
        if handled { return true }
        guard let id = activeTabID,
              let store = blockEditorStores[id],
              store.undoManager.canRedo else { return false }
        store.undoManager.redo()
        return true
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
            if snap[idx].isMarkdown,
               let document = pullActiveMarkdownDocument?() {
                let diverged = snap[idx].text != document.source
                snap[idx].text = document.source
                snap[idx].markdownDocument = document
                if diverged { snap[idx].isDirty = true }
            } else if let pull = pullActiveText {
                let liveText = pull()
                if snap[idx].text != liveText { snap[idx].isDirty = true }
                snap[idx].text = liveText
            }
            if let pullY = pullActiveScrollY { snap[idx].scrollY = pullY() }
            if let selection = pullActiveSelection?() {
                snap[idx].selectionLocation = max(0, selection.location)
                snap[idx].selectionLength = max(0, selection.length)
            }
        }
        return Session(
            tabs: snap,
            activeTabID: activeTabID,
            fontIndex: fontIndex,
            sidebarWidth: sidebarWidth,
            sidebarOpen: sidebarOpen,
            directoryPath: directoryURL?.path,
            expandedFolderPaths: Array(expandedFolders).sorted()
        )
    }

    /// Persist the current session NOW (synchronous, best-effort). Used by the
    /// terminate hook and by the debounce block.
    func saveSession() {
        SessionStore.save(snapshotSession(), to: sessionURL)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + sessionSaveDelay, execute: work)
    }

    /// Rebuild in-memory state from a saved session. Sets tabs/active/font/sidebar;
    /// if the saved folder still exists, rebuilds the sidebar tree from it (no file is
    /// auto-opened — tabs are already restored). Restored dirty tabs keep `isDirty`
    /// and their unsaved text; nothing is written to disk here. `fontIndex` is set
    /// FIRST so the editor seeds the correct body size when it mounts (Phase-1
    /// `lastStyledBodySize` seeding in makeNSView reads the current fontIndex).
    func restore(from s: Session) {
        let preexistingTabs = tabs
        let preexistingActiveTabID = activeTabID
        fontIndex = max(0, min(DesignTokens.bodyFontSizes.count - 1, s.fontIndex))
        sidebarWidth = max(
            DesignTokens.sidebarMinWidth,
            min(DesignTokens.sidebarMaxWidth, s.sidebarWidth)
        )
        sidebarOpen = s.sidebarOpen
        tabs = s.tabs.map(reconciledRestoredTab)
        var preferredPreexistingActiveTabID = preexistingActiveTabID
        for pending in preexistingTabs {
            let matchingIndex = tabs.firstIndex { restored in
                restored.id == pending.id
                    || canonicalURLsMatch(restored.url, pending.url)
            }
            if let matchingIndex {
                if tabs[matchingIndex].isDirty && !pending.isDirty {
                    if pending.id == preexistingActiveTabID {
                        preferredPreexistingActiveTabID = tabs[matchingIndex].id
                    }
                } else {
                    tabs[matchingIndex] = pending
                }
            } else {
                tabs.append(pending)
            }
        }
        visualTestFixtureTabID = nil
        blockEditorStores.removeAll()
        blockEditorStoreGenerations.removeAll()
        autoFocusBlockEditorTabIDs.removeAll()
        commitActiveEditing = nil
        pullActiveText = nil
        pullActiveMarkdownDocument = nil
        pullActiveScrollY = nil
        pullActiveSelection = nil
        lastClosedTab = nil
        confirmingCloseTabID = nil
        // Fall back to the first tab if the saved active id no longer matches.
        activeTabID = (preferredPreexistingActiveTabID.flatMap { id in
            tabs.first { $0.id == id }?.id
        })
            ?? (s.activeTabID.flatMap { id in tabs.first { $0.id == id }?.id })
            ?? tabs.first?.id
        // Rebuild the sidebar tree from the saved folder if it still exists. tabs is
        // already non-empty, so loadDirectory's first-file auto-open never fires.
        directoryURL = nil
        fileTree = []
        expandedFolders = []
        if let path = s.directoryPath {
            let savedDirectory = URL(fileURLWithPath: path, isDirectory: true)
            let isDirectory = (try? savedDirectory.resourceValues(
                forKeys: [.isDirectoryKey]
            ).isDirectory) ?? false
            if isDirectory {
                loadDirectory(savedDirectory)
                if let saved = s.expandedFolderPaths {
                    expandedFolders = Set(saved)
                }
            }
        }
        MVLog.info("session restored: \(tabs.count) tab(s), font \(fontIndex)", category: "session")
    }

    /// Restore an isolated visual-test session and reconnect its URL-less fixture
    /// tab to the matching workspace row. The binding is accepted only when both
    /// the restored tabs and restored file tree contain one unambiguous match.
    func restoreVisualTestSession(from session: Session, fixtureName: String) {
        guard visualTestEnabled else { return }
        restore(from: session)

        let tabMatches = tabs.filter {
            $0.url == nil && $0.isMarkdown && $0.name == fixtureName
        }
        let workspaceMatches = matchingWorkspaceFiles(
            named: fixtureName,
            in: fileTree
        )
        guard tabMatches.count == 1, workspaceMatches.count == 1 else {
            MVLog.warn(
                "visual-test fixture binding is ambiguous after restore",
                category: "session"
            )
            return
        }
        visualTestFixtureTabID = tabMatches[0].id
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

    /// Shared admission and loading path for the system panel, Finder open events,
    /// and drag-and-drop. Duplicate canonical paths activate the existing tab before
    /// touching disk, preserving any unsaved in-memory source.
    @discardableResult
    func openSelection(
        _ url: URL?,
        admission: DocumentOpenAdmission
    ) -> DocumentOpenResult {
        openSelection(url, admission: admission, documentReader: nil)
    }

    @discardableResult
    func openSelection(
        _ url: URL?,
        admission: DocumentOpenAdmission,
        reader: @escaping DocumentReader
    ) -> DocumentOpenResult {
        openSelection(url, admission: admission, documentReader: reader)
    }

    private func openSelection(
        _ url: URL?,
        admission: DocumentOpenAdmission,
        documentReader: DocumentReader?
    ) -> DocumentOpenResult {
        guard let url else { return .cancelled }
        guard url.isFileURL else {
            Toaster.shared.flash(admission.unsupportedMessage)
            return .rejectedUnsupported
        }

        let isDirectory = (try? url.resourceValues(
            forKeys: [.isDirectoryKey]
        ).isDirectory) == true
        if isDirectory {
            guard admission.allowsDirectories else {
                Toaster.shared.flash(admission.unsupportedMessage)
                return .rejectedUnsupported
            }
            loadDirectory(url)
            return .openedDirectory(url)
        }

        guard admission.acceptsFile(url) else {
            Toaster.shared.flash(admission.unsupportedMessage)
            return .rejectedUnsupported
        }

        let canonical = canonicalPath(for: url)
        if let existing = tabs.first(where: {
            $0.url.map(canonicalPath(for:)) == canonical
        }) {
            activateTab(existing.id)
            return .activatedExisting(existing.id)
        }

        let contents: DocumentFileContents
        do {
            if let documentReader {
                let text = try documentReader(url)
                let rawData = try? Data(contentsOf: url)
                contents = DocumentFileContents(
                    text: text,
                    hasUTF8BOM: false,
                    rawData: rawData == Self.encodedUTF8Data(text, hasBOM: false)
                        ? rawData
                        : nil
                )
            } else {
                contents = try Self.readDocumentFile(at: url)
            }
        } catch {
            MVLog.warn("open failed: \(url.path), \(error)", category: "document")
            Toaster.shared.flash("无法打开文件")
            return .failedToRead
        }

        openTab(
            for: url,
            text: contents.text,
            hasUTF8BOM: contents.hasUTF8BOM,
            diskBaseline: contents.rawData.map {
                DocumentDiskBaseline(canonicalPath: canonical, bytes: $0)
            }
        )
        guard let activeTabID else { return .failedToRead }
        return .openedFile(activeTabID)
    }

    func openDocument() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = DocumentFormat.openPanelContentTypes
        let selection = panel.runModal() == .OK ? panel.url : nil
        openSelection(selection, admission: .openPanel)
    }

    func saveCurrent() {
        guard let tab = activeTab else { return }
        if tab.url != nil {
            if saveActiveDocument() {
                Toaster.shared.flash("已保存 " + tab.name)
            } else {
                Toaster.shared.flash(saveFailureMessage)
            }
        } else {
            saveAsCurrent()
        }
    }

    func saveAsCurrent() {
        // Capture native marked text before the panel can move first responder.
        _ = synchronizeActiveEditorForSave()
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = DocumentFormat.openPanelContentTypes
        savePanel.nameFieldStringValue = activeTab?.name ?? "未命名.md"
        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }
        if saveActiveDocument(to: url) {
            Toaster.shared.flash("已保存 " + url.lastPathComponent)
        } else {
            Toaster.shared.flash(saveFailureMessage)
        }
    }

    /// Save the active document without presenting UI. Supplying a destination
    /// performs Save As and updates tab identity only after the write succeeds.
    @discardableResult
    func saveActiveDocument(to destinationURL: URL? = nil) -> Bool {
        return saveActiveDocument(to: destinationURL) { text, url in
            guard let current = self.activeTab else { throw DocumentFileError.invalidUTF8 }
            try Self.encodedUTF8Data(text, hasBOM: current.hasUTF8BOM)
                .write(to: url, options: .atomic)
        }
    }

    /// Writer-injected variant used by lifecycle tests and non-UI callers.
    @discardableResult
    func saveActiveDocument(
        to destinationURL: URL? = nil,
        writer: DocumentWriter
    ) -> Bool {
        lastSaveFailure = nil
        guard let snapshot = synchronizeActiveEditorForSave(),
              let idx = tabs.firstIndex(where: { $0.id == snapshot.id }) else {
            lastSaveFailure = .writeFailed
            return false
        }
        let current = tabs[idx]
        guard let requestedTarget = destinationURL ?? current.url else {
            lastSaveFailure = .unsupportedDestination
            return false
        }
        let currentCanonical = current.url.map(canonicalPath(for:))
        let requestedCanonical = canonicalPath(for: requestedTarget)
        let savesCurrentCanonicalPath = currentCanonical == requestedCanonical
        let target = savesCurrentCanonicalPath ? (current.url ?? requestedTarget) : requestedTarget
        let format = DocumentFormat(url: target)
        guard format.isOpenable else {
            lastSaveFailure = .unsupportedDestination
            return false
        }

        let canonicalTarget = canonicalPath(for: target)
        let writeTarget = URL(fileURLWithPath: canonicalTarget)
        guard !tabs.contains(where: { candidate in
            candidate.id != current.id
                && candidate.url.map(canonicalPath(for:)) == canonicalTarget
        }) else {
            MVLog.warn("save as target already open: \(target.path)", category: "document")
            lastSaveFailure = .destinationAlreadyOpen
            return false
        }

        if savesCurrentCanonicalPath,
           let conflict = externalFileConflict(for: current, canonicalPath: canonicalTarget) {
            MVLog.warn(
                "save rejected by external-file conflict: \(conflict)",
                category: "document"
            )
            lastSaveFailure = .conflict(conflict)
            return false
        }

        let expectedBytes = Self.encodedUTF8Data(
            current.text,
            hasBOM: current.hasUTF8BOM
        )

        do {
            try writer(current.text, writeTarget)
        } catch {
            MVLog.warn("save failed: \(error)", category: "document")
            lastSaveFailure = .writeFailed
            return false
        }

        let writtenBytes: Data
        do {
            writtenBytes = try Data(contentsOf: writeTarget)
            guard writtenBytes == expectedBytes else {
                MVLog.warn("save verification failed: bytes differ", category: "document")
                lastSaveFailure = .writeFailed
                return false
            }
        } catch {
            MVLog.warn("save verification failed: \(error)", category: "document")
            lastSaveFailure = .writeFailed
            return false
        }

        // A previously nonexistent target can acquire a different resolved path
        // after creation, such as /private/tmp becoming /tmp. Persist only the
        // post-write identity so the next ordinary save compares like with like.
        let persistedCanonicalTarget = canonicalPath(for: writeTarget)

        guard let savedIndex = tabs.firstIndex(where: { $0.id == current.id }) else {
            lastSaveFailure = .writeFailed
            return false
        }
        var saved = tabs[savedIndex]
        saved.url = target
        saved.name = target.lastPathComponent
        saved.isDirty = false
        saved.isMarkdown = format.isMarkdownRendered
        saved.diskBaseline = DocumentDiskBaseline(
            canonicalPath: persistedCanonicalTarget,
            bytes: writtenBytes
        )
        if saved.isMarkdown {
            if saved.markdownDocument?.source != saved.text {
                saved.markdownDocument = MarkdownDocument(source: saved.text)
            }
            if let document = saved.markdownDocument {
                blockEditorStores[saved.id]?.acceptSavedDocument(document)
            }
        } else {
            saved.markdownDocument = nil
            blockEditorStores.removeValue(forKey: saved.id)
            blockEditorStoreGenerations.removeValue(forKey: saved.id)
            pullActiveMarkdownDocument = nil
            commitActiveEditing = nil
        }
        tabs[savedIndex] = saved
        scheduleSessionSave()
        return true
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DocumentFormat.openPanelContentTypes
        let selection = panel.runModal() == .OK ? panel.url : nil
        openSelection(selection, admission: .openPanel)
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
        expandedFolders = Set(allFolderIDs(in: fileTree))
        if let first = firstTextFile(in: fileTree), tabs.isEmpty {
            _ = openSelection(first, admission: .system)
        }
    }

    func openFileNode(_ node: FileNode) {
        if let fixture = tabs.first(where: { tabRepresentsFileNode($0, node: node) }) {
            activateTab(fixture.id)
            return
        }
        guard !node.isDirectory else { return }
        _ = openSelection(node.url, admission: .system)
    }

    /// Whether a tab is represented by a concrete sidebar row. Normal documents
    /// match by canonical URL. The one URL-less visual fixture tab matches only its
    /// same-named workspace row.
    func tabRepresentsFileNode(_ tab: DocumentTab, node: FileNode) -> Bool {
        guard !node.isDirectory else { return false }
        if let url = tab.url {
            return canonicalPath(for: url) == canonicalPath(for: node.url)
        }
        return visualTestEnabled
            && tab.id == visualTestFixtureTabID
            && tab.name == node.name
    }

    func isActiveFileNode(_ node: FileNode) -> Bool {
        guard let activeTab else { return false }
        return tabRepresentsFileNode(activeTab, node: node)
    }

    func fileNodeHasDirtyTab(_ node: FileNode) -> Bool {
        tabs.contains { $0.isDirty && tabRepresentsFileNode($0, node: node) }
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
        }.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let order = lhs.name.compare(
                rhs.name,
                options: [.caseInsensitive, .numeric],
                range: nil,
                locale: Locale(identifier: "en_US_POSIX")
            )
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.url.path < rhs.url.path
        }
    }

    private func firstTextFile(in nodes: [FileNode]) -> URL? {
        for node in nodes {
            if !node.isDirectory { return node.url }
            if let found = firstTextFile(in: node.children) { return found }
        }
        return nil
    }

    private func allFolderIDs(in nodes: [FileNode]) -> [String] {
        nodes.flatMap { node in
            node.isDirectory ? [node.id] + allFolderIDs(in: node.children) : []
        }
    }

    private func matchingWorkspaceFiles(
        named name: String,
        in nodes: [FileNode]
    ) -> [FileNode] {
        nodes.flatMap { node in
            if node.isDirectory {
                return matchingWorkspaceFiles(named: name, in: node.children)
            }
            return node.name == name ? [node] : []
        }
    }

    /// Read the live native editor into the tab snapshot without ending editing.
    /// This includes marked text because both native bridges expose their current
    /// NSTextView or field-editor string directly.
    private func synchronizeActiveEditorForSave() -> DocumentTab? {
        guard let idx = activeIdx else { return nil }
        var updated = tabs[idx]
        var changed = false
        let originalText = updated.text

        if updated.isMarkdown,
           let document = pullActiveMarkdownDocument?() {
            if updated.text != document.source {
                updated.text = document.source
                changed = true
            }
            if updated.markdownDocument != document {
                updated.markdownDocument = document
                changed = true
            }
        } else if let liveText = pullActiveText?(), updated.text != liveText {
            updated.text = liveText
            updated.markdownDocument = updated.isMarkdown
                ? MarkdownDocument(source: liveText)
                : nil
            changed = true
        }

        if updated.text != originalText, !updated.isDirty {
            updated.isDirty = true
            changed = true
        }
        if let selection = pullActiveSelection?(),
           updated.selectionLocation != selection.location
            || updated.selectionLength != selection.length {
            updated.selectionLocation = max(0, selection.location)
            updated.selectionLength = max(0, selection.length)
            changed = true
        }
        if let pullY = pullActiveScrollY {
            let y = pullY()
            if updated.scrollY != y {
                updated.scrollY = y
                changed = true
            }
        }
        if changed {
            tabs[idx] = updated
        }
        return updated
    }

    private var saveFailureMessage: String {
        switch lastSaveFailure {
        case .conflict(.modified):
            return "文件已在磁盘上更改，未覆盖"
        case .conflict(.deleted):
            return "文件已在磁盘上删除，未保存"
        case .conflict(.unreadable):
            return "无法读取磁盘文件，未覆盖"
        case .conflict(.baselineUnknown):
            return "无法确认磁盘版本，请另存为新文件"
        case .destinationAlreadyOpen:
            return "目标文件已打开，未保存"
        case .unsupportedDestination:
            return "不支持此保存位置"
        case .writeFailed, .none:
            return "保存失败"
        }
    }

    private func externalFileConflict(
        for tab: DocumentTab,
        canonicalPath: String
    ) -> ExternalFileConflict? {
        guard let baseline = tab.diskBaseline,
              baseline.canonicalPath == canonicalPath else {
            return .baselineUnknown
        }
        guard FileManager.default.fileExists(atPath: canonicalPath) else {
            return .deleted
        }
        do {
            let currentBytes = try Data(contentsOf: URL(fileURLWithPath: canonicalPath))
            return currentBytes == baseline.bytes ? nil : .modified
        } catch {
            return .unreadable
        }
    }

    private func matchingDiskBaseline(
        at url: URL,
        text: String,
        hasUTF8BOM: Bool
    ) -> DocumentDiskBaseline? {
        guard let bytes = try? Data(contentsOf: url),
              bytes == Self.encodedUTF8Data(text, hasBOM: hasUTF8BOM) else {
            return nil
        }
        return DocumentDiskBaseline(
            canonicalPath: canonicalPath(for: url),
            bytes: bytes
        )
    }

    private func reconciledRestoredTab(_ persisted: DocumentTab) -> DocumentTab {
        guard !persisted.isDirty, let url = persisted.url else { return persisted }
        var restored = persisted
        do {
            let contents = try Self.readDocumentFile(at: url)
            restored.text = contents.text
            restored.hasUTF8BOM = contents.hasUTF8BOM
            restored.diskBaseline = contents.rawData.map {
                DocumentDiskBaseline(
                    canonicalPath: canonicalPath(for: url),
                    bytes: $0
                )
            }
            restored.isMarkdown = DocumentFormat(url: url).isMarkdownRendered
            restored.markdownDocument = restored.isMarkdown
                ? MarkdownDocument(source: contents.text)
                : nil
            let textLength = (contents.text as NSString).length
            restored.selectionLocation = min(restored.selectionLocation, textLength)
            restored.selectionLength = min(
                restored.selectionLength,
                textLength - restored.selectionLocation
            )
        } catch {
            restored.isDirty = true
            restored.diskBaseline = nil
            MVLog.warn(
                "clean session tab could not be refreshed: \(url.path), \(error)",
                category: "session"
            )
        }
        return restored
    }

    private func canonicalURLsMatch(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        return canonicalPath(for: lhs) == canonicalPath(for: rhs)
    }

    private static func readDocumentFile(at url: URL) throws -> DocumentFileContents {
        let data = try Data(contentsOf: url)
        let bom = Data([0xEF, 0xBB, 0xBF])
        let hasUTF8BOM = data.starts(with: bom)
        let payload = hasUTF8BOM ? data.dropFirst(bom.count) : data[...]
        guard let text = String(data: Data(payload), encoding: .utf8) else {
            throw DocumentFileError.invalidUTF8
        }
        return DocumentFileContents(
            text: text,
            hasUTF8BOM: hasUTF8BOM,
            rawData: data
        )
    }

    private static func encodedUTF8Data(_ text: String, hasBOM: Bool) -> Data {
        var data = Data()
        if hasBOM {
            data.append(contentsOf: [0xEF, 0xBB, 0xBF])
        }
        data.append(contentsOf: text.utf8)
        return data
    }

    private func isTextFile(_ url: URL) -> Bool {
        DocumentFormat(url: url).isOpenable
    }

    private func canonicalPath(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: - Vim-like navigation

    struct VimNavState { var mode: VimMode = .normal }
    enum VimMode { case normal, insert }
    @Published var vim = VimNavState()
}
