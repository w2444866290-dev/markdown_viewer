import AppKit
import SwiftUI

/// Central gate for edit-only gestures, controls, and hover styling.
struct MarkdownBlockInteractionPolicy: Equatable {
    let previewMode: Bool

    var allowsEditingActions: Bool { !previewMode }
    var allowsTaskToggle: Bool { true }

    func showsEditHoverCue(hovered: Bool) -> Bool {
        allowsEditingActions && hovered
    }

    func exposesBlockAccessibilityAction(kind: MarkdownBlockKind) -> Bool {
        allowsEditingActions && kind != .table
    }

    func performEditingAction(_ action: () -> Void) {
        guard allowsEditingActions else { return }
        action()
    }

    func performTaskToggle(_ action: () -> Void) {
        guard allowsTaskToggle else { return }
        action()
    }
}

enum MarkdownVerticalLayout {
    static func collapsedTopMargin(_ margin: CGFloat, after previousBottomMargin: CGFloat) -> CGFloat {
        max(0, margin - max(0, previousBottomMargin))
    }

    static func bottomMargin(for block: MarkdownBlock) -> CGFloat {
        switch block.kind {
        case .heading:
            let trimmed = block.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let level = min(6, max(1, trimmed.prefix(while: { $0 == "#" }).count))
            return headingBottomMargin(level: level)
        case .paragraph, .quote, .list:
            return 18
        case .code, .table, .image, .footnotes:
            return 20
        case .horizontalRule:
            return 16
        }
    }

    static func headingBottomMargin(level: Int) -> CGFloat {
        switch min(6, max(1, level)) {
        case 1: return 16
        case 2: return 14
        case 3: return 10
        case 4: return 8
        default: return 6
        }
    }

    static func headingTopMargin(level: Int) -> CGFloat {
        switch min(6, max(1, level)) {
        case 1: return 34
        case 2: return 32
        case 3: return 26
        case 4: return 22
        case 5: return 20
        default: return 18
        }
    }

    static func headingLineHeight(level: Int) -> CGFloat {
        switch min(6, max(1, level)) {
        case 1: return 33
        case 2: return 26
        case 3: return 22
        case 4: return 20
        case 5: return 18
        default: return 16
        }
    }
}

enum MarkdownHorizontalScrollerLayout {
    static let gutterHeight: CGFloat = 6
    static let compactWindowUpperBound: CGFloat = 994

    static func reservedGutterHeight(
        paperWidth: CGFloat,
        windowWidth: CGFloat,
        overflows: Bool
    ) -> CGFloat {
        guard overflows else { return 0 }
        let usesCompactPaper = paperWidth < DesignTokens.paperWidth
        let usesCompactWindow = windowWidth < compactWindowUpperBound
        return usesCompactPaper || usesCompactWindow ? gutterHeight : 0
    }
}

enum MarkdownHoverLayout {
    static let horizontalOutset: CGFloat = 14
    static let verticalOutset: CGFloat = 5

    static func alignedBlockWidth(paperWidth: CGFloat) -> CGFloat {
        max(0, paperWidth)
    }

    static func backgroundWidth(paperWidth: CGFloat) -> CGFloat {
        alignedBlockWidth(paperWidth: paperWidth) + horizontalOutset * 2
    }

    static func outerSpacing(
        for block: MarkdownBlock,
        isFirstBlock: Bool,
        previousBottomMargin: CGFloat
    ) -> (top: CGFloat, bottom: CGFloat)? {
        switch block.kind {
        case .heading:
            let trimmed = block.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let level = min(6, max(1, trimmed.prefix(while: { $0 == "#" }).count))
            return (
                isFirstBlock
                    ? 0
                    : MarkdownVerticalLayout.collapsedTopMargin(
                        MarkdownVerticalLayout.headingTopMargin(level: level),
                        after: previousBottomMargin
                    ),
                MarkdownVerticalLayout.headingBottomMargin(level: level)
            )
        case .paragraph, .quote, .list:
            return (0, MarkdownVerticalLayout.bottomMargin(for: block))
        case .horizontalRule:
            return (
                MarkdownVerticalLayout.collapsedTopMargin(
                    16,
                    after: previousBottomMargin
                ),
                MarkdownVerticalLayout.bottomMargin(for: block)
            )
        case .code, .table, .image, .footnotes:
            return nil
        }
    }
}

