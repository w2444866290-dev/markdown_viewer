import AppKit
import SwiftUI

enum MarkdownTableEditorLayout {
    static let toolbarHeight: CGFloat = 32
    static let toolbarToGridSpacing: CGFloat = 10
    static let headerRowHeight: CGFloat = 45
    static let bodyRowHeight: CGFloat = 33
    static let gridToHelpSpacing: CGFloat = 9
    static let helpHeight: CGFloat = 18
    static let topPadding: CGFloat = 2
    static let bottomPadding: CGFloat = 6
    static let blockSpacing: CGFloat = 20

    static func rowHeight(header: Bool) -> CGFloat {
        header ? headerRowHeight : bodyRowHeight
    }

    static func gridHeight(bodyRowCount: Int) -> CGFloat {
        headerRowHeight + CGFloat(max(0, bodyRowCount)) * bodyRowHeight
    }

    static func editorHeight(bodyRowCount: Int) -> CGFloat {
        topPadding
            + toolbarHeight
            + toolbarToGridSpacing
            + gridHeight(bodyRowCount: bodyRowCount)
            + gridToHelpSpacing
            + helpHeight
            + bottomPadding
            + blockSpacing
    }
}

struct MarkdownTableCellFocusRequestState {
    private var wasSelected = false

    mutating func update(isSelected: Bool) -> Bool {
        defer { wasSelected = isSelected }
        return isSelected && !wasSelected
    }
}

struct MarkdownTableFindHighlight: Equatable {
    let range: NSRange
    let isCurrent: Bool
}

enum MarkdownTableFindFormatter {
    static func attributedValue(
        _ value: String,
        font: NSFont,
        textColor: NSColor,
        highlights: [MarkdownTableFindHighlight]
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: value,
            attributes: [
                .font: font,
                .foregroundColor: textColor,
            ]
        )
        let length = (value as NSString).length
        for highlight in highlights where isValid(highlight.range, length: length) {
            result.addAttribute(
                .backgroundColor,
                value: highlight.isCurrent
                    ? DesignTokens.accentStrong
                    : DesignTokens.accentSoft,
                range: highlight.range
            )
        }
        return result
    }

    static func applyTemporaryHighlights(
        _ highlights: [MarkdownTableFindHighlight],
        to textView: NSTextView
    ) {
        guard let layoutManager = textView.layoutManager else { return }
        let length = (textView.string as NSString).length
        let fullRange = NSRange(location: 0, length: length)
        layoutManager.removeTemporaryAttribute(
            .backgroundColor,
            forCharacterRange: fullRange
        )
        for highlight in highlights where isValid(highlight.range, length: length) {
            layoutManager.addTemporaryAttribute(
                .backgroundColor,
                value: highlight.isCurrent
                    ? DesignTokens.accentStrong
                    : DesignTokens.accentSoft,
                forCharacterRange: highlight.range
            )
        }
        layoutManager.invalidateDisplay(forCharacterRange: fullRange)
    }

    private static func isValid(_ range: NSRange, length: Int) -> Bool {
        range.location >= 0
            && range.length > 0
            && NSMaxRange(range) <= length
    }
}

@MainActor
final class MarkdownTableEditorBridge {
    struct Snapshot: Equatable {
        let cell: MarkdownTableCell
        let value: String
        let hadMarkedText: Bool
    }

    private weak var activeField: NSTextField?
    private var activeCell: MarkdownTableCell?
    private var onValue: ((String) -> Void)?
    private var isFlushing = false

    func snapshot() -> Snapshot? {
        guard let activeField, let activeCell else { return nil }
        let editor = activeField.currentEditor() as? NSTextView
        return Snapshot(
            cell: activeCell,
            value: editor?.string ?? activeField.stringValue,
            hadMarkedText: editor?.hasMarkedText() == true
        )
    }

    @discardableResult
    func flushForLifecycleBoundary() -> Snapshot? {
        guard !isFlushing,
              let activeField,
              let activeCell else { return snapshot() }
        isFlushing = true
        defer { isFlushing = false }

        let editor = activeField.currentEditor() as? NSTextView
        let hadMarkedText = editor?.hasMarkedText() == true
        if hadMarkedText { editor?.unmarkText() }
        let value = editor?.string ?? activeField.stringValue
        activeField.stringValue = value
        onValue?(value)
        return Snapshot(
            cell: activeCell,
            value: value,
            hadMarkedText: hadMarkedText
        )
    }

