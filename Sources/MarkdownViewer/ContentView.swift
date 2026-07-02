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
                                text: docManager.textBinding,
                                fontIndex: $docManager.fontIndex,
                                isMarkdown: active.isMarkdown,
                                findState: findState,
                                bridge: bridge,
                                scrollModel: scrollModel,
                                activeHeadingModel: activeHeading,
                                hoverURL: hoverURL,
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
                    EditorStatusBar(scrollModel: scrollModel, bridge: bridge)
                }
                .overlay(alignment: .bottomLeading) {
                    // Observes the isolated HoverURLModel — a mouse move over a link
                    // re-renders only this leaf, never ContentView.body (性能-2).
                    HoverURLPreview(model: hoverURL)
                }
                // DIAG (temporary): always-visible restyle-path readout, pinned
                // top-center of the content area. Observes only the isolated
                // DiagModel, so it re-renders alone. Rip out with the DIAG markers.
                .overlay(alignment: .top) {
                    DiagReadout(model: diag)
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
            if docManager.tabs.isEmpty {
                // First launch: one empty untitled doc, empty sidebar (spec #1/#2).
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

// MARK: - Status bar — isolated so scroll only re-renders THIS view
//
// spec: bottom 14px, right 20px, "{千分位字数} 字 · {行数} 行 · {pct}%",
// font 11.5 monospaced, statusText color, fade out 0.8s after scrolling stops.
//
// Observes ScrollProgressModel (the per-frame scroll sink) and EditorBridge
// (char/line counts, changed only on edit). Because ContentView holds the model
// via @State and does NOT observe it, scrolling re-evaluates only this view.
private struct EditorStatusBar: View {
    @ObservedObject var scrollModel: ScrollProgressModel
    @ObservedObject var bridge: EditorBridge
    @State private var faded = false

    // Shared formatter avoids a fresh allocation on every render.
    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private var wordCount: String {
        Self.numberFormatter.string(from: NSNumber(value: bridge.charCount))
            ?? "\(bridge.charCount)"
    }

    var body: some View {
        // spec L208: 11.5px with tabular numerals (font-variant-numeric: tabular-nums),
        // NOT a monospaced family.
        Text("\(wordCount) 字 · \(bridge.lineCount) 行 · \(Int(scrollModel.value * 100))%")
            .font(.system(size: 11.5))
            .monospacedDigit()
            .foregroundColor(DesignTokens.swiftUI.statusText)
            .opacity(faded ? 0 : 1)
            .animation(.easeInOut(duration: 0.3), value: faded)
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
            .onReceive(
                scrollModel.$value.debounce(for: .seconds(0.8), scheduler: DispatchQueue.main)
            ) { _ in
                faded = false
            }
            .onReceive(scrollModel.$value) { _ in
                faded = true
            }
    }
}

// MARK: - Link URL preview — isolated so a mouse move over a link re-renders
// ONLY this leaf (性能-2). Spec L213: bottom 14, left 20, 11.5px, #767676,
// single line ellipsis, max-width 42%, no hit testing.
//
// Observes the isolated HoverURLModel. Because ContentView holds the model via
// @State and does NOT observe it, hovering links never re-evaluates ContentView.body.
private struct HoverURLPreview: View {
    @ObservedObject var model: HoverURLModel

    var body: some View {
        GeometryReader { geo in
            if !model.url.isEmpty {
                Text(model.url)
                    .font(.system(size: 11.5))
                    .foregroundColor(DesignTokens.swiftUI.statusText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: geo.size.width * 0.42, alignment: .leading)
                    .padding(.leading, 20)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .allowsHitTesting(false)
    }
}

// DIAG (temporary) ----------------------------------------------------------
// On-screen restyle-path readout for the "whole-document styling flashes for one
// frame while typing/deleting" bug. Shows the LAST re-style path plus cumulative
// per-path tallies, updated on every keystroke by EditorView.Coordinator.diagRecord.
//
// Observes the isolated DiagModel. ContentView holds that model via @State and does
// NOT observe it, so the instrumentation re-renders ONLY this yellow leaf - it can
// never itself trigger the whole-ContentView re-render we are hunting. Deliberately
// loud debug styling. Rip out with the rest of the `// DIAG (temporary)` markers.
private struct DiagReadout: View {
    @ObservedObject var model: DiagModel

    var body: some View {
        Text(model.text.isEmpty ? "DIAG  (waiting for keystroke...)" : model.text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.yellow)
            .cornerRadius(6)
            .padding(.top, 6)
            .allowsHitTesting(false)
    }
}

// MARK: - Editor header (44px): sidebar toggle + tabs + actions

private struct EditorHeader: View {
    @EnvironmentObject var docManager: DocumentManager
    @ObservedObject var findState: FindState
    let tabPadLeft: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            // Sidebar toggle — spec: 26×26, radius 6, color #aeaeb2, hover bg rgba(0,0,0,0.05) + #6e6e73
            HeaderIconButton(action: { docManager.sidebarOpen.toggle() },
                             frame: CGSize(width: 26, height: 26),
                             tip: "显示 / 隐藏侧栏") { color in
                CIcon { CustomIcons.sidebarToggle }
                    .frame(width: 16, height: 13)
                    .foregroundColor(color)
            }

            // Tabs area
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(docManager.tabs) { tab in
                        EditorTabPill(tab: tab)
                    }
                    // + button — spec: 26×26, radius 6, font-size 16, hover bg rgba(0,0,0,0.05) + #6e6e73
                    HeaderIconButton(action: { docManager.newDocument() },
                                     frame: CGSize(width: 26, height: 26),
                                     tip: "新建文档 · ⌘N") { color in
                        Text("＋")
                            .font(.system(size: 16))
                            .foregroundColor(color)
                    }
                }
                .padding(.horizontal, 8)
            }

            // Find + Open buttons — spec: gap 2px, 28×26, hover bg rgba(0,0,0,0.05) + #6e6e73
            HStack(spacing: 2) {
                HeaderIconButton(action: { findState.openFind() },
                                 frame: CGSize(width: 28, height: 26),
                                 tip: "查找 / 替换 · ⌘F") { color in
                    CIcon { CustomIcons.find }
                        .frame(width: 14, height: 14)
                        .foregroundColor(color)
                }

                HeaderIconButton(action: { docManager.openDocument() },
                                 frame: CGSize(width: 28, height: 26),
                                 tip: "打开 · ⌘O") { color in
                    CIcon { CustomIcons.openFolder }
                        .frame(width: 15, height: 14)
                        .foregroundColor(color)
                }
            }
        }
        .padding(.trailing, 12)
    }
}