struct MarkdownBlockRenderer: View, Equatable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let block: MarkdownBlock
    let bodyFontSize: CGFloat
    let previewMode: Bool
    let isFirstBlock: Bool
    let paperWidth: CGFloat
    let windowWidth: CGFloat
    let previousBottomMargin: CGFloat
    let revision: Int
    let findMatches: [BlockFindMatch]
    let currentFindMatch: BlockFindMatch?
    let diagnosticIndex: Int
    let callbackOwnerIdentity: ObjectIdentifier
    let onActivate: () -> Void
    let onTaskToggle: (Int) -> Void
    let onTableCell: (MarkdownTableCell) -> Void
    var onRender: (UUID) -> Void = { _ in }
    var onFootnoteBack: (String) -> Void = { _ in }
    var onHoverURL: (String, CGRect?) -> Void = { _, _ in }
    var onOpenURL: (String) -> Void = { _ in }

    @State private var hovered = false

    private var interactionPolicy: MarkdownBlockInteractionPolicy {
        MarkdownBlockInteractionPolicy(previewMode: previewMode)
    }

    private var editHoverActive: Bool {
        interactionPolicy.showsEditHoverCue(hovered: hovered)
    }

    static func == (lhs: MarkdownBlockRenderer, rhs: MarkdownBlockRenderer) -> Bool {
        lhs.block == rhs.block
            && lhs.bodyFontSize == rhs.bodyFontSize
            && lhs.previewMode == rhs.previewMode
            && lhs.isFirstBlock == rhs.isFirstBlock
            && lhs.paperWidth == rhs.paperWidth
            && lhs.windowWidth == rhs.windowWidth
            && lhs.previousBottomMargin == rhs.previousBottomMargin
            && lhs.revision == rhs.revision
            && lhs.findMatches == rhs.findMatches
            && lhs.currentFindMatch == rhs.currentFindMatch
            && lhs.diagnosticIndex == rhs.diagnosticIndex
            && lhs.callbackOwnerIdentity == rhs.callbackOwnerIdentity
    }

    var body: some View {
        accessibilitySurface(
            Group {
                if interactionPolicy.allowsEditingActions {
                    interactiveRenderedBlock
                        .onTapGesture(perform: activateFromPointer)
                } else {
                    renderedBlock
                }
            }
            .background(BlockRenderProbe(blockID: block.id, onRender: onRender))
        )
    }

    private var interactiveRenderedBlock: some View {
        renderedBlock
            .frame(
                width: MarkdownHoverLayout.alignedBlockWidth(paperWidth: paperWidth),
                alignment: .leading
            )
            .background(hoverBackground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { isHovering in
                hovered = isHovering
                DebugPointerTrace.shared.recordSemantic(
                    isHovering ? "block-hover-enter" : "block-hover-exit",
                    blockIndex: diagnosticIndex,
                    blockID: block.id
                )
            }
    }

    private func activateFromPointer() {
        guard block.kind != .table else { return }
        DebugPointerTrace.shared.recordSemantic(
            "block-pointer-activate",
            blockIndex: diagnosticIndex,
            blockID: block.id
        )
        interactionPolicy.performEditingAction(onActivate)
    }

    @ViewBuilder
    private func accessibilitySurface<Content: View>(_ content: Content) -> some View {
        if interactionPolicy.exposesBlockAccessibilityAction(kind: block.kind) {
            accessibilityMetadata(content)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    interactionPolicy.performEditingAction(onActivate)
                }
        } else {
            accessibilityMetadata(content)
        }
    }

    private func accessibilityMetadata<Content: View>(_ content: Content) -> some View {
        content
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(
                MarkdownAccessibilitySurface.renderedBlock(
                    index: diagnosticIndex,
                    kind: block.kind
                )
            )
            .accessibilityLabel(
                MarkdownAccessibilitySurface.blockLabel(
                    index: diagnosticIndex,
                    kind: block.kind
                )
            )
            .accessibilityValue(projection.text)
    }

    @ViewBuilder
    private var renderedBlock: some View {
        switch block.kind {
        case .heading:
            heading
        case .paragraph:
            paragraph
        case .quote:
            quote
        case .list:
            list
        case .code:
            MarkdownCodeBlock(
                source: block.source,
                paperWidth: paperWidth,
                windowWidth: windowWidth,
                diagnosticIndex: diagnosticIndex,
                nestedListItem: nil,
                findHighlights: highlights(in: NSRange(
                    location: 0,
                    length: projection.text.utf16.count
                ))
            )
        case .table:
            MarkdownTableBlock(
                source: block.source,
                paperWidth: paperWidth,
                windowWidth: windowWidth,
                projectedRanges: projection.searchableRanges,
                findMatches: findMatches,
                currentFindMatch: currentFindMatch,
                diagnosticIndex: diagnosticIndex,
                interactionPolicy: interactionPolicy,
                onCell: onTableCell,
                onHoverURL: onHoverURL,
                onOpenURL: onOpenURL
            )
        case .image:
            image
        case .horizontalRule:
            horizontalRule
        case .footnotes:
            footnotes
        }
    }

    private var heading: some View {
        let parsed = Self.headingParts(block.source)
        let metrics = Self.headingMetrics(level: parsed.level)
        return HStack(alignment: .center, spacing: 11) {
            RoundedRectangle(cornerRadius: 2)
                .fill(DesignTokens.swiftUI.accent)
                .frame(width: metrics.barWidth, height: metrics.barHeight)
            MarkdownInlineText(
                source: parsed.title,
                style: PassiveMarkdownInlineStyle(
                    font: NSFont.systemFont(ofSize: metrics.size, weight: .semibold),
                    color: DesignTokens.headingText,
                    kern: metrics.kerning
                ),
                findHighlights: highlights(in: NSRange(
                    location: 0,
                    length: projection.text.utf16.count
                )),
                accessibilityBlockIndex: diagnosticIndex,
                accessibilityLeafScope: "heading",
                onHoverURL: onHoverURL,
                onOpenURL: onOpenURL
            )
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: metrics.lineHeight)
        .debugVisualTestBlockAnchor("document-content-\(diagnosticIndex)-heading")
        .padding(
            .top,
            isFirstBlock
                ? 0
                : MarkdownVerticalLayout.collapsedTopMargin(
                    metrics.top,
                    after: previousBottomMargin
                )
        )
        .padding(.bottom, metrics.bottom)
    }

    private var paragraph: some View {
        let source = block.source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .joined(separator: " ")
        return MarkdownInlineText(
            source: source,
            style: PassiveMarkdownInlineStyle(
                font: NSFont.systemFont(ofSize: bodyFontSize),
                color: DesignTokens.bodyText
            ),
            findHighlights: highlights(in: NSRange(
                location: 0,
                length: projection.text.utf16.count
            )),
            accessibilityBlockIndex: diagnosticIndex,
            onHoverURL: onHoverURL,
            onOpenURL: onOpenURL,
            lineSpacing: bodyFontSize * 0.4 + 1.5
        )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .padding(.bottom, paragraphLineBoxBottomLeading)
            .debugVisualTestBlockAnchor("document-content-\(diagnosticIndex)-paragraph")
            .padding(.bottom, 18)
    }

    private var paragraphLineBoxBottomLeading: CGFloat {
        let inlineExpansion = block.source.contains("<sup>") || block.source.contains("<sub>")
            ? 3.55
            : 0
        return 3.75 + inlineExpansion
    }

    private var quote: some View {
        let source = block.source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { line in
                var value = line
                while value.first == " " || value.first == "\t" { value.removeFirst() }
                if value.first == ">" { value.removeFirst() }
                if value.first == " " { value.removeFirst() }
                return value
            }
            .joined(separator: "\n")
        return HStack(alignment: .top, spacing: 14) {
            Rectangle()
                .fill(Color(hex: 0xE9E9EF))
                .frame(width: 2)
            MarkdownInlineText(
                source: source,
                style: PassiveMarkdownInlineStyle(
                    font: NSFont.systemFont(ofSize: bodyFontSize),
                    color: DesignTokens.secondaryText
                ),
                findHighlights: highlights(in: NSRange(
                    location: 0,
                    length: projection.text.utf16.count
                )),
                accessibilityBlockIndex: diagnosticIndex,
                accessibilityLeafScope: "quote",
                onHoverURL: onHoverURL,
                onOpenURL: onOpenURL,
                lineSpacing: 22 / 3
            )
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .padding(.bottom, 18)
        .debugVisualTestBlockAnchor("document-content-\(diagnosticIndex)-quote")
        .padding(.bottom, 18)
    }

    private var list: some View {
        let items = Self.listItems(block.source)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .top, spacing: 9) {
                    if let checked = item.checked {
                        taskCheckbox(
                            checked: checked,
                            itemIndex: item.taskIndex ?? 0
                        )
                    } else {
                        Text(item.displayMarker)
                            .font(.system(size: bodyFontSize))
                            .foregroundColor(DesignTokens.swiftUI.placeholderText)
                            .frame(minWidth: 20, alignment: .trailing)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        MarkdownInlineText(
                            source: item.content,
                            style: PassiveMarkdownInlineStyle(
                                font: NSFont.systemFont(ofSize: bodyFontSize),
                                color: item.checked == true
                                    ? NSColor(hex: 0xA1A1A6)
                                    : DesignTokens.bodyText
                            ),
                            findHighlights: projection.searchableRanges.indices.contains(index)
                                ? highlights(in: projection.searchableRanges[index])
                                : [],
                            accessibilityBlockIndex: diagnosticIndex,
                            accessibilityLeafScope: "list-item-\(index)",
                            onHoverURL: onHoverURL,
                            onOpenURL: onOpenURL
                        )
                        .strikethrough(item.checked == true, color: Color(hex: 0xD3D3D6))
                        listChildren(item)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(item.level) * 22)
                .padding(.vertical, 4)
                .debugVisualTestBlockAnchor(
                    "document-content-\(diagnosticIndex)-list-\(index)"
                )
                if index < items.count - 1 {
                    Color.clear
                        .frame(height: Self.hasNestedCode(item) ? 16 : 18)
                }
            }
        }
        .padding(.bottom, 18)
    }

    private var image: some View {
        let alt = Self.imageAlt(block.source)
        return ZStack {
            StripedPlaceholder()
            Text("图片占位 · \(alt.isEmpty ? "image" : alt)")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(Color(hex: 0x8E8E93))
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Color.white)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                )
        }
        .frame(height: 184)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(hex: 0xE9E9EF), lineWidth: 1)
        )
        .debugVisualTestBlockAnchor("document-content-\(diagnosticIndex)-image")
        .padding(
            .top,
            MarkdownVerticalLayout.collapsedTopMargin(6, after: previousBottomMargin)
        )
        .padding(.bottom, 20)
    }

    private var horizontalRule: some View {
        Rectangle()
            .fill(Color(hex: 0xE9E9EF))
            .frame(height: 1)
            .padding(.vertical, 14)
            .debugVisualTestBlockAnchor("document-content-\(diagnosticIndex)-horizontalRule")
            .padding(
                .top,
                MarkdownVerticalLayout.collapsedTopMargin(16, after: previousBottomMargin)
            )
            .padding(.bottom, 16)
    }

    private var footnotes: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("脚注")
                .font(.system(size: 10.5))
                .kerning(0.6)
                .foregroundColor(DesignTokens.swiftUI.placeholderText)
                .frame(height: 18, alignment: .leading)
            ForEach(PassiveFootnoteDefinitionParser.parse(block.source), id: \.id) { item in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(item.id)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(DesignTokens.swiftUI.accent)
                    MarkdownInlineText(
                        source: item.text,
                        style: PassiveMarkdownInlineStyle(
                            font: NSFont.systemFont(ofSize: 13),
                            color: DesignTokens.secondaryText
                        ),
                        accessibilityBlockIndex: diagnosticIndex,
                        accessibilityLeafScope: "footnote-definition-\(item.id)",
                        onHoverURL: onHoverURL,
                        onOpenURL: onOpenURL
                    )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("↩") { onFootnoteBack(item.id) }
                        .buttonStyle(.plain)
                        .foregroundColor(DesignTokens.swiftUI.accent)
                        .markdownPointingHandCursor()
                        .mvTip("回到引用")
                        .accessibilityIdentifier("footnote-back-\(item.id)")
                }
                .frame(minHeight: 27.5, alignment: .topLeading)
            }
        }
        .padding(.horizontal, 15)
        .padding(.top, 11)
        .padding(.bottom, 13)
        .background(Color.white)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    editHoverActive ? Color(hex: 0xB4B4BA) : Color(hex: 0xC7C7CC),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
        .cornerRadius(8)
        .shadow(color: editHoverActive ? .black.opacity(0.07) : .clear, radius: 4.5, y: 3)
        .debugVisualTestBlockAnchor("document-content-\(diagnosticIndex)-footnotes")
        .padding(
            .top,
            MarkdownVerticalLayout.collapsedTopMargin(24, after: previousBottomMargin)
        )
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private var hoverBackground: some View {
        if let spacing = MarkdownHoverLayout.outerSpacing(
            for: block,
            isFirstBlock: isFirstBlock,
            previousBottomMargin: previousBottomMargin
        ) {
            RoundedRectangle(cornerRadius: 8)
                .fill(editHoverActive ? Color.black.opacity(0.035) : Color.clear)
                .padding(.horizontal, -MarkdownHoverLayout.horizontalOutset)
                .padding(.top, spacing.top - MarkdownHoverLayout.verticalOutset)
                .padding(.bottom, spacing.bottom - MarkdownHoverLayout.verticalOutset)
                .animation(
                    MotionPolicy.animation(
                        .easeInOut(duration: 0.13),
                        reduceMotion: reduceMotion
                    ),
                    value: editHoverActive
                )
        } else {
            Color.clear
        }
    }

    private var projection: BlockVisibleTextProjection {
        BlockFindEngine.projection(for: block)
    }

    private func taskCheckbox(checked: Bool, itemIndex: Int) -> some View {
        HStack(spacing: 0) {
            Button(action: {
                interactionPolicy.performTaskToggle {
                    onTaskToggle(itemIndex)
                }
            }) {
                taskCheckboxAppearance(checked: checked)
            }
            .buttonStyle(.plain)
            .disabled(!interactionPolicy.allowsTaskToggle)
            .markdownPointingHandCursor(enabled: interactionPolicy.allowsTaskToggle)
            .accessibilityLabel(checked ? "已完成任务" : "未完成任务")
            .accessibilityValue(checked ? "已勾选" : "未勾选")
            .accessibilityIdentifier(
                MarkdownAccessibilitySurface.taskCheckbox(
                    blockIndex: diagnosticIndex,
                    taskIndex: itemIndex
                )
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("第 \(itemIndex + 1) 个任务")
        .accessibilityValue(checked ? "已勾选" : "未勾选")
    }

    private func taskCheckboxAppearance(checked: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(checked ? DesignTokens.swiftUI.accent : .white)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            checked ? Color.clear : Color(hex: 0xD0D0D5),
                            lineWidth: checked ? 0 : 1.4
                        )
                )
            if checked {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .frame(width: 16, height: 16)
    }

    private func highlights(in visibleRange: NSRange) -> [PassiveFindHighlight] {
        findMatches.compactMap { match in
            let intersection = NSIntersectionRange(match.visibleRange, visibleRange)
            guard intersection.length == match.visibleRange.length else { return nil }
            return PassiveFindHighlight(
                range: NSRange(
                    location: intersection.location - visibleRange.location,
                    length: intersection.length
                ),
                isCurrent: match == currentFindMatch
            )
        }
    }

    private static func headingParts(_ source: String) -> (level: Int, title: String) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let level = min(6, trimmed.prefix(while: { $0 == "#" }).count)
        let title = trimmed.dropFirst(level)
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
        return (max(1, level), title)
    }

    private static func headingMetrics(level: Int) -> (
        size: CGFloat,
        kerning: CGFloat,
        barWidth: CGFloat,
        barHeight: CGFloat,
        lineHeight: CGFloat,
        top: CGFloat,
        bottom: CGFloat
    ) {
        switch level {
        case 1:
            return (26, -0.2, 4, 19, MarkdownVerticalLayout.headingLineHeight(level: 1),
                    MarkdownVerticalLayout.headingTopMargin(level: 1), 16)
        case 2:
            return (20, -0.1, 3.5, 15, MarkdownVerticalLayout.headingLineHeight(level: 2),
                    MarkdownVerticalLayout.headingTopMargin(level: 2), 14)
        case 3:
            return (17, 0, 3, 12, MarkdownVerticalLayout.headingLineHeight(level: 3),
                    MarkdownVerticalLayout.headingTopMargin(level: 3), 10)
        case 4:
            return (15.5, 0, 2.5, 11, MarkdownVerticalLayout.headingLineHeight(level: 4),
                    MarkdownVerticalLayout.headingTopMargin(level: 4), 8)
        case 5:
            return (14, 0.4, 2, 10, MarkdownVerticalLayout.headingLineHeight(level: 5),
                    MarkdownVerticalLayout.headingTopMargin(level: 5), 6)
        default:
            return (13, 0.4, 2, 9, MarkdownVerticalLayout.headingLineHeight(level: 6),
                    MarkdownVerticalLayout.headingTopMargin(level: 6), 6)
        }
    }

    private struct ListItem: Identifiable {
        let lineIndex: Int
        let level: Int
        let marker: String
        let content: String
        let checked: Bool?
        let taskIndex: Int?
        var children: [String]
        var id: Int { lineIndex }

        var displayMarker: String {
            if ["-", "+", "*"].contains(marker) {
                return ["•", "◦", "▪"][level % 3]
            }
            return MarkdownListMarkerFormatter.display(marker: marker, level: level)
        }
    }

    private static func listItems(_ source: String) -> [ListItem] {
        let pattern = #"^(\s*)([-+*]|\d+[.)]|[A-Za-z]+[.)])\s+(?:\[([ xX])\]\s+)?(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var result: [ListItem] = []
        var taskIndex = 0
        for (index, line) in lines.enumerated() {
            guard let match = regex.firstMatch(
                in: line,
                range: NSRange(location: 0, length: (line as NSString).length)
            ) else {
                if !result.isEmpty { result[result.count - 1].children.append(line) }
                continue
            }
            let ns = line as NSString
            let indent = ns.substring(with: match.range(at: 1)).count
            let marker = ns.substring(with: match.range(at: 2))
            let checked: Bool?
            let itemTaskIndex: Int?
            if match.range(at: 3).location == NSNotFound {
                checked = nil
                itemTaskIndex = nil
            } else {
                checked = ns.substring(with: match.range(at: 3)).lowercased() == "x"
                itemTaskIndex = taskIndex
                taskIndex += 1
            }
            let ordered = !["-", "+", "*"].contains(marker)
            result.append(ListItem(
                lineIndex: index,
                level: max(0, indent / (ordered ? 3 : 2)),
                marker: marker,
                content: ns.substring(with: match.range(at: 4)),
                checked: checked,
                taskIndex: itemTaskIndex,
                children: []
            ))
        }
        return result
    }

    @ViewBuilder
    private func listChildren(_ item: ListItem) -> some View {
        let lines = Self.dedented(item.children)
        if !lines.isEmpty {
            let childSource = lines.joined(separator: "\n")
            if Self.startsWithFence(childSource) {
                MarkdownCodeBlock(
                    source: childSource,
                    paperWidth: paperWidth,
                    windowWidth: windowWidth,
                    diagnosticIndex: diagnosticIndex,
                    nestedListItem: item.lineIndex,
                    findHighlights: [],
                    bottomMargin: 0
                )
                    .padding(.top, 17)
            } else {
                MarkdownInlineText(
                    source: childSource,
                    style: PassiveMarkdownInlineStyle(
                        font: NSFont.systemFont(ofSize: bodyFontSize),
                        color: DesignTokens.bodyText
                    ),
                    accessibilityBlockIndex: diagnosticIndex,
                    accessibilityLeafScope: "list-item-\(item.lineIndex)-child",
                    onHoverURL: onHoverURL,
                    onOpenURL: onOpenURL
                )
            }
        }
    }

    private static func dedented(_ lines: [String]) -> [String] {
        let content = lines.drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        guard !content.isEmpty else { return [] }
        let widths = content
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { line in line.prefix(while: { $0 == " " || $0 == "\t" }).count }
        let width = widths.min() ?? 0
        return content.map { line in
            String(line.dropFirst(min(width, line.prefix(while: { $0 == " " || $0 == "\t" }).count)))
        }
    }

    private static func hasNestedCode(_ item: ListItem) -> Bool {
        let source = dedented(item.children)
            .joined(separator: "\n")
        return startsWithFence(source)
    }

    private static func startsWithFence(_ source: String) -> Bool {
        guard let first = source
            .components(separatedBy: .newlines)
            .drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            .first else { return false }
        return MarkdownFenceSyntax.openingFence(in: first) != nil
    }

    private static func imageAlt(_ source: String) -> String {
        guard let start = source.range(of: "![")?.upperBound,
              let end = source[start...].firstIndex(of: "]") else { return "" }
        return String(source[start..<end])
    }

}

