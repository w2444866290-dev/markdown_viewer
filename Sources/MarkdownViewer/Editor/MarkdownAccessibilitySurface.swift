import Foundation

/// Stable accessibility names for rendered Markdown surfaces.
///
/// Block UUIDs survive local edits, but they are intentionally random between
/// fresh fixture loads. Debug diagnostics already use document-order indexes,
/// so real-App automation uses the same index as its stable lookup key.
enum MarkdownAccessibilitySurface {
    static let sidebarSurface = "sidebar-surface"
    static let sidebarFilterEmpty = "sidebar-filter-empty"

    static func sidebarNode(
        url: URL,
        workspaceRoot: URL?,
        isDirectory: Bool
    ) -> String {
        let nodeKind = isDirectory ? "folder" : "file"
        let nodeURL = url.standardizedFileURL
        let relativePath = workspaceRoot.flatMap { root -> String? in
            let rootComponents = root.standardizedFileURL.pathComponents
            let nodeComponents = nodeURL.pathComponents
            guard nodeComponents.count > rootComponents.count,
                  Array(nodeComponents.prefix(rootComponents.count)) == rootComponents else {
                return nil
            }
            return nodeComponents
                .suffix(from: rootComponents.count)
                .joined(separator: "/")
        } ?? nodeURL.lastPathComponent
        return "sidebar-\(nodeKind)-\(valueToken(relativePath))"
    }

    static func outlineHeading(index: Int) -> String {
        "outline-heading-\(max(0, index))"
    }

    static func renderedBlock(index: Int, kind: MarkdownBlockKind) -> String {
        "document-block-\(blockToken(index))-\(kind.rawValue)"
    }

    static func sourceEditor(blockIndex: Int) -> String {
        "document-block-\(blockToken(blockIndex))-source-editor"
    }

    static func codeCard(blockIndex: Int, nestedListItem: Int? = nil) -> String {
        "document-block-\(blockToken(blockIndex))-\(nestedToken(nestedListItem))code-card"
    }

    static func codeCopy(blockIndex: Int, nestedListItem: Int? = nil) -> String {
        "document-block-\(blockToken(blockIndex))-\(nestedToken(nestedListItem))code-copy"
    }

    static func taskCheckbox(blockIndex: Int, taskIndex: Int) -> String {
        "document-block-\(blockToken(blockIndex))-task-\(max(0, taskIndex))-checkbox"
    }

    static func passiveTableCell(blockIndex: Int, row: Int, column: Int) -> String {
        let rowToken = row < 0 ? "header" : "row-\(row)"
        return "document-block-\(blockToken(blockIndex))-table-\(rowToken)-column-\(max(0, column))"
    }

    static func footnotePopover(blockIndex: Int) -> String {
        "document-block-\(blockToken(blockIndex))-footnote-popover"
    }

    static func footnoteReference(
        blockIndex: Int,
        identifier: String,
        scope: String? = nil,
        occurrence: Int = 0
    ) -> String {
        let base = "\(inlinePrefix(blockIndex: blockIndex, scope: scope))-footnote-reference-\(valueToken(identifier))"
        return occurrence > 0 ? "\(base)-occurrence-\(occurrence)" : base
    }

    static func inlineLink(blockIndex: Int, scope: String? = nil, index: Int) -> String {
        "\(inlinePrefix(blockIndex: blockIndex, scope: scope))-link-\(max(0, index))"
    }

    static func hoverURLPreview(blockIndex: Int?) -> String {
        guard let blockIndex else { return "hover-url-preview" }
        return "document-block-\(blockToken(blockIndex))-hover-url-preview"
    }

    static func blockLabel(index: Int, kind: MarkdownBlockKind) -> String {
        "第 \(max(0, index) + 1) 个\(kindLabel(kind))块"
    }

    static func tableCellLabel(row: Int, column: Int) -> String {
        if row < 0 {
            return "表头第 \(max(0, column) + 1) 列"
        }
        return "表格第 \(row + 1) 行第 \(max(0, column) + 1) 列"
    }

    private static func blockToken(_ index: Int) -> String {
        index >= 0 ? String(index) : "unknown"
    }

    private static func nestedToken(_ listItem: Int?) -> String {
        guard let listItem else { return "" }
        return "list-item-\(max(0, listItem))-"
    }

    private static func inlinePrefix(blockIndex: Int, scope: String?) -> String {
        let base = "document-block-\(blockToken(blockIndex))"
        guard let scope, !scope.isEmpty else { return base }
        return "\(base)-\(valueToken(scope))"
    }

    private static func valueToken(_ value: String) -> String {
        let encoded = value.utf8.map { byte -> String in
            if (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
                || byte == 45
                || byte == 95 {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
        return encoded.isEmpty ? "unknown" : encoded
    }

    private static func kindLabel(_ kind: MarkdownBlockKind) -> String {
        switch kind {
        case .heading: return "标题"
        case .paragraph: return "段落"
        case .quote: return "引用"
        case .list: return "列表"
        case .code: return "代码"
        case .table: return "表格"
        case .image: return "图片"
        case .horizontalRule: return "分割线"
        case .footnotes: return "脚注"
        }
    }
}