    func activate(
        field: NSTextField,
        cell: MarkdownTableCell,
        onValue: @escaping (String) -> Void
    ) {
        if let activeField, activeField !== field {
            _ = flushForLifecycleBoundary()
        }
        activeField = field
        activeCell = cell
        self.onValue = onValue
    }

    func deactivate(field: NSTextField, flush: Bool = true) {
        guard activeField === field else { return }
        if flush { _ = flushForLifecycleBoundary() }
        activeField = nil
        activeCell = nil
        onValue = nil
    }

    func resetAfterCommit() {
        activeField = nil
        activeCell = nil
        onValue = nil
    }
}

struct MarkdownTableGridEditor: View {
    @ObservedObject var store: BlockEditorStore
    let paperWidth: CGFloat
    @State private var keyMonitor: Any?

    private var grid: MarkdownTableGrid? { store.tableDraft }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            if let grid {
                let findHighlightsByCell = tableFindHighlightsByCell()
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        VStack(spacing: 0) {
                            gridRow(
                                grid.header,
                                row: -1,
                                header: true,
                                grid: grid,
                                findHighlightsByCell: findHighlightsByCell
                            )
                            ForEach(Array(grid.rows.enumerated()), id: \.offset) { row, values in
                                gridRow(
                                    values,
                                    row: row,
                                    header: false,
                                    grid: grid,
                                    findHighlightsByCell: findHighlightsByCell
                                )
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .background(Color(hex: 0xFBFBFC))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(hex: 0xE9E9EF), lineWidth: 1)
                    )
                    .debugVisualAnchor("table-grid-frame")
                    .onChange(of: store.currentFindTableCell) { cell in
                        guard let cell else { return }
                        proxy.scrollTo(cell, anchor: .center)
                    }
                    .onAppear {
                        if let cell = store.currentFindTableCell {
                            proxy.scrollTo(cell, anchor: .center)
                        }
                    }
                    .padding(.top, MarkdownTableEditorLayout.toolbarToGridSpacing)
                }
            }
            Text("Tab / 回车 移动单元格 · Esc 完成")
                .font(.system(size: 11))
                .foregroundColor(DesignTokens.swiftUI.placeholderText)
                .frame(
                    maxWidth: .infinity,
                    minHeight: MarkdownTableEditorLayout.helpHeight,
                    maxHeight: MarkdownTableEditorLayout.helpHeight,
                    alignment: .leading
                )
                .padding(.top, MarkdownTableEditorLayout.gridToHelpSpacing)
        }
        .padding(.leading, 14)
        .padding(.top, MarkdownTableEditorLayout.topPadding)
        .padding(.bottom, MarkdownTableEditorLayout.bottomPadding)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(DesignTokens.swiftUI.accent)
                .frame(width: 3)
        }
        .padding(.leading, -14)
        .padding(.bottom, MarkdownTableEditorLayout.blockSpacing)
        .onAppear {
            installKeyMonitor()
        }
        .onDisappear { removeKeyMonitor() }
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            toolbarButton("＋行", tip: "添加行", identifier: "table-add-row") {
                store.addTableRow()
            }
            toolbarButton("＋列", tip: "添加列", identifier: "table-add-column") {
                store.addTableColumn()
            }
            divider
            toolbarButton(
                alignmentLabel,
                tip: "切换当前列对齐方式",
                identifier: "table-cycle-alignment",
                muted: true
            ) {
                store.cycleActiveTableAlignment()
            }
            divider
            toolbarButton(
                "删行",
                tip: "删除当前行",
                identifier: "table-delete-row",
                danger: true
            ) {
                store.deleteActiveTableRow()
            }
            toolbarButton(
                "删列",
                tip: "删除当前列",
                identifier: "table-delete-column",
                danger: true
            ) {
                store.deleteActiveTableColumn()
            }
        }
        .padding(.horizontal, 4)
        .frame(height: MarkdownTableEditorLayout.toolbarHeight)
        .background(Color(hex: 0x1C1C1E).opacity(0.92))
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.2), radius: 10, y: 6)
    }

    private var alignmentLabel: String {
        guard let grid,
              let column = store.activeTableCell?.column,
              grid.alignments.indices.contains(column) else { return "左对齐" }
        switch grid.alignments[column] {
        case .left: return "左对齐"
        case .center: return "居中"
        case .right: return "右对齐"
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.2))
            .frame(width: 1, height: 14)
    }

    private func toolbarButton(
        _ label: String,
        tip: String,
        identifier: String,
        muted: Bool = false,
        danger: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(label, action: action)
            .buttonStyle(GridToolbarButtonStyle(muted: muted, danger: danger))
            .mvTip(tip)
            .accessibilityIdentifier(identifier)
    }

    private func gridRow(
        _ values: [String],
        row: Int,
        header: Bool,
        grid: MarkdownTableGrid,
        findHighlightsByCell: [MarkdownTableCell: [MarkdownTableFindHighlight]]
    ) -> some View {
        let columnWidth = MarkdownTableLayout.columnWidth(
            availableWidth: paperWidth,
            columnCount: grid.columnCount
        )
        return HStack(spacing: 0) {
            ForEach(values.indices, id: \.self) { column in
                let cell = MarkdownTableCell(row: row, column: column)
                let findHighlights = findHighlightsByCell[cell, default: []]
                let hasFindMatch = !findHighlights.isEmpty
                let isCurrentFindMatch = findHighlights.contains { $0.isCurrent }
                MarkdownTableCellTextField(
                    value: value(for: cell),
                    cell: cell,
                    isFocused: store.activeTableCell == cell,
                    font: .systemFont(
                        ofSize: header ? 11 : 13.5,
                        weight: header ? .semibold : .regular
                    ),
                    textColor: header ? DesignTokens.tertiaryText : DesignTokens.bodyText,
                    alignment: textAlignment(grid.alignments[column]),
                    findHighlights: findHighlights,
                    accessibilityIdentifier: "table-cell-\(row)-\(column)",
                    lifecycleBridge: store.tableEditorBridge,
                    onChange: { [weak store] value in
                        store?.setTableCell(cell, value: value)
                    },
                    onFocus: { [weak store] in
                        store?.activeTableCell = cell
                    }
                )
                    .padding(.horizontal, 2)
                    .padding(.vertical, 3)
                    .frame(width: max(72, columnWidth - 24))
                    .padding(.horizontal, 12)
                    .padding(.vertical, header ? 5 : 2)
                    .frame(height: MarkdownTableEditorLayout.rowHeight(header: header))
                    .background(header ? Color(hex: 0xF6F6F9) : Color(hex: 0xFBFBFC))
                    .overlay(alignment: .bottom) {
                        if header || row < grid.rows.count - 1 {
                            Rectangle().fill(Color(hex: 0xF0F0F1)).frame(height: 1)
                        }
                    }
                    .overlay {
                        if store.activeTableCell == cell {
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(DesignTokens.swiftUI.accent.opacity(0.7), lineWidth: 2)
                                .padding(.horizontal, 10)
                                .padding(.vertical, header ? 5 : 2)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityIdentifier("table-cell-\(row)-\(column)")
                    .accessibilityValue(
                        isCurrentFindMatch
                            ? "当前查找结果"
                            : (hasFindMatch ? "查找结果" : "")
                    )
                    .id(cell)
            }
        }
    }

    private func tableFindHighlightsByCell() -> [
        MarkdownTableCell: [MarkdownTableFindHighlight]
    ] {
        guard let blockID = store.activeTableID else { return [:] }
        var result: [MarkdownTableCell: [MarkdownTableFindHighlight]] = [:]
        for match in store.findMatches(for: blockID) {
            guard let target = match.tableCell else { continue }
            let cell = MarkdownTableCell(row: target.row, column: target.column)
            result[cell, default: []].append(MarkdownTableFindHighlight(
                range: target.range,
                isCurrent: match == store.currentFindMatch
            ))
        }
        return result
    }

    private func value(for cell: MarkdownTableCell) -> String {
        guard let grid = store.tableDraft else { return "" }
        if cell.row < 0 {
            return grid.header.indices.contains(cell.column) ? grid.header[cell.column] : ""
        }
        return grid.rows.indices.contains(cell.row)
            && grid.rows[cell.row].indices.contains(cell.column)
            ? grid.rows[cell.row][cell.column]
            : ""
    }

    private func textAlignment(_ alignment: MarkdownTableAlignment) -> NSTextAlignment {
        switch alignment {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard store.activeTableID != nil,
                  store.activeTableCell != nil else { return event }
            switch event.keyCode {
            case 48:
                guard store.tableEditorBridge.snapshot()?.hadMarkedText != true else {
                    return event
                }
                store.moveTableFocus(
                    forward: !event.modifierFlags.contains(.shift),
                    vertical: false
                )
                return nil
            case 36, 76:
                guard store.tableEditorBridge.snapshot()?.hadMarkedText != true else {
                    return event
                }
                store.moveTableFocus(forward: true, vertical: true)
                return nil
            case 53:
                store.finishTableEditing()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

private struct MarkdownTableCellTextField: NSViewRepresentable {
    let value: String
    let cell: MarkdownTableCell
    let isFocused: Bool
    let font: NSFont
    let textColor: NSColor
    let alignment: NSTextAlignment
    let findHighlights: [MarkdownTableFindHighlight]
    let accessibilityIdentifier: String
    let lifecycleBridge: MarkdownTableEditorBridge
    let onChange: (String) -> Void
    let onFocus: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> MarkdownTableTextField {
        let field = MarkdownTableTextField(frame: .zero)
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.onWindowAttached = { [weak coordinator = context.coordinator] in
            coordinator?.requestFocusIfNeeded()
        }
        context.coordinator.field = field
        update(field, coordinator: context.coordinator)
        return field
    }

    func updateNSView(_ field: MarkdownTableTextField, context: Context) {
        context.coordinator.parent = self
        update(field, coordinator: context.coordinator)
    }

    static func dismantleNSView(
        _ field: MarkdownTableTextField,
        coordinator: Coordinator
    ) {
        coordinator.parent.lifecycleBridge.deactivate(field: field)
        field.delegate = nil
        field.onWindowAttached = nil
        coordinator.field = nil
    }

    private func update(_ field: MarkdownTableTextField, coordinator: Coordinator) {
        let shouldRequestFocus = coordinator.focusRequestState.update(
            isSelected: isFocused
        )
        field.font = font
        field.textColor = textColor
        field.alignment = alignment
        field.setAccessibilityIdentifier(accessibilityIdentifier)
        if field.currentEditor() == nil, field.stringValue != value {
            field.stringValue = value
        }
        if let editor = field.currentEditor() as? NSTextView {
            MarkdownTableFindFormatter.applyTemporaryHighlights(
                findHighlights,
                to: editor
            )
        } else {
            let attributed = MarkdownTableFindFormatter.attributedValue(
                value,
                font: font,
                textColor: textColor,
                highlights: findHighlights
            )
            if !field.attributedStringValue.isEqual(to: attributed) {
                field.attributedStringValue = attributed
            }
        }
        if isFocused {
            lifecycleBridge.activate(
                field: field,
                cell: cell,
                onValue: onChange
            )
            if shouldRequestFocus { coordinator.requestFocusIfNeeded() }
        } else {
            lifecycleBridge.deactivate(field: field)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: MarkdownTableCellTextField
        var focusRequestState = MarkdownTableCellFocusRequestState()
        weak var field: MarkdownTableTextField?

        init(parent: MarkdownTableCellTextField) {
            self.parent = parent
        }

        func requestFocusIfNeeded() {
            guard AppEnv.allowsAutomaticFocusRequests,
                  parent.isFocused,
                  let field,
                  let window = field.window,
                  field.currentEditor() == nil else { return }
            DispatchQueue.main.async { [weak self, weak field, weak window] in
                guard let self, let field, let window,
                      self.parent.isFocused,
                      field.window === window,
                      field.currentEditor() == nil else { return }
                window.makeFirstResponder(field)
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field else { return }
            parent.lifecycleBridge.activate(
                field: field,
                cell: parent.cell,
                onValue: parent.onChange
            )
            parent.onFocus()
            if let editor = field.currentEditor() as? NSTextView {
                MarkdownTableFindFormatter.applyTemporaryHighlights(
                    parent.findHighlights,
                    to: editor
                )
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field,
                  let snapshot = parent.lifecycleBridge.snapshot(),
                  snapshot.cell == parent.cell,
                  !snapshot.hadMarkedText else { return }
            if field.stringValue != snapshot.value {
                field.stringValue = snapshot.value
            }
            parent.onChange(snapshot.value)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field else { return }
            parent.lifecycleBridge.deactivate(field: field)
        }
    }
}

private final class MarkdownTableTextField: NSTextField {
    var onWindowAttached: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onWindowAttached?() }
    }
}

private struct GridToolbarButtonStyle: ButtonStyle {
    let muted: Bool
    let danger: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11))
            .foregroundColor(
                danger
                    ? Color(hex: 0xFF9A8F)
                    : (muted ? Color(hex: 0xD0D0D5) : .white)
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(configuration.isPressed ? Color.white.opacity(0.14) : .clear)
            )
    }
}