final class BlockRenderProbeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private struct BlockRenderProbe: NSViewRepresentable {
    let blockID: UUID
    let onRender: (UUID) -> Void

    func makeNSView(context: Context) -> NSView {
        onRender(blockID)
        let view = BlockRenderProbeView(frame: .zero)
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        onRender(blockID)
    }
}

enum MarkdownListMarkerFormatter {
    static func display(marker: String, level: Int) -> String {
        guard let last = marker.last, last == "." || last == ")" else { return marker }
        let body = String(marker.dropLast()).lowercased()
        let normalizedLevel = max(0, level)
        let value = orderedValue(body, level: normalizedLevel)
        let rendered: String
        switch normalizedLevel % 3 {
        case 1:
            rendered = alphabetic(value)
        case 2:
            rendered = roman(value)
        default:
            rendered = String(value)
        }
        return rendered + String(last)
    }

    private static func orderedValue(_ body: String, level: Int) -> Int {
        if let number = Int(body), number > 0 { return number }
        if level % 3 == 2, body.range(of: #"^[ivxlcdm]+$"#, options: .regularExpression) != nil {
            return romanValue(body)
        }
        if body.range(of: #"^[a-z]+$"#, options: .regularExpression) != nil {
            return alphabeticValue(body)
        }
        return 1
    }

