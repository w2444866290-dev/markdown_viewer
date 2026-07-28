import AppKit
import Foundation
import Testing
@testable import MarkdownViewer

@Suite
struct AccessibilitySurfaceTests {
    @Test("render diagnostics never intercept block pointer input")
    func renderProbePassesPointerInputThrough() {
        let view = BlockRenderProbeView(
            frame: NSRect(x: 0, y: 0, width: 120, height: 80)
        )

        #expect(view.hitTest(NSPoint(x: 40, y: 30)) == nil)
    }

    @Test("window configuration never makes document content a drag surface")
    @MainActor
    func windowMovementPolicyKeepsContentInteractive() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isMovable = false
        window.isMovableByWindowBackground = true

        WindowMovementPolicy.apply(to: window)

        #expect(window.isMovable)
        #expect(!window.isMovableByWindowBackground)
    }

    @Test("bounded Debug foreground windows temporarily outrank desktop overlays")
    @MainActor
    func boundedForegroundWindowLevelIsReversible() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        VisualTestWindowLevelPolicy.prepareForBoundedForeground(window)
        #expect(window.level == .screenSaver)
        #expect(VisualTestWindowLevelPolicy.safetyTimeoutSeconds == 3.8)
        #expect(VisualTestWindowLevelPolicy.safetyTimeoutSeconds < 4)

        VisualTestWindowLevelPolicy.restoreNormal(window)
        #expect(window.level == .normal)
    }

    @Test("window configuration probe never intercepts pointer input")
    func windowConfigurationProbePassesPointerInputThrough() {
        let view = WindowConfigurationProbeView(
            frame: NSRect(x: 0, y: 0, width: 120, height: 80)
        )

        #expect(view.hitTest(NSPoint(x: 40, y: 30)) == nil)
    }

    @Test("sidebar surfaces use workspace-relative percent-encoded identifiers")
    func sidebarSurfaceIdentifiers() {
        let workspace = URL(fileURLWithPath: "/tmp/Profile/Workspace", isDirectory: true)
        let docs = workspace.appendingPathComponent("docs", isDirectory: true)
        let config = docs.appendingPathComponent("config.yaml")
        let fixture = docs.appendingPathComponent("格式示例.md")

        #expect(MarkdownAccessibilitySurface.sidebarSurface == "sidebar-surface")
        #expect(
            MarkdownAccessibilitySurface.sidebarFilterEmpty
                == "sidebar-filter-empty"
        )
        #expect(MarkdownAccessibilitySurface.sidebarNode(
            url: docs,
            workspaceRoot: workspace,
            isDirectory: true
        ) == "sidebar-folder-docs")
        #expect(MarkdownAccessibilitySurface.sidebarNode(
            url: config,
            workspaceRoot: workspace,
            isDirectory: false
        ) == "sidebar-file-docs%2Fconfig%2Eyaml")
        #expect(MarkdownAccessibilitySurface.sidebarNode(
            url: fixture,
            workspaceRoot: workspace,
            isDirectory: false
        ) == "sidebar-file-docs%2F%E6%A0%BC%E5%BC%8F%E7%A4%BA%E4%BE%8B%2Emd")
    }

    @Test("sidebar identifiers do not capture the disposable profile root")
    func sidebarIdentifiersIgnoreProfileRoot() {
        let firstRoot = URL(fileURLWithPath: "/tmp/Profile-A/Workspace", isDirectory: true)
        let secondRoot = URL(fileURLWithPath: "/tmp/Profile-B/Workspace", isDirectory: true)
        let firstNode = firstRoot.appendingPathComponent("docs/config.yaml")
        let secondNode = secondRoot.appendingPathComponent("docs/config.yaml")

        let first = MarkdownAccessibilitySurface.sidebarNode(
            url: firstNode,
            workspaceRoot: firstRoot,
            isDirectory: false
        )
        let second = MarkdownAccessibilitySurface.sidebarNode(
            url: secondNode,
            workspaceRoot: secondRoot,
            isDirectory: false
        )

        #expect(first == second)
        #expect(!first.contains("Profile-A"))
        #expect(!second.contains("Profile-B"))
    }

    @Test("rendered Markdown surfaces use diagnostic block indexes")
    func renderedSurfaceIdentifiers() {
        #expect(MarkdownAccessibilitySurface.outlineHeading(
            index: 12
        ) == "outline-heading-12")
        #expect(MarkdownAccessibilitySurface.renderedBlock(
            index: 7,
            kind: .paragraph
        ) == "document-block-7-paragraph")
        #expect(MarkdownAccessibilitySurface.sourceEditor(
            blockIndex: 7
        ) == "document-block-7-source-editor")
        #expect(MarkdownAccessibilitySurface.codeCard(
            blockIndex: 12
        ) == "document-block-12-code-card")
        #expect(MarkdownAccessibilitySurface.codeCopy(
            blockIndex: 12,
            nestedListItem: 3
        ) == "document-block-12-list-item-3-code-copy")
        #expect(MarkdownAccessibilitySurface.taskCheckbox(
            blockIndex: 4,
            taskIndex: 2
        ) == "document-block-4-task-2-checkbox")
    }

    @Test("passive table cells distinguish headers and body rows")
    func passiveTableCellIdentifiers() {
        #expect(MarkdownAccessibilitySurface.passiveTableCell(
            blockIndex: 9,
            row: -1,
            column: 1
        ) == "document-block-9-table-header-column-1")
        #expect(MarkdownAccessibilitySurface.passiveTableCell(
            blockIndex: 9,
            row: 2,
            column: 1
        ) == "document-block-9-table-row-2-column-1")
        #expect(MarkdownAccessibilitySurface.tableCellLabel(
            row: -1,
            column: 1
        ) == "表头第 2 列")
        #expect(MarkdownAccessibilitySurface.tableCellLabel(
            row: 2,
            column: 1
        ) == "表格第 3 行第 2 列")
    }

    @Test("transient feedback identifiers retain their source block")
    func transientFeedbackIdentifiers() {
        #expect(MarkdownAccessibilitySurface.footnotePopover(
            blockIndex: 5
        ) == "document-block-5-footnote-popover")
        #expect(MarkdownAccessibilitySurface.footnoteReference(
            blockIndex: 5,
            identifier: "scope"
        ) == "document-block-5-footnote-reference-scope")
        #expect(MarkdownAccessibilitySurface.footnoteReference(
            blockIndex: 5,
            identifier: "scope",
            occurrence: 1
        ) == "document-block-5-footnote-reference-scope-occurrence-1")
        #expect(MarkdownAccessibilitySurface.footnoteReference(
            blockIndex: 5,
            identifier: "范围 1"
        ) == "document-block-5-footnote-reference-%E8%8C%83%E5%9B%B4%201")
        #expect(MarkdownAccessibilitySurface.inlineLink(
            blockIndex: 5,
            index: 1
        ) == "document-block-5-link-1")
        #expect(MarkdownAccessibilitySurface.inlineLink(
            blockIndex: 5,
            scope: "table-row-2-column-1",
            index: 1
        ) == "document-block-5-table-row-2-column-1-link-1")
        #expect(MarkdownAccessibilitySurface.footnoteReference(
            blockIndex: 5,
            identifier: "scope",
            scope: "list item"
        ) == "document-block-5-list%20item-footnote-reference-scope")
        #expect(MarkdownAccessibilitySurface.hoverURLPreview(
            blockIndex: 5
        ) == "document-block-5-hover-url-preview")
        #expect(MarkdownAccessibilitySurface.hoverURLPreview(
            blockIndex: nil
        ) == "hover-url-preview")
    }

    @Test("hover URL state clears its diagnostic source atomically")
    func hoverURLState() {
        let model = HoverURLModel()

        model.publish("https://example.com", sourceBlockIndex: 6)
        #expect(model.url == "https://example.com")
        #expect(model.sourceBlockIndex == 6)

        model.clear()
        #expect(model.url.isEmpty)
        #expect(model.sourceBlockIndex == nil)
    }

    @Test("bounded foreground targets stay bound to the Debug fixture")
    func foregroundFixtureTargets() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ui/格式示例.md")
        let source = try String(contentsOf: fixtureURL, encoding: .utf8)
        let document = MarkdownDocument(source: source)

        let quote = try #require(document.blocks.first(where: {
            $0.kind == .quote
                && $0.source.hasSuffix("设计原则：读起来像一页纸，而不是一个应用。")
        }))
        let listItem = try #require(document.blocks.first(where: {
            $0.kind == .list && $0.source == "- 另一个第一层项目"
        }))
        let task = try #require(document.blocks.first(where: {
            $0.kind == .list && $0.source == "- [ ] 协同编辑"
        }))
        let code = try #require(document.blocks.first(where: {
            $0.kind == .code && $0.source == """
        ```bash
        # 安装并运行
        npx -y @dev/cli@latest --version
        ```
        """
        }))
        let tableHeading = try #require(document.blocks.first(where: {
            $0.kind == .heading && $0.source == "## 表格"
        }))
        let table = try #require(document.blocks.first(where: {
            $0.kind == .table && $0.source.contains("| ⌘B | 加粗 | 全部 |")
        }))
        let footnoteBody = try #require(document.blocks.first(where: {
            $0.kind == .paragraph && $0.source.contains("[^scope]")
        }))
        let footnotes = try #require(document.blocks.first(where: {
            $0.kind == .footnotes && $0.source.contains("[^1]:")
        }))

        #expect(quote.id != listItem.id)
        #expect(listItem.id != task.id)
        #expect(code.id != tableHeading.id)
        #expect(tableHeading.id != table.id)
        #expect(footnoteBody.id != footnotes.id)
    }
}
