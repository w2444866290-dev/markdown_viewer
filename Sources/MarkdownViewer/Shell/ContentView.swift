import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Reference holder for double-Shift timing (mutated from an NSEvent monitor closure).
private final class ShiftTracker { var last: TimeInterval = 0 }

struct ContentView: View {
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
    // DIAG (temporary): restyle-path readout sink. Held via @State (NOT observed
    // here) for the SAME isolation reason as scrollModel/hoverURL - writing it on
    // every keystroke must NOT re-render ContentView, or the instrumentation would
    // itself cause the whole-view re-render we are trying to catch. Only the
    // top-center DiagReadout leaf observes it. Rip out with the other DIAG markers.
    @State private var diag = DiagModel()
    @State private var isDragging = false
    @State private var hasInitialized = false
    // Double-Shift → quick search (spec JS L478-490): event monitor + timing holder.
    @State private var shiftMonitor: Any?
    @State private var shiftTracker = ShiftTracker()

    private var tabPadLeft: CGFloat {
        docManager.sidebarOpen ? 12 : 84
    }

    var body: some View {
        HStack(spacing: 0) {
            if docManager.sidebarOpen {
                SidebarView()
                    .frame(width: docManager.sidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            VStack(spacing: 0) {
                EditorHeader(findState: findState, tabPadLeft: tabPadLeft)
                    .frame(height: 44)
                    .padding(.leading, tabPadLeft)

                ZStack(alignment: .topTrailing) {
                    if let active = docManager.activeTab {
                        ZStack(alignment: .trailing) {
                            EditorView(
                                // Plain mount-time load value (NOT a two-way binding):
                                // the live text lives in the NSTextView after mount, and
                                // `.id(activeTabID)` below reloads it per tab switch.
                                text: active.text,
                                // Mount-time scroll offset to restore (same one-shot
                                // load semantics as `text`) — Phase-2 per-tab scroll.
                                scrollY: active.scrollY,
                                docManager: docManager,
                                fontIndex: $docManager.fontIndex,
                                isMarkdown: active.isMarkdown,
                                findState: findState,
                                bridge: bridge,
                                scrollModel: scrollModel,
                                activeHeadingModel: activeHeading,
                                hoverURL: hoverURL,
                                docMetrics: docMetrics,
                                diag: diag  // DIAG (temporary)
                            )
                            .id(docManager.activeTabID)

                            // Outline rail is Markdown-only (#22): non-Markdown source
                            // (TOML/YAML/etc.) has no headings, so render no rail at all.
                            if active.isMarkdown {
                                OutlineRailView(
                                    headings: bridge.headings,
                                    activeHeading: activeHeading,
                                    onJump: { bridge.onJumpToHeading?($0) },
                                    docToken: docManager.activeTabID,
                                    onHoverChange: { bridge.cursorOverRail = $0 }
                                )
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
                            .transition(.move(edge: .top).combined(with: .opacity))
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
                    EditorStatusBar(scrollModel: scrollModel, metrics: docMetrics)
                }
                .overlay(alignment: .bottomLeading) {
                    // Observes the isolated HoverURLModel — a mouse move over a link
                    // re-renders only this leaf, never ContentView.body (性能-2).
                    HoverURLPreview(model: hoverURL)
                }
                // DIAG (temporary): restyle-path + find readout, pinned BOTTOM-LEFT
                // of the content area (out of the way of the top find bar) and
                // collapsible. Observes only the isolated DiagModel, so it re-renders
                // alone. Gated to developer/debug launches (AppEnv.debug) so USER mode
                // never shows it. Rip out with the DIAG markers.
                .overlay(alignment: .bottomLeading) {
                    if AppEnv.debug {
                        DiagReadout(model: diag)
                    }
                }
            }
        }
        .background(MovableByBackground())
        .background(DesignTokens.swiftUI.paper)
        .ignoresSafeArea()
        // ⌘K palette lives in a separate blur-backed window (PaletteBlurHost) so
        // its backdrop can truly frost the main window content. Driven by paletteOpen.
        .background(PaletteBlurHost(docManager: docManager))
        .overlay {
            if isDragging {
                dragOverlay
            }
        }
        .overlay(alignment: .top) {
            if toaster.visible {
                ToastView(message: toaster.message)
                    .padding(.top, 56)
                    .transition(.opacity)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
            handleDrop(providers: providers)
        }
        .animation(.easeInOut(duration: 0.18), value: docManager.sidebarOpen)
        .onAppear {
            guard !hasInitialized else { return }
            hasInitialized = true
            // Session restore (Phase 2): resume the previous tabs/active/font/sidebar/
            // folder/scroll. A restored session takes over BEFORE the blank fallback,
            // so the fallback never double-fires. No/empty/corrupt session → first-run
            // behaviour is unchanged: one empty untitled doc, empty sidebar (spec #1/#2).
            if let s = SessionStore.load(), !s.tabs.isEmpty {
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
        .onDisappear { removeShiftMonitor() }
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
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("没有打开的文档")
                .font(.system(size: 14))
                .foregroundColor(DesignTokens.swiftUI.placeholderText)
            Text("在左侧选择文件，或按 ⌘K")
                .font(.system(size: 12))
                .foregroundColor(DesignTokens.swiftUI.disabledText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    }

    // MARK: - Double-Shift quick search (spec JS L478-490)

    private func installShiftMonitor() {
        guard shiftMonitor == nil else { return }
        let tracker = shiftTracker
        shiftMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [docManager, findState] event in
            if event.type == .keyDown {
                tracker.last = 0   // any non-modifier key breaks the streak (typing capitals)
                return event
            }
            let isShiftKey = (event.keyCode == 56 || event.keyCode == 60)
            let mods = event.modifierFlags
            if isShiftKey, mods.contains(.shift),
               mods.isDisjoint(with: [.command, .control, .option]) {
                // Shift pressed down, no other modifiers.
                let now = ProcessInfo.processInfo.systemUptime
                if tracker.last > 0, now - tracker.last < 0.35 {
                    tracker.last = 0
                    if findState.isOpen { findState.closeFind() }
                    docManager.paletteOpen = true
                } else {
                    tracker.last = now
                }
            } else if !isShiftKey {
                tracker.last = 0   // another modifier interrupted the streak
            }
            // (Shift release falls through: streak preserved.)
            return event
        }
    }

    private func removeShiftMonitor() {
        if let m = shiftMonitor { NSEvent.removeMonitor(m); shiftMonitor = nil }
    }

    // MARK: - Drop handling

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let path = String(data: data, encoding: .utf8),
                  let url = URL(string: path) else { return }
            let ext = url.pathExtension.lowercased()
            // spec L857: only Markdown / text files; reject everything else with a toast.
            guard ["md", "markdown", "txt"].contains(ext) else {
                DispatchQueue.main.async {
                    Toaster.shared.flash("仅支持 Markdown / 文本文件")
                }
                return
            }
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                DispatchQueue.main.async {
                    docManager.openTab(for: url, text: text)
                }
            }
        }
        return true
    }
}