    private static func alphabetic(_ value: Int) -> String {
        var number = max(1, value)
        var characters: [Character] = []
        while number > 0 {
            number -= 1
            let scalar = UnicodeScalar(97 + number % 26) ?? UnicodeScalar(97)!
            characters.append(Character(scalar))
            number /= 26
        }
        return String(characters.reversed())
    }

    private static func alphabeticValue(_ marker: String) -> Int {
        marker.unicodeScalars.reduce(0) { value, scalar in
            value * 26 + max(1, Int(scalar.value) - 96)
        }
    }

    private static func roman(_ value: Int) -> String {
        let tokens: [(Int, String)] = [
            (1_000, "m"), (900, "cm"), (500, "d"), (400, "cd"),
            (100, "c"), (90, "xc"), (50, "l"), (40, "xl"),
            (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
        ]
        var number = max(1, value)
        var result = ""
        for (tokenValue, token) in tokens {
            while number >= tokenValue {
                result += token
                number -= tokenValue
            }
        }
        return result
    }

    private static func romanValue(_ marker: String) -> Int {
        let values: [Character: Int] = [
            "i": 1, "v": 5, "x": 10, "l": 50,
            "c": 100, "d": 500, "m": 1_000,
        ]
        let characters = Array(marker)
        return max(1, characters.indices.reduce(0) { sum, index in
            let current = values[characters[index], default: 0]
            let next = index + 1 < characters.count
                ? values[characters[index + 1], default: 0]
                : 0
            return sum + (current < next ? -current : current)
        })
    }
}

struct MarkdownInlineText: View {
    let source: String
    let style: PassiveMarkdownInlineStyle
    var findHighlights: [PassiveFindHighlight] = []
    var accessibilityBlockIndex: Int? = nil
    var accessibilityLeafScope: String? = nil
    var onHoverURL: (String, CGRect?) -> Void = { _, _ in }
    var onOpenURL: (String) -> Void = { _ in }
    var lineSpacing: CGFloat = 0

