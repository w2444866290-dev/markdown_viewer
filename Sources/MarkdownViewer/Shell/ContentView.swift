import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// Stateful detector for two eligible Shift presses inside the prototype's
/// 350 ms interval. Modifier eligibility remains at the NSEvent boundary so this
/// timing policy stays deterministic and directly testable.
final class DoubleShiftTracker {
    static let maximumInterval: TimeInterval = 0.35

    private var lastPress: TimeInterval?

    func registerPress(at timestamp: TimeInterval) -> Bool {
        if let lastPress,
           timestamp >= lastPress,
           timestamp - lastPress < Self.maximumInterval {
            self.lastPress = nil
            return true
        }
        lastPress = timestamp
        return false
    }

    func reset() {
        lastPress = nil
    }
}

/// Applies one deterministic Debug visual-test state after the fixture tab and
/// workspace have been loaded. Nil is deliberately a no-op, which keeps Release
/// and ordinary Debug launches isolated from visual-test state arguments.
@MainActor
enum VisualTestStateApplier {
    static func apply(
        _ state: VisualTestLaunchState?,
        documentManager: DocumentManager,
        findState: FindState
    ) {
        apply(
            state,
            documentManager: documentManager,
            findState: findState,
            toaster: .shared
        )
    }

    static func apply(
        _ state: VisualTestLaunchState?,
        documentManager: DocumentManager,
        findState: FindState,
        toaster: Toaster
    ) {
        guard let state else { return }

        switch state {
        case .defaultState:
            return
        case .palette:
            // Use the production palette state transition. The presentation
            // policy keeps an inactive passive launch inside its ordered-out
            // main surface, then returns to the child panel after activation.
            documentManager.openCommandPalette()
        case .find:
            findState.openFind()
        case .preview:
            // Exercise the production transition so the reference state also
            // contains its real transient feedback. Pin only this current toast
            // because readiness and offscreen capture can exceed its 1.6 s life.
            documentManager.togglePreviewMode(toaster: toaster)
            toaster.pinCurrentToastUntilNextFlash()
        case .sidebarHidden:
            documentManager.sidebarOpen = false
        case .sourceEditor:
            guard let tab = documentManager.activeTab else { return }
            let store = documentManager.blockEditorStore(for: tab)
            guard let firstBlock = store.document.blocks.first else { return }
            store.beginSourceEditing(
                blockID: firstBlock.id,
                // A generic rendered-block click in the authoritative
                // prototype opens the editor with the insertion point at end.
                selection: NSRange(
                    location: (firstBlock.source as NSString).length,
                    length: 0
                )
            )
        case .tableEditor:
            guard let tab = documentManager.activeTab else { return }
            let store = documentManager.blockEditorStore(for: tab)
            guard let table = store.document.blocks.first(where: { $0.kind == .table }),
                  let grid = try? store.document.tableGrid(for: table.id),
                  !grid.rows.isEmpty,
                  grid.columnCount > 0 else { return }
            store.beginTableEditing(
                blockID: table.id,
                // The authoritative reference opens the table wrapper rather
                // than a body cell, which resolves to the first header input.
                cell: .header(0)
            )
        }
    }
}

struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject var docManager: DocumentManager
    @ObservedObject var findState: FindState
    @ObservedObject private var toaster = Toaster.shared
    @StateObject private var bridge = EditorBridge()
    // Held via @State (NOT @StateObject/@ObservedObject) on purpose: @State keeps
    // a stable reference WITHOUT subscribing to objectWillChange, so per-frame
    // scroll updates to scrollModel.value never re-render ContentView. Only the
    // isolated EditorStatusBar observes it.
    @State private var scrollModel = ScrollProgressModel()
    // Same isolation as scrollModel: the active outline heading changes on every
    // scroll frame, so it gets its own observable held via @State (NOT observed
    // here) — only OutlineRailView subscribes. ContentView.body must never read
    // it, or scrolling would re-render the whole tree again.
    @State private var activeHeading = ActiveHeadingModel()
    // Same isolation as scrollModel/activeHeading: the hovered link URL changes on
    // every mouse move over a link. Held via @State (NOT observed here) so only the
    // bottom-left hover-preview leaf re-renders. ContentView.body must never read it.
    @State private var hoverURL = HoverURLModel()
    // Same isolation as scrollModel/activeHeading/hoverURL: the document char/line
    // counts change on every edit. Held via @State (NOT observed here) so only the
    // bottom-right EditorStatusBar re-renders. ContentView.body must never read it,
    // or editing would re-render the whole tree again (性能-3).
    @State private var docMetrics = DocMetricsModel()
    // Debug restyle and find diagnostic sink. Held via @State and not observed here
    // for the same isolation reason as scrollModel and hoverURL. Writing it on every
    // edit must not re-render ContentView. Only the bottom-left DiagReadout observes it.
    @State private var diag = DiagModel()
    // Plain-source diagnostics are published by the shell at tab activation time.
    // Keep their HUD model separate from EditorCoordinator's Markdown restyle probe,
    // whose delayed callbacks must never replace the active plain-document readout.
    @State private var nonMarkdownDiag = DiagModel()
    @State private var isDragging = false
    @State private var dropCoordinator = DocumentDropCoordinator()
    @State private var hasInitialized = false
    // Double-Shift → quick search (spec JS L478-490): event monitor + timing holder.
    @State private var shiftMonitor: Any?
    @State private var shiftTracker = DoubleShiftTracker()
    @State private var visualTestHasActivated = NSApplication.shared.isActive

    private var tabPadLeft: CGFloat {
        docManager.sidebarOpen ? 12 : 84
    }

    private var palettePresentationMode: PalettePresentationMode {
        PalettePresentationPolicy.mode(
            isVisualTest: AppEnv.visualTest,
            launchesForeground: AppEnv.visualTestForegroundOnLaunch,
            hasActivated: visualTestHasActivated
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            if docManager.sidebarOpen {
                SidebarView()
                    .frame(width: docManager.sidebarWidth)
                    // The resize hit strip extends 4 pt into the document. Keep that
                    // narrow overlap above the following HStack sibling.
                    .zIndex(1)
                    .debugVisualAnchor("sidebar-frame")
                    .transition(MotionPolicy.transition(
                        .move(edge: .leading).combined(with: .opacity),
                        reduceMotion: reduceMotion
                    ))
            }

            VStack(spacing: 0) {
                EditorHeader(findState: findState, tabPadLeft: tabPadLeft)
                    .frame(height: 44)
                    .padding(.leading, tabPadLeft)
                    .debugVisualAnchor("tab-bar-frame")

                ZStack(alignment: .topTrailing) {
                    if let active = docManager.activeTab {
                        if active.isMarkdown {
                            MarkdownBlockEditorView(
                                store: docManager.blockEditorStore(for: active),
                                findState: findState,
                                documentName: active.name,
                                bodyFontSize: DesignTokens.bodyFontSizes[docManager.fontIndex],
                                previewMode: docManager.previewMode,
                                initialScrollY: active.scrollY,
                                scrollModel: scrollModel,
                                activeHeadingModel: activeHeading,
                                hoverURL: hoverURL,
                                docMetrics: docMetrics,
                                diag: diag
                            )
                            .id(active.id)
                        } else {
                            EditorView(
                                // Plain mount-time load value (NOT a two-way binding):
                                // the live text lives in the NSTextView after mount, and
                                // `.id(activeTabID)` below reloads it per tab switch.
                                text: active.text,
                                // Mount-time scroll offset to restore (same one-shot
                                // load semantics as `text`) — Phase-2 per-tab scroll.
                                scrollY: active.scrollY,
                                selection: active.selectionRange,
                                diagnosticDocumentID: active.id,
                                diagnosticDocumentName: active.name,
                                docManager: docManager,
                                fontIndex: $docManager.fontIndex,
                                isMarkdown: false,
                                isPreviewMode: false,
                                findState: findState,
                                bridge: bridge,
                                scrollModel: scrollModel,
                                activeHeadingModel: activeHeading,
                                hoverURL: hoverURL,
                                docMetrics: docMetrics,
                                diag: diag  // Debug diagnostics
                            )
                            .id(docManager.activeTabID)
                            .onAppear {
                                publishNonMarkdownDiagnosticSurfaceIfNeeded()
                            }
                        }
                    } else {
                        emptyState
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DesignTokens.swiftUI.paper)
                // ⌘F find/replace panel — spec L131-135: lives INSIDE the content area
                // (the flex:1 box below the 44px tab bar), anchored top:10 right:18.
                // Overlaying here (not on the outer column) makes top/right relative to
                // the content area, so it sits just under the tab bar instead of being
                // measured against the whole window and riding up over the top bar (QA P1).
                .overlay(alignment: .topTrailing) {
                    if findState.isOpen {
                        FindBarView(state: findState)
                            .transition(MotionPolicy.transition(
                                .move(edge: .top).combined(with: .opacity),
                                reduceMotion: reduceMotion
                            ))
                    }
                }
                // #22: non-Markdown source banner (spec ~L391). Pinned to the top of
                // the content area so it reads as a header above the source text.
                .overlay(alignment: .top) {
                    if let active = docManager.activeTab, !active.isMarkdown {
                        nonMarkdownBanner
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if docManager.activeTab != nil {
                        EditorStatusBar(
                            scrollModel: scrollModel,
                            metrics: docMetrics,
                            docToken: docManager.activeTabID
                        )
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    // Observes the isolated HoverURLModel — a mouse move over a link
                    // re-renders only this leaf, never ContentView.body (性能-2).
                    HoverURLPreview(model: hoverURL)
                }
                // Debug restyle-path and find readout, pinned to the bottom-left
                // of the content area (out of the way of the top find bar) and
                // collapsible. Observes only the isolated DiagModel, so it re-renders
                // alone. Gated to Debug diagnostics so normal launches never show it.
                .overlay(alignment: .bottomLeading) {
                    if AppEnv.diagnosticsVisible {
                        DiagReadout(
                            model: docManager.activeTab?.isMarkdown == false
                                ? nonMarkdownDiag
                                : diag
                        )
                    }
                }
            }
        }
        .background(
            WindowGeometryConfigurator(
                frameSize: AppEnv.visualTest
                    ? AppEnv.visualTestWindowSize
                    : CGSize(width: 1_180, height: 760)
            )
        )
        .background(DesignTokens.swiftUI.paper)
        .ignoresSafeArea()
        // Ordinary and activated launches use the production child panel. An
        // inactive passive visual launch renders the same palette view inside the
        // ordered-out main surface so there is no second window to expose or focus.
        .background {
            if palettePresentationMode == .childPanel {
                PaletteBlurHost(docManager: docManager)
            }
        }
        .overlay {
            if palettePresentationMode == .inlinePassive, docManager.paletteOpen {
                CommandPaletteView()
                    .environmentObject(docManager)
            }
        }
        .overlay {
            if isDragging {
                dragOverlay
            }
        }
        .overlay(alignment: .top) {
            if toaster.visible {
                ToastView(message: toaster.message)
                    .debugVisualAnchor("toast-frame")
                    .padding(.top, 56)
                    .transition(MotionPolicy.transition(
                        .opacity,
                        reduceMotion: reduceMotion
                    ))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
            handleDrop(providers: providers)
        }
        .onOpenURL { url in
            guard !AppEnv.consumesVisualTestBootstrapURL(url) else { return }
            docManager.openSelection(url, admission: .system)
        }
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .animation(
            MotionPolicy.animation(.easeInOut(duration: 0.18), reduceMotion: reduceMotion),
            value: docManager.sidebarOpen
        )
        .onAppear {
            resetDocumentModels(for: docManager.activeTabID)
            guard !hasInitialized else { return }
            hasInitialized = true
            // Session restore (Phase 2): resume the previous tabs/active/font/sidebar/
            // folder/scroll. A restored session takes over BEFORE the blank fallback,
            // so the fallback never double-fires. No/empty/corrupt session → first-run
            // behaviour is unchanged: one empty untitled doc, empty sidebar (spec #1/#2).
            if AppEnv.visualTest {
                if AppEnv.visualTestRestoresSession {
                    if let session = SessionStore.load(), !session.tabs.isEmpty {
                        docManager.restoreVisualTestSession(
                            from: session,
                            fixtureName: AppEnv.visualTestFixtureName
                        )
                    } else {
                        MVLog.warn(
                            "visual-test session restore requested without a usable session",
                            category: "session"
                        )
                        docManager.newDocument()
                    }
                } else {
                    do {
                        let text = try DebugFixtureLoader.load(
                            named: AppEnv.visualTestFixtureName
                        )
                        docManager.loadVisualTestDocument(
                            name: AppEnv.visualTestFixtureName,
                            text: text,
                            scrollY: AppEnv.visualTestInitialScrollY
                        )
                        let workspace = try DebugFixtureLoader.prepareWorkspace(
                            fixtureName: AppEnv.visualTestFixtureName,
                            fixtureText: text
                        )
                        docManager.loadDirectory(workspace)
                        VisualTestStateApplier.apply(
                            AppEnv.visualTestLaunchState,
                            documentManager: docManager,
                            findState: findState
                        )
                    } catch {
                        MVLog.warn("visual-test fixture load failed: \(error)", category: "document")
                        docManager.newDocument()
                    }
                }
            } else if let s = SessionStore.load(), !s.tabs.isEmpty {
                docManager.restore(from: s)
            } else if docManager.tabs.isEmpty {
                docManager.newDocument()
            }
        }
        .onAppear { installShiftMonitor() }
        // Wire the palette's always-open find path (spec #14). Parallels the
        // findStateToggle closure set in App.swift; lives here because ContentView
        // owns the findState reference passed to the rest of the UI.
        .onAppear { docManager.findStateOpen = { findState.openFind() } }
        .onAppear {
            installDiagnosticPublicationGate()
            publishNonMarkdownDiagnosticSurfaceIfNeeded()
            publishVisualDiagnostics()
        }
        .onChange(of: docManager.sidebarOpen) { _ in publishVisualDiagnostics() }
        .onChange(of: docManager.paletteOpen) { _ in publishVisualDiagnostics() }
        .onChange(of: palettePresentationMode) { _ in publishVisualDiagnostics() }
        .onChange(of: docManager.previewMode) { _ in publishVisualDiagnostics() }
        .onChange(of: findState.isOpen) { _ in publishVisualDiagnostics() }
        .onChange(of: findState.showReplace) { _ in publishVisualDiagnostics() }
        .onChange(of: docManager.activeTabID) { documentID in
            resetDocumentModels(for: documentID)
            DebugDiagnosticWriter.shared.activeDocumentDidChange()
            publishNonMarkdownDiagnosticSurfaceIfNeeded()
            publishVisualDiagnostics()
        }
        .onChange(of: docManager.activeTab?.isDirty) { _ in
            publishNonMarkdownDiagnosticSurfaceIfNeeded()
        }
        .onDisappear { removeShiftMonitor() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            visualTestHasActivated = true
        }
        .mvTooltipHost()
    }

    // MARK: - Drag overlay

    private var dragOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .stroke(DesignTokens.swiftUI.accent, lineWidth: 2)
                .background(DesignTokens.swiftUI.accent.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            Text("松开以打开 Markdown 文件")
                .font(.system(size: 13))
                .foregroundColor(DesignTokens.swiftUI.titleText)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(DesignTokens.swiftUI.paper)
                .cornerRadius(10)
                // spec L221: 0 0 0 1px rgba(0,0,0,0.05) hairline border hugging the radius
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.14), radius: 14, y: 8)
        }
        .padding(10)
        .accessibilityIdentifier("file-drop-overlay")
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("没有打开的文档")
                .font(.system(size: 14))
                .foregroundColor(DesignTokens.swiftUI.placeholderText)
            Text("按 ⌘N 新建，或 ⌘K 打开一篇")
                .font(.system(size: 12))
                .foregroundColor(DesignTokens.swiftUI.disabledText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("empty-workspace")
    }

    private func publishNonMarkdownDiagnosticSurfaceIfNeeded() {
        guard AppEnv.debug else { return }
        let find = DebugDiagnosticFindState.current(findState)
        guard let active = docManager.activeTab else {
            DebugDiagnosticWriter.shared.update(.emptyWorkspace(
                find: find,
                sessionPath: SessionStore.fileURL.path
            ))
            return
        }
        guard !active.isMarkdown else { return }
        let snapshot = DebugDiagnosticSnapshot.plainSource(
            document: active.name,
            selection: active.selectionRange,
            dirty: active.isDirty,
            find: find,
            scrollY: Double(active.scrollY),
            sessionPath: SessionStore.fileURL.path
        )
        DebugDiagnosticSurfacePublisher.publishPlainSource(
            snapshot,
            documentID: active.id,
            writer: .shared,
            hud: nonMarkdownDiag
        )
    }

    private func installDiagnosticPublicationGate() {
        guard AppEnv.debug else { return }
        DebugDiagnosticWriter.shared.installActiveDocumentProvider { [weak docManager] in
            guard let active = docManager?.activeTab else { return nil }
            return DebugDiagnosticActiveDocument(
                id: active.id,
                isMarkdown: active.isMarkdown
            )
        }
        DebugDiagnosticWriter.shared.activeDocumentDidChange()
    }

    private func publishVisualDiagnostics() {
        guard AppEnv.debug else { return }
        DebugDiagnosticWriter.shared.updateVisualState(
            documentVisible: docManager.activeTab != nil,
            sidebarVisible: docManager.sidebarOpen,
            paletteVisible: docManager.paletteOpen,
            palettePresentation: palettePresentationMode.rawValue,
            findPanelVisible: findState.isOpen,
            replaceRowVisible: findState.isOpen && findState.showReplace,
            previewActive: docManager.previewMode
                && docManager.activeTab?.isMarkdown == true
        )
    }

    private func resetDocumentModels(for documentID: UUID?) {
        scrollModel.reset(for: documentID)
        activeHeading.reset(for: documentID)
        docMetrics.reset(for: documentID)
        hoverURL.clear()
    }

    // MARK: - Non-Markdown source banner (spec ~L391)

    private var nonMarkdownBanner: some View {
        // spec: font-size 12px, color #86868b (tertiaryText), sits above the source.
        Text("非 Markdown 文件 · 以源码形式查看")
            .font(.system(size: 12))
            .foregroundColor(DesignTokens.swiftUI.tertiaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 70)
            .padding(.vertical, 12)
            .background(DesignTokens.swiftUI.paper)
            .allowsHitTesting(false)
            .accessibilityIdentifier("non-markdown-banner")
    }

    // MARK: - Double-Shift quick search (spec JS L478-490)

    private func installShiftMonitor() {
        guard shiftMonitor == nil else { return }
        let tracker = shiftTracker
        shiftMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [docManager, findState] event in
            if event.type == .keyDown {
                // Any non-modifier key breaks the streak, including typing a
                // capital letter with Shift held.
                tracker.reset()
                return event
            }
            let isShiftKey = (event.keyCode == 56 || event.keyCode == 60)
            let mods = event.modifierFlags
            if isShiftKey, mods.contains(.shift) {
                // `isARepeat` is defined for key-down events, not
                // flags-changed modifier events. A held Shift key does not emit
                // repeated Shift-down transitions, so modifier eligibility is
                // fully described by the active flags here.
                guard mods.isDisjoint(with: [.command, .control, .option]) else {
                    tracker.reset()
                    return event
                }
                let now = ProcessInfo.processInfo.systemUptime
                if tracker.registerPress(at: now) {
                    if findState.isOpen { findState.closeFind() }
                    docManager.openCommandPalette()
                }
            } else if !isShiftKey {
                // Another modifier interrupted the streak. A Shift release keeps
                // the first press armed for the second press.
                tracker.reset()
            }
            return event
        }
    }

    private func removeShiftMonitor() {
        if let m = shiftMonitor { NSEvent.removeMonitor(m); shiftMonitor = nil }
    }

    // MARK: - Drop handling

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        dropCoordinator.handle(providers: providers, manager: docManager)
    }
}
