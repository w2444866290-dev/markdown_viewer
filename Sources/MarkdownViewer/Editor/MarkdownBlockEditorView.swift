import AppKit
import SwiftUI

struct MarkdownBlockEditorView: View {
    @EnvironmentObject private var docManager: DocumentManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: BlockEditorStore
    @ObservedObject var findState: FindState

    let documentName: String
    let bodyFontSize: CGFloat
    let previewMode: Bool
    let initialScrollY: CGFloat
    let scrollModel: ScrollProgressModel
    let activeHeadingModel: ActiveHeadingModel
    let hoverURL: HoverURLModel
    let docMetrics: DocMetricsModel
    let diag: DiagModel

    @State private var headingPositions: [UUID: CGFloat] = [:]
    @State private var washState = OutlineWashState<UUID>()
    @State private var washOpacity = 0.0
    @State private var nativeScrollView = WeakScrollViewBox()
    @State private var activeEditorHeight: CGFloat = 34
    @State private var footnotePopoverText = ""
    @State private var footnotePopoverDefinitionID = ""
    @State private var footnotePopoverSourceBlockIndex: Int?
    @State private var footnotePopoverPoint = CGPoint.zero
    @State private var footnoteReturnBlocks: [String: UUID] = [:]
    @State private var scrollToBlockAction: ((UUID) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let paperWidth = min(
                DesignTokens.paperWidth,
                max(240, geometry.size.width - 138)
            )
            let windowWidth = geometry.frame(in: .global).maxX
            ScrollViewReader { proxy in
                ZStack(alignment: .leading) {
                    ScrollView(.vertical, showsIndicators: true) {
                        documentStack(
                            paperWidth: paperWidth,
                            windowWidth: windowWidth
                        )
                        .frame(
                            width: paperWidth,
                            alignment: .leading
                        )
                        .padding(.top, 40)
                        .padding(
                            .bottom,
                            DesignTokens.editorBottomPadding(contentHeight: geometry.size.height)
                        )
                        .debugVisualAnchor("document-page-frame")
                        .frame(maxWidth: .infinity)
                        .offset(x: -3)
                    }
                    .coordinateSpace(name: "markdown-block-scroll")
                    .debugVisualAnchor("document-surface-frame")
                    .onPreferenceChange(HeadingPositionPreferenceKey.self) { positions in
                        headingPositions = positions
                        synchronizeActiveHeading()
                    }

                    OutlineRailView(
                        headings: outlineHeadings,
                        activeHeading: activeHeadingModel,
                        onJump: { index in jumpToHeading(index, proxy: proxy) },
                        docToken: store.tabID
                    )

                    if !footnotePopoverText.isEmpty,
                       let sourceBlockIndex = footnotePopoverSourceBlockIndex {
                        Text(footnotePopoverText)
                            .font(.system(size: 12))
                            .lineSpacing(3)
                            .foregroundColor(.white)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .frame(maxWidth: 300)
                            .background(Color(hex: 0x1C1C1E, opacity: 0.95))
                            .cornerRadius(8)
                            .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
                            .position(
                                x: min(max(160, footnotePopoverPoint.x), geometry.size.width - 160),
                                y: max(26, footnotePopoverPoint.y - 34)
                            )
                            .allowsHitTesting(false)
                            .accessibilityIdentifier(
                                MarkdownAccessibilitySurface.footnotePopover(
                                    blockIndex: sourceBlockIndex
                                )
                            )
                            .accessibilityLabel(
                                "脚注 \(footnotePopoverDefinitionID) 预览"
                            )
                            .accessibilityValue(footnotePopoverText)
                    }
                }
                .onAppear {
                    wireScrollToBlockAction(proxy: proxy)
                    wireFindState(proxy: proxy)
                }
                .onChange(of: reduceMotion) { _ in
                    wireScrollToBlockAction(proxy: proxy)
                }
            }
        }
        .background(DesignTokens.swiftUI.paper)
        .onAppear {
            prepareDocumentModels()
            wireActiveStore()
            refreshDerivedState()
        }
        .onChange(of: store.document) { _ in
            pruneHeadingPositions()
            synchronizeActiveHeading()
            refreshDerivedState()
            searchCurrentQueryIfNeeded()
        }
        .onChange(of: store.findResult) { _ in
            synchronizeFindState()
        }
        .onChange(of: store.currentFindIndex) { _ in
            synchronizeFindState()
        }
        .onChange(of: store.activeBlockID) { _ in
            refreshDerivedState()
        }
        .onChange(of: store.activeTableCell) { _ in
            refreshDerivedState()
        }
        .onChange(of: previewMode) { enabled in
            if enabled { store.flushActiveEditingForLifecycleBoundary() }
            refreshDerivedState(previewModeOverride: enabled)
        }
        .onDisappear {
            resetTransientNavigation()
            store.flushActiveEditingForLifecycleBoundary()
        }
    }

    @ViewBuilder
    private func documentStack(
        paperWidth: CGFloat,
        windowWidth: CGFloat
    ) -> some View {
        if AppEnv.visualTest {
            VStack(alignment: .leading, spacing: 0) {
                documentStackContent(
                    paperWidth: paperWidth,
                    windowWidth: windowWidth
                )
            }
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                documentStackContent(
                    paperWidth: paperWidth,
                    windowWidth: windowWidth
                )
            }
        }
    }

    @ViewBuilder
    private func documentStackContent(
        paperWidth: CGFloat,
        windowWidth: CGFloat
    ) -> some View {
        BlockScrollObserver(
            initialY: initialScrollY,
            onResolve: { scrollView in
                nativeScrollView.scrollView = scrollView
                MarkdownDocumentScrollIndicatorPolicy.apply(to: scrollView)
                docManager.pullActiveScrollY = { [weak scrollView] in
                    scrollView?.contentView.bounds.origin.y ?? 0
                }
            },
            onScroll: { _, progress, isScrollActivity in
                scrollModel.publish(
                    progress,
                    for: store.tabID,
                    isScrollActivity: isScrollActivity
                )
                if AppEnv.debug { refreshDerivedState() }
            }
        )
        .frame(width: 1, height: 0)

        ForEach(store.document.blocks) { block in
            blockRow(
                block,
                paperWidth: paperWidth,
                windowWidth: windowWidth
            )
                .id(block.id)
                .background {
                    if block.kind == .heading {
                        GeometryReader { blockGeometry in
                            Color.clear.preference(
                                key: HeadingPositionPreferenceKey.self,
                                value: [
                                    block.id: blockGeometry.frame(
                                        in: .named("markdown-block-scroll")
                                    ).minY,
                                ]
                            )
                        }
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            washState.blockID == block.id
                                ? DesignTokens.swiftUI.accent.opacity(washOpacity)
                                : Color.clear
                        )
                        .allowsHitTesting(false)
                }
                .debugVisualTestBlockAnchor(
                    diagnosticBlockAnchorName(block)
                )
        }
    }

    private func diagnosticBlockAnchorName(_ block: MarkdownBlock) -> String {
        let index = store.document.blocks.firstIndex(where: { $0.id == block.id }) ?? -1
        return "document-block-\(index)-\(block.kind.rawValue)"
    }

    @ViewBuilder
    private func blockRow(
        _ block: MarkdownBlock,
        paperWidth: CGFloat,
        windowWidth: CGFloat
    ) -> some View {
        if store.activeTableID == block.id, !previewMode {
            MarkdownTableGridEditor(store: store, paperWidth: paperWidth)
        } else if store.activeBlockID == block.id, !previewMode {
            activeSourceEditor(block)
        } else {
            let diagnosticIndex = store.document.blocks.firstIndex(where: {
                $0.id == block.id
            }) ?? -1
            MarkdownBlockRenderer(
                block: block,
                bodyFontSize: bodyFontSize,
                previewMode: previewMode,
                isFirstBlock: store.document.blocks.first?.id == block.id,
                paperWidth: paperWidth,
                windowWidth: windowWidth,
                previousBottomMargin: previousBottomMargin(before: block),
                revision: store.renderRevisionByBlock[block.id, default: 0],
                findMatches: store.findMatches(for: block.id),
                currentFindMatch: store.currentFindMatch,
                diagnosticIndex: diagnosticIndex,
                callbackOwnerIdentity: ObjectIdentifier(store),
                onActivate: {
                    guard !previewMode else { return }
                    DebugPointerTrace.shared.recordSemantic(
                        "block-activate-callback",
                        blockIndex: diagnosticIndex,
                        blockID: block.id
                    )
                    store.beginSourceEditing(blockID: block.id)
                },
                onTaskToggle: { itemIndex in
                    store.toggleTask(blockID: block.id, itemIndex: itemIndex)
                },
                onTableCell: { cell in
                    guard !previewMode else { return }
                    store.beginTableEditing(blockID: block.id, cell: cell)
                },
                onRender: { blockID in
                    guard AppEnv.debug else { return }
                    DebugDiagnosticWriter.shared.recordBlockRender(blockID)
                },
                onFootnoteBack: jumpBackToFootnoteReference,
                onHoverURL: { destination in
                    handleHoverDestination(
                        destination,
                        sourceBlockIndex: diagnosticIndex
                    )
                },
                onOpenURL: { destination in
                    openLink(destination, from: block.id)
                }
            )
            .equatable()
        }
    }

    private func previousBottomMargin(before block: MarkdownBlock) -> CGFloat {
        guard let index = store.document.blocks.firstIndex(where: { $0.id == block.id }),
              index > 0 else { return 0 }
        return MarkdownVerticalLayout.bottomMargin(for: store.document.blocks[index - 1])
    }

    private func activeSourceEditor(_ block: MarkdownBlock) -> some View {
        let diagnosticIndex = store.document.blocks.firstIndex(where: {
            $0.id == block.id
        }) ?? -1
        return BlockSourceEditor(
            initialSource: block.source,
            blockKind: block.kind,
            bodyFontSize: bodyFontSize,
            focusToken: block.id,
            initialSelection: store.activeSelection,
            accessibilityIdentifier: MarkdownAccessibilitySurface.sourceEditor(
                blockIndex: diagnosticIndex
            ),
            findHighlights: store.findMatches(for: block.id).map { match in
                BlockSourceEditor.FindHighlight(
                    range: match.sourceRange,
                    isCurrent: match == store.currentFindMatch
                )
            },
            onHeightChange: { activeEditorHeight = $0 },
            lifecycleBridge: store.sourceEditorBridge,
            onChange: { source, selection in
                store.updateActiveDraft(source, selection: selection)
                if AppEnv.debug { refreshDerivedState() }
            },
            onCommit: { source, selection in
                store.updateActiveDraft(source, selection: selection)
                store.commitActiveEditing()
            },
            onKeyCommand: { event, source, selection in
                editingResult(
                    for: event,
                    source: source,
                    selection: selection
                )
            },
            onBoundaryAction: { action in
                store.handleBoundaryAction(
                    action,
                    selection: store.activeSelection ?? NSRange(location: 0, length: 0)
                )
            }
        )
        .frame(height: activeEditorHeight)
        .debugVisualAnchor("source-editor-frame")
        .padding(.leading, -BlockSourceEditorLayout.leadingOverflow)
        .padding(.bottom, MarkdownVerticalLayout.bottomMargin(for: block))
    }

    private func editingResult(
        for event: NSEvent,
        source: String,
        selection: NSRange
    ) -> MarkdownEditingResult? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command: MarkdownEditingCommand?
        if modifiers.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "b": command = .bold
            case "i": command = .italic
            case "e": command = .inlineCode
            default: command = nil
            }
        } else if modifiers.isDisjoint(with: [.control, .option]) {
            switch event.keyCode {
            case 36, 76:
                command = modifiers.contains(.shift) ? .shiftEnter : .enter
            case 51: command = .backspace
            case 48: command = modifiers.contains(.shift) ? .shiftTab : .tab
            case 126: command = .arrowUp
            case 125: command = .arrowDown
            default: command = nil
            }
        } else {
            command = nil
        }
        guard let command,
              let result = try? MarkdownEditingCommands.apply(
                command,
                to: source,
                selection: selection,
                blockKind: MarkdownDocument.inferredBlockKind(
                    forDraft: source,
                    atUTF16Offset: selection.location
                )
              ) else { return nil }
        if (command == .arrowUp || command == .arrowDown), result.boundaryAction == nil {
            return nil
        }
        return result
    }

    private func handleHoverDestination(_ destination: String, sourceBlockIndex: Int) {
        guard destination.hasPrefix("mv-footnote:") else {
            footnotePopoverText = ""
            footnotePopoverDefinitionID = ""
            footnotePopoverSourceBlockIndex = nil
            hoverURL.publish(destination, sourceBlockIndex: sourceBlockIndex)
            return
        }
        hoverURL.clear()
        let id = String(destination.dropFirst("mv-footnote:".count))
        footnotePopoverText = footnoteDefinitions[id] ?? ""
        footnotePopoverDefinitionID = id
        footnotePopoverSourceBlockIndex = sourceBlockIndex
        guard let scrollView = nativeScrollView.scrollView,
              let window = scrollView.window else { return }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let local = scrollView.convert(windowPoint, from: nil)
        footnotePopoverPoint = CGPoint(
            x: local.x,
            y: scrollView.bounds.height - local.y
        )
    }

    private func openLink(_ destination: String, from sourceBlockID: UUID) {
        guard !destination.isEmpty else { return }
        if destination.hasPrefix("mv-footnote:") {
            let id = String(destination.dropFirst("mv-footnote:".count))
            footnoteReturnBlocks[id] = sourceBlockID
            jumpToFootnoteDefinition(id)
            return
        }
        let resolved: URL?
        if let absolute = URL(string: destination), absolute.scheme != nil {
            resolved = absolute
        } else if let documentURL = docManager.activeTab?.url {
            resolved = URL(
                string: destination,
                relativeTo: documentURL.deletingLastPathComponent()
            )?.absoluteURL
        } else {
            resolved = nil
        }
        guard let resolved else {
            Toaster.shared.flash("无法打开链接")
            return
        }
        NSWorkspace.shared.open(resolved)
    }

    private var footnoteDefinitions: [String: String] {
        var result: [String: String] = [:]
        for block in store.document.blocks where block.kind == .footnotes {
            for definition in PassiveFootnoteDefinitionParser.parse(block.source) {
                result[definition.id] = definition.text
            }
        }
        return result
    }

    private func jumpToFootnoteDefinition(_ id: String) {
        guard let block = store.document.blocks.first(where: { block in
            block.kind == .footnotes
                && PassiveFootnoteDefinitionParser.parse(block.source).contains { $0.id == id }
        }) else { return }
        scrollToBlockAction?(block.id)
        wash(block.id)
    }

    private func jumpBackToFootnoteReference(_ id: String) {
        let fallback = store.document.blocks.first(where: {
            $0.kind != .footnotes && $0.source.contains("[^\(id)]")
        })?.id
        guard let blockID = footnoteReturnBlocks[id] ?? fallback else { return }
        scrollToBlockAction?(blockID)
        wash(blockID)
    }

    private func wash(_ blockID: UUID) {
        let delay = MotionPolicy.delay(0.32, reduceMotion: reduceMotion)
        let generation = beginNavigationWash()
        scheduleWash(blockID, after: delay, generation: generation)
    }

    private var outlineHeadings: [OutlineController.Heading] {
        var headings: [OutlineController.Heading] = []
        for block in store.document.blocks {
            guard block.kind == .heading,
                  let presentation = MarkdownHeadingPresentation.parse(block.source) else {
                continue
            }
            headings.append(OutlineController.Heading(
                id: headings.count,
                title: presentation.title,
                level: presentation.level,
                charIndex: headings.count
            ))
        }
        return headings
    }

    private func jumpToHeading(_ index: Int, proxy: ScrollViewProxy) {
        let ids = store.document.blocks.filter { $0.kind == .heading }.map(\.id)
        guard ids.indices.contains(index) else { return }
        let id = ids[index]
        let generation = beginNavigationWash()
        MotionPolicy.perform(
            reduceMotion: reduceMotion,
            animation: .easeOut(duration: OutlineBehaviorPolicy.jumpDuration)
        ) {
            proxy.scrollTo(id, anchor: .top)
        }
        let delay = MotionPolicy.delay(
            OutlineBehaviorPolicy.jumpDuration,
            reduceMotion: reduceMotion
        )
        scheduleWash(id, after: delay, generation: generation)
    }

    private func synchronizeActiveHeading() {
        let headingIDs = store.document.blocks.filter { $0.kind == .heading }.map(\.id)
        let active = OutlineBehaviorPolicy.activeHeadingIndex(
            orderedHeadingIDs: headingIDs,
            viewportMinYByHeadingID: headingPositions,
            previousIndex: activeHeadingModel.index
        ) ?? 0
        activeHeadingModel.publish(active, for: store.tabID)
    }

    private func pruneHeadingPositions() {
        let headingIDs = Set(store.document.blocks.lazy.filter {
            $0.kind == .heading
        }.map(\.id))
        headingPositions = headingPositions.filter { headingIDs.contains($0.key) }
    }

    private func beginNavigationWash() -> Int {
        washOpacity = 0
        return washState.beginNavigation()
    }

    private func scheduleWash(
        _ blockID: UUID,
        after delay: TimeInterval,
        generation: Int
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard store.document.blocks.contains(where: { $0.id == blockID }),
                  washState.beginWash(blockID, ifCurrent: generation) else { return }
            washOpacity = OutlineBehaviorPolicy.washOpacity

            if !reduceMotion {
                DispatchQueue.main.async {
                    guard washState.isCurrent(generation) else { return }
                    MotionPolicy.perform(
                        reduceMotion: false,
                        animation: .easeOut(duration: OutlineBehaviorPolicy.washDuration)
                    ) {
                        washOpacity = 0
                    }
                    scheduleWashCompletion(generation: generation)
                }
            } else {
                scheduleWashCompletion(generation: generation)
            }
        }
    }

    private func scheduleWashCompletion(generation: Int) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OutlineBehaviorPolicy.washDuration
        ) {
            guard washState.finishWash(ifCurrent: generation) else { return }
            washOpacity = 0
        }
    }

    private func resetTransientNavigation() {
        washState.reset()
        washOpacity = 0
    }

    private func prepareDocumentModels() {
        scrollModel.reset(for: store.tabID)
        activeHeadingModel.reset(for: store.tabID)
        docMetrics.reset(for: store.tabID)
    }

    private func wireActiveStore() {
        docManager.commitActiveEditing = { [weak store] in
            store?.flushActiveEditingForLifecycleBoundary()
        }
        docManager.pullActiveText = { [weak store] in store?.snapshotDocument().source ?? "" }
        docManager.pullActiveMarkdownDocument = { [weak store] in store?.snapshotDocument() }
        docManager.pullActiveSelection = { [weak store] in store?.snapshotSelection }
    }

    private func wireFindState(proxy: ScrollViewProxy) {
        let state = findState
        state.onSearch = { [weak store, weak state] query in
            guard let store, let state else { return }
            store.search(BlockFindOptions(
                query: query,
                caseSensitive: state.caseSensitive,
                wholeWord: state.wholeWord,
                useRegex: state.useRegex
            ))
            synchronizeFindState()
            scrollToCurrentFindMatch(proxy: proxy)
        }
        state.onNavigate = { [weak store, weak state] delta in
            guard let store, state != nil else { return }
            store.navigateFind(delta)
            synchronizeFindState()
            scrollToCurrentFindMatch(proxy: proxy)
        }
        state.onReplaceCurrent = { [weak store, weak state] in
            guard let store, let state else { return }
            let count = store.replaceCurrentFind(with: state.replaceText)
            synchronizeFindState()
            if count == 0 {
                Toaster.shared.flash("没有可替换的匹配")
            } else {
                Toaster.shared.flash("已替换 1 处")
                scrollToCurrentFindMatch(proxy: proxy)
            }
        }
        state.onReplaceAll = { [weak store, weak state] in
            guard let store, let state else { return }
            let count = store.replaceAllFind(with: state.replaceText)
            synchronizeFindState()
            Toaster.shared.flash(count == 0 ? "没有可替换的匹配" : "已替换 \(count) 处")
        }
        searchCurrentQueryIfNeeded()
    }

    private func wireScrollToBlockAction(proxy: ScrollViewProxy) {
        let reduceMotion = reduceMotion
        scrollToBlockAction = { blockID in
            MotionPolicy.perform(
                reduceMotion: reduceMotion,
                animation: .easeOut(duration: 0.32)
            ) {
                proxy.scrollTo(blockID, anchor: .top)
            }
        }
    }

    private func searchCurrentQueryIfNeeded() {
        guard !findState.query.isEmpty else {
            synchronizeFindState()
            return
        }
        store.search(BlockFindOptions(
            query: findState.query,
            caseSensitive: findState.caseSensitive,
            wholeWord: findState.wholeWord,
            useRegex: findState.useRegex
        ))
        synchronizeFindState()
    }

    private func synchronizeFindState() {
        let count = store.findResult.matches.count
        if findState.matchCount != count { findState.matchCount = count }
        let index = count == 0 ? 0 : min(store.currentFindIndex, count - 1)
        if findState.currentIndex != index { findState.currentIndex = index }
        let hasError = store.findResult.error != nil
        if findState.isError != hasError { findState.isError = hasError }
        refreshDerivedState()
    }

    private func scrollToCurrentFindMatch(proxy: ScrollViewProxy) {
        guard let blockID = store.currentFindMatch?.blockID else { return }
        MotionPolicy.perform(
            reduceMotion: reduceMotion,
            animation: .easeOut(duration: 0.12)
        ) {
            proxy.scrollTo(blockID, anchor: .center)
        }
    }

    private func refreshDerivedState(previewModeOverride: Bool? = nil) {
        let diagnosticPreviewMode = previewModeOverride ?? previewMode
        let metricsDocument = store.snapshotDocument()
        let source = metricsDocument.source
        docMetrics.publish(
            charCount: DocMetricsModel.nonWhitespaceCharacterCount(in: source),
            lineCount: DocMetricsModel.renderedBlockLineCount(in: metricsDocument),
            for: store.tabID
        )
        if AppEnv.debug,
           DebugDiagnosticPublicationPolicy.allowsPublication(
               mountedDocumentID: store.tabID,
               activeDocumentID: docManager.activeTabID
           ) {
            let active = store.activeBlock
                ?? store.activeTableID.flatMap { store.document.block(id: $0) }
            let tableCell = store.activeTableCell.map { "\($0.row),\($0.column)" } ?? "none"
            let selection = store.activeSelection.map { "\($0.location),\($0.length)" } ?? "none"
            let diagnosticWriter = DebugDiagnosticWriter.shared
            diag.text = [
                "doc=\(documentName)",
                "block=\(active?.id.uuidString ?? "none")",
                "type=\(active?.kind.rawValue ?? "none")",
                "mode=\(diagnosticPreviewMode ? "preview" : "edit")",
                "table=\(tableCell)",
                "selection=\(selection)",
                "dirty=\(docManager.activeTab?.isDirty == true)",
                "find=\(findState.displayText)",
                "outline=\(outlineHeadings.count)/\(activeHeadingModel.index)",
                "scroll=\(Int(nativeScrollView.scrollView?.contentView.bounds.origin.y ?? 0))",
                "session=\(SessionStore.fileURL.path)",
                "parse=\(store.parseCount)",
                "local=\(store.localMutationCount)",
                "render=\(diagnosticWriter.renderedBlockUpdateCount)",
            ].joined(separator: " · ")
            diagnosticWriter.update(DebugDiagnosticSnapshot(
                schemaVersion: 1,
                document: documentName,
                blockID: active?.id.uuidString,
                blockType: active?.kind.rawValue,
                mode: diagnosticPreviewMode ? "preview" : "edit",
                selection: store.activeSelection.map {
                    DebugDiagnosticSelection(location: $0.location, length: $0.length)
                },
                activeTableCell: store.activeTableCell.map {
                    DebugDiagnosticTableCell(row: $0.row, column: $0.column)
                },
                dirty: docManager.activeTab?.isDirty == true,
                find: DebugDiagnosticFindState(
                    query: findState.query,
                    display: findState.displayText,
                    matchCount: findState.matchCount,
                    currentIndex: findState.currentIndex,
                    invalidRegex: findState.isError,
                    replaceExpanded: findState.showReplace,
                    caseSensitive: findState.caseSensitive,
                    wholeWord: findState.wholeWord,
                    regex: findState.useRegex
                ),
                outline: DebugDiagnosticOutlineState(
                    headingCount: outlineHeadings.count,
                    activeIndex: activeHeadingModel.index
                ),
                scrollY: Double(nativeScrollView.scrollView?.contentView.bounds.origin.y ?? 0),
                sessionPath: SessionStore.fileURL.path,
                parseCount: store.parseCount,
                localMutationCount: store.localMutationCount,
                renderedBlockUpdateCount: diagnosticWriter.renderedBlockUpdateCount,
                activeBlockRenderUpdateCount: diagnosticWriter.renderedBlockUpdateCount(
                    for: active?.id
                ),
                renderedBlockUpdates: [:],
                visual: .empty,
                updatedAt: Date()
            ))
        }
    }
}

private struct HeadingPositionPreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]

    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Uses the system overlay scroller rather than a decorative SwiftUI thumb.
/// AppKit retains drag tracking, hover behavior, and accessibility semantics.
enum MarkdownDocumentScrollIndicatorPolicy {
    static func apply(to scrollView: NSScrollView) {
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
    }
}