    var body: some View {
        let rendered = PassiveMarkdownInlineRenderer.render(
            source,
            style: style,
            findHighlights: findHighlights
        )
        Text(AttributedString(displayString(from: rendered)))
            .lineSpacing(lineSpacing)
            .overlay {
                if rendered.containsLinks {
                    PassiveInlineLinkHoverLayer(
                        attributed: rendered,
                        accessibilityBlockIndex: accessibilityBlockIndex,
                        accessibilityLeafScope: accessibilityLeafScope,
                        lineSpacing: lineSpacing,
                        onHoverURL: onHoverURL,
                        onOpenURL: onOpenURL
                    )
                }
            }
    }

    private func displayString(from rendered: NSAttributedString) -> NSAttributedString {
        let display = NSMutableAttributedString(attributedString: rendered)
        display.removeAttribute(.link, range: NSRange(location: 0, length: display.length))
        return display
    }
}

/// Gives compact rendered-document controls the pointer cursor declared by the
/// prototype without replacing their native SwiftUI button semantics.
private struct MarkdownPointingHandCursor: ViewModifier {
    let enabled: Bool
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                guard enabled else {
                    popIfNeeded()
                    return
                }
                if hovering {
                    pushIfNeeded()
                } else {
                    popIfNeeded()
                }
            }
            .onChange(of: enabled) { isEnabled in
                if !isEnabled { popIfNeeded() }
            }
            .onDisappear { popIfNeeded() }
    }

    private func pushIfNeeded() {
        guard !pushed else { return }
        NSCursor.pointingHand.push()
        pushed = true
    }

    private func popIfNeeded() {
        guard pushed else { return }
        NSCursor.pop()
        pushed = false
    }
}