// MARK: - Header button style (hover: bg rgba(0,0,0,0.05), color #6e6e73)

private struct HeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(configuration.isPressed
                        ? Color.black.opacity(0.08)
                        : Color.clear)
            )
    }
}

// spec L96/117/121/124: top-bar icon buttons hover → bg rgba(0,0,0,0.05) + icon
// color #6e6e73 (secondaryText). Static color #aeaeb2 (placeholderText). The icon
// foreground is set inside the label, so hover color must be driven per-button here
// (an outer .foregroundColor in the ButtonStyle can't override the inner one).
private struct HeaderIconButton<Label: View>: View {
    let action: () -> Void
    let frame: CGSize
    let tip: String
    @ViewBuilder let label: (Color) -> Label
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            label(hover ? DesignTokens.swiftUI.secondaryText
                        : DesignTokens.swiftUI.placeholderText)
                .frame(width: frame.width, height: frame.height)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hover ? Color.black.opacity(0.05) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(HeaderButtonStyle())
        .mvTip(tip)
        .onHover { hover = $0 }
    }
}

// MARK: - Tab pill

private struct EditorTabPill: View {
    @EnvironmentObject var docManager: DocumentManager
    let tab: DocumentTab
    @State private var isHovered = false
    @State private var closeHovered = false

    var isActive: Bool { tab.id == docManager.activeTabID }
    var isConfirming: Bool { docManager.confirmingCloseTabID == tab.id }

    var body: some View {
        // spec: [name][gap 6][16×16 trailing slot OR 确认关闭? capsule]
        HStack(spacing: 6) {
            Text(tab.name)
                .font(.system(size: 12.5))
                .fontWeight(isActive ? .semibold : .regular)
                .foregroundColor(isActive
                    ? DesignTokens.swiftUI.titleText
                    : DesignTokens.swiftUI.tertiaryText)

            if isConfirming {
                confirmCapsule
            } else {
                trailingSlot
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)  // spec: padding 0 7px 0 12px
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive
                    ? Color.black.opacity(0.06)
                    : (isHovered ? Color.black.opacity(0.05) : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { docManager.activeTabID = tab.id }
        .onHover { isHovered = $0 }
    }

    // spec L105: red pill "确认关闭?" — height 18, padding 0 7px, radius 6,
    // font 11/500, color #C7482E, bg rgba(199,72,46,0.10), line-height 1.
    private var confirmCapsule: some View {
        Text("确认关闭?")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(DesignTokens.swiftUI.danger)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(DesignTokens.swiftUI.danger.opacity(0.10))
            )
            .contentShape(Rectangle())
            .onTapGesture { docManager.requestClose(tab) }
            .help("再点一次关闭，未保存的更改将丢弃")
    }

    // spec L108-114: constant 16×16 slot. Dirty (not hovering) → amber dot;
    // hover → × with its own hover background. Slot always reserved → no jitter.
    private var trailingSlot: some View {
        ZStack {
            if tab.isDirty && !isHovered {
                // spec L110: amber dot 7×7 #E8A33D
                Circle()
                    .fill(DesignTokens.swiftUI.accent)
                    .frame(width: 7, height: 7)
            }
            if isHovered {
                // spec L112: × font-size 13, no weight; color #aeaeb2; hover bg rgba(0,0,0,0.08) + color #1d1d1f
                Text("×")
                    .font(.system(size: 13))
                    .foregroundColor(closeHovered
                        ? DesignTokens.swiftUI.titleText
                        : DesignTokens.swiftUI.placeholderText)
                    .frame(width: 16, height: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(closeHovered ? Color.black.opacity(0.08) : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { docManager.requestClose(tab) }
                    .onHover { closeHovered = $0 }
            }
        }
        .frame(width: 16, height: 16)  // always reserved → tab width never jitters
    }
}