private extension View {
    func markdownPointingHandCursor(enabled: Bool = true) -> some View {
        modifier(MarkdownPointingHandCursor(enabled: enabled))
    }
}

private struct MarkdownCodeBlock: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let source: String
    let paperWidth: CGFloat
    let windowWidth: CGFloat
    let diagnosticIndex: Int
    let nestedListItem: Int?
    let findHighlights: [PassiveFindHighlight]
    var bottomMargin: CGFloat = 20
    @State private var hovered = false
    @State private var showsTrailingFade = false

    private var parts: (language: String, code: String) {
        guard let content = MarkdownFenceSyntax.content(in: source) else {
            return ("text", source)
        }
        return (
            content.language.isEmpty ? "text" : content.language,
            content.code
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(parts.language.uppercased())
                    .font(.system(size: 10.5, design: .monospaced))
                    .kerning(0.6)
                    .foregroundColor(Color(hex: 0xB3B3B8))
                Spacer()
                HStack(spacing: 0) {
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(parts.code, forType: .string)
                        Toaster.shared.flash("已复制代码")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(hovered
                        ? DesignTokens.swiftUI.titleText
                        : DesignTokens.swiftUI.placeholderText)
                    .opacity(hovered ? 1 : 0)
                    .animation(
                        MotionPolicy.animation(
                            .easeInOut(duration: 0.15),
                            reduceMotion: reduceMotion
                        ),
                        value: hovered
                    )
                    .markdownPointingHandCursor()
                    .mvTip("复制代码")
                    .accessibilityIdentifier(
                        MarkdownAccessibilitySurface.codeCopy(
                            blockIndex: diagnosticIndex,
                            nestedListItem: nestedListItem
                        )
                    )
                    .accessibilityLabel("复制代码")
                    .accessibilityValue(parts.language)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("代码复制操作")
                .accessibilityValue(parts.language)
            }
            .padding(.horizontal, 14)
            .padding(.top, 9)
            .padding(.bottom, 2)

            ZStack(alignment: .trailing) {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(AttributedString(highlightedCode))
                        .lineSpacing(6)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.leading, 16)
                        .padding(.trailing, 44)
                        .padding(.top, 4)
                        .padding(.bottom, 26)
                        .background(
                            HorizontalOverflowObserver { showsTrailingFade = $0 }
                                .frame(width: 1, height: 1)
                        )
                }
                if showsTrailingFade {
                    LinearGradient(
                        colors: [Color(hex: 0xF6F6F9).opacity(0), Color(hex: 0xF6F6F9)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 44)
                        .allowsHitTesting(false)
                }
            }
            .padding(
                .bottom,
                MarkdownHorizontalScrollerLayout.reservedGutterHeight(
                    paperWidth: paperWidth,
                    windowWidth: windowWidth,
                    overflows: showsTrailingFade
                )
            )
        }
        .background(Color(hex: 0xF6F6F9))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(hovered ? Color(hex: 0xD2D2D8) : Color(hex: 0xE9E9EF), lineWidth: 1)
        )
        .shadow(color: hovered ? .black.opacity(0.08) : .clear, radius: 4.5, y: 3)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            MarkdownAccessibilitySurface.codeCard(
                blockIndex: diagnosticIndex,
                nestedListItem: nestedListItem
            )
        )
        .accessibilityLabel("代码块")
        .accessibilityValue(parts.language)
        .debugVisualTestBlockAnchor("document-content-\(diagnosticIndex)-code")
        .padding(.bottom, bottomMargin)
    }

    private var highlightedCode: NSAttributedString {
        let attributed = NSMutableAttributedString(attributedString: PassiveCodeHighlighter.highlight(
            parts.code,
            language: parts.language
        ))
        for highlight in findHighlights {
            guard highlight.range.location >= 0,
                  highlight.range.length > 0,
                  NSMaxRange(highlight.range) <= attributed.length else { continue }
            attributed.addAttribute(
                .backgroundColor,
                value: highlight.isCurrent ? DesignTokens.accentStrong : DesignTokens.accentSoft,
                range: highlight.range
            )
        }
        return attributed
    }
}

private struct HorizontalOverflowObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> NSView {
        let view = HorizontalObserverView(frame: .zero)
        view.onAttach = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.attach(from: view)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.attach(from: view)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var onChange: (Bool) -> Void
        private weak var scrollView: NSScrollView?
        private var observer: NSObjectProtocol?

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
        }

        func attach(from view: NSView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let scrollView = view?.enclosingScrollView else { return }
                if self.scrollView !== scrollView {
                    self.detach()
                    self.scrollView = scrollView
                    scrollView.contentView.postsBoundsChangedNotifications = true
                    self.observer = NotificationCenter.default.addObserver(
                        forName: NSView.boundsDidChangeNotification,
                        object: scrollView.contentView,
                        queue: .main
                    ) { [weak self] _ in self?.publish() }
                }
                self.publish()
            }
        }

        func detach() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            scrollView = nil
        }

        private func publish() {
            guard let scrollView else { return }
            let documentWidth = scrollView.documentView?.bounds.width ?? 0
            let viewportWidth = scrollView.contentView.bounds.width
            let x = scrollView.contentView.bounds.origin.x
            onChange(documentWidth - viewportWidth - x > 1)
        }
    }
}

private final class HorizontalObserverView: NSView {
    var onAttach: (() -> Void)?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        onAttach?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onAttach?()
    }
}

private struct MarkdownTableBlock: View {
    let source: String
    let paperWidth: CGFloat
    let windowWidth: CGFloat
    let projectedRanges: [NSRange]
    let findMatches: [BlockFindMatch]
    let currentFindMatch: BlockFindMatch?
    let diagnosticIndex: Int
    let interactionPolicy: MarkdownBlockInteractionPolicy
    let onCell: (MarkdownTableCell) -> Void
    let onHoverURL: (String, CGRect?) -> Void
    let onOpenURL: (String) -> Void
    @State private var hovered = false

    private var editHoverActive: Bool {
        interactionPolicy.showsEditHoverCue(hovered: hovered)
    }

    @ViewBuilder
    var body: some View {
        if interactionPolicy.allowsEditingActions {
            tableCard
                .onHover { hovered = $0 }
        } else {
            tableCard
        }
    }

    private var tableCard: some View {
        Group {
            if let grid = try? MarkdownTableGrid(parsing: source) {
                let columnWidths = resolvedColumnWidths(for: grid)
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        tableRow(
                            grid.header,
                            row: -1,
                            grid: grid,
                            header: true,
                            columnWidths: columnWidths
                        )
                        ForEach(Array(grid.rows.enumerated()), id: \.offset) { row, cells in
                            tableRow(
                                cells,
                                row: row,
                                grid: grid,
                                header: false,
                                columnWidths: columnWidths
                            )
                        }
                    }
                    .frame(
                        minHeight: MarkdownTableLayout.cardHeight(bodyRowCount: grid.rows.count),
                        alignment: .top
                    )
                    .fixedSize(horizontal: true, vertical: false)
                }
                .padding(
                    .bottom,
                    MarkdownHorizontalScrollerLayout.reservedGutterHeight(
                        paperWidth: paperWidth,
                        windowWidth: windowWidth,
                        overflows: CGFloat(grid.columnCount)
                            * MarkdownTableLayout.minimumColumnWidth > paperWidth
                    )
                )
            } else {
                MarkdownInlineText(
                    source: source,
                    style: PassiveMarkdownInlineStyle(
                        font: NSFont.systemFont(ofSize: 13.5),
                        color: DesignTokens.bodyText
                    ),
                    accessibilityBlockIndex: diagnosticIndex,
                    accessibilityLeafScope: "table-fallback",
                    onHoverURL: onHoverURL,
                    onOpenURL: onOpenURL
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0xFBFBFC))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    editHoverActive ? Color(hex: 0xD2D2D8) : Color(hex: 0xE9E9EF),
                    lineWidth: 1
                )
        )
        .shadow(color: editHoverActive ? .black.opacity(0.08) : .clear, radius: 4.5, y: 3)
        .debugVisualTestBlockAnchor("document-content-\(diagnosticIndex)-table")
        .padding(.bottom, 20)
    }

    private func tableRow(
        _ cells: [String],
        row: Int,
        grid: MarkdownTableGrid,
        header: Bool,
        columnWidths: [CGFloat]
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(cells.indices, id: \.self) { column in
                tableCell(
                    value: cells[column],
                    row: row,
                    column: column,
                    grid: grid,
                    header: header,
                    columnWidth: columnWidths[column]
                )
            }
        }
        .background(header ? Color(hex: 0xF6F6F9) : Color(hex: 0xFBFBFC))
        .overlay(alignment: .bottom) {
            if header || row < grid.rows.count - 1 {
                Rectangle().fill(Color(hex: 0xF0F0F1)).frame(height: 1)
            }
        }
    }

    @ViewBuilder
    private func tableCell(
        value: String,
        row: Int,
        column: Int,
        grid: MarkdownTableGrid,
        header: Bool,
        columnWidth: CGFloat
    ) -> some View {
        if interactionPolicy.allowsEditingActions {
            Button(action: {
                interactionPolicy.performEditingAction {
                    onCell(MarkdownTableCell(row: row, column: column))
                }
            }) {
                tableCellContent(
                    value: value,
                    row: row,
                    column: column,
                    grid: grid,
                    header: header,
                    columnWidth: columnWidth
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(cellAccessibilityIdentifier(row: row, column: column))
            .accessibilityLabel(
                MarkdownAccessibilitySurface.tableCellLabel(row: row, column: column)
            )
            .accessibilityValue(value)
        } else {
            tableCellContent(
                value: value,
                row: row,
                column: column,
                grid: grid,
                header: header,
                columnWidth: columnWidth
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(cellAccessibilityIdentifier(row: row, column: column))
            .accessibilityLabel(
                MarkdownAccessibilitySurface.tableCellLabel(row: row, column: column)
            )
            .accessibilityValue(value)
        }
    }

    private func cellAccessibilityIdentifier(row: Int, column: Int) -> String {
        MarkdownAccessibilitySurface.passiveTableCell(
            blockIndex: diagnosticIndex,
            row: row,
            column: column
        )
    }

    private func tableCellContent(
        value: String,
        row: Int,
        column: Int,
        grid: MarkdownTableGrid,
        header: Bool,
        columnWidth: CGFloat
    ) -> some View {
        MarkdownInlineText(
            source: header ? value.uppercased() : value,
            style: PassiveMarkdownInlineStyle(
                font: NSFont.systemFont(
                    ofSize: header ? 12 : 13.5,
                    weight: header ? .bold : .regular
                ),
                color: header ? DesignTokens.titleText : DesignTokens.bodyText,
                kern: header ? 0.4 : 0
            ),
            findHighlights: highlights(row: row, column: column, grid: grid),
            accessibilityBlockIndex: diagnosticIndex,
            accessibilityLeafScope: header
                ? "table-header-column-\(column)"
                : "table-row-\(row)-column-\(column)",
            onHoverURL: onHoverURL,
            onOpenURL: onOpenURL
        )
        .frame(
            width: max(0, columnWidth - 28),
            alignment: alignment(grid.alignments[column])
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: MarkdownTableLayout.rowHeight(header: header))
        .background(header ? Color(hex: 0xF6F6F9) : Color(hex: 0xFBFBFC))
    }

    private func resolvedColumnWidths(for grid: MarkdownTableGrid) -> [CGFloat] {
        let minimum = MarkdownTableLayout.columnWidth(
            availableWidth: paperWidth,
            columnCount: grid.columnCount
        )
        return grid.header.indices.map { column in
            let headerWidth = intrinsicCellWidth(grid.header[column], header: true)
            let bodyWidth = grid.rows.reduce(CGFloat.zero) { widest, row in
                max(widest, intrinsicCellWidth(row[column], header: false))
            }
            return max(minimum, max(headerWidth, bodyWidth))
        }
    }

    private func intrinsicCellWidth(_ source: String, header: Bool) -> CGFloat {
        let rendered = PassiveMarkdownInlineRenderer.render(
            header ? source.uppercased() : source,
            style: PassiveMarkdownInlineStyle(
                font: NSFont.systemFont(
                    ofSize: header ? 12 : 13.5,
                    weight: header ? .bold : .regular
                ),
                color: header ? DesignTokens.titleText : DesignTokens.bodyText,
                kern: header ? 0.4 : 0
            )
        )
        let bounds = rendered.boundingRect(
            with: NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(bounds.width) + 28
    }

    private func highlights(
        row: Int,
        column: Int,
        grid: MarkdownTableGrid
    ) -> [PassiveFindHighlight] {
        let flatIndex = row < 0
            ? column
            : grid.columnCount + row * grid.columnCount + column
        guard projectedRanges.indices.contains(flatIndex) else { return [] }
        let cellRange = projectedRanges[flatIndex]
        return findMatches.compactMap { match in
            let intersection = NSIntersectionRange(match.visibleRange, cellRange)
            guard intersection.length == match.visibleRange.length else { return nil }
            return PassiveFindHighlight(
                range: NSRange(
                    location: intersection.location - cellRange.location,
                    length: intersection.length
                ),
                isCurrent: match == currentFindMatch
            )
        }
    }

    private func alignment(_ alignment: MarkdownTableAlignment) -> Alignment {
        switch alignment {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
}

enum MarkdownTableLayout {
    static let minimumColumnWidth: CGFloat = 120
    static let headerRowHeight: CGFloat = 39
    static let bodyRowHeight: CGFloat = 41.5

    static func rowHeight(header: Bool) -> CGFloat {
        header ? headerRowHeight : bodyRowHeight
    }

    static func cardHeight(bodyRowCount: Int) -> CGFloat {
        ceil(headerRowHeight + CGFloat(max(0, bodyRowCount)) * bodyRowHeight)
    }

    static func columnWidth(
        availableWidth: CGFloat,
        columnCount: Int,
        minimumWidth: CGFloat = minimumColumnWidth
    ) -> CGFloat {
        guard columnCount > 0 else { return max(0, minimumWidth) }
        return max(max(0, minimumWidth), max(0, availableWidth) / CGFloat(columnCount))
    }
}

private struct StripedPlaceholder: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0xF5F5F6)))
            var path = Path()
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 22
            }
            context.stroke(path, with: .color(Color(hex: 0xEFEFF1)), lineWidth: 11)
        }
    }
}
