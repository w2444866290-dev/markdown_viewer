import Foundation
import Testing
@testable import MarkdownViewer

@Suite
struct SidebarFilterPolicyTests {
    private let workspace = URL(
        fileURLWithPath: "/tmp/MarkdownViewer/Workspace",
        isDirectory: true
    )

    @Test("empty and whitespace-only queries retain hierarchical browse mode")
    func emptyQueryRetainsBrowseMode() {
        let tree = fixtureTree()

        #expect(SidebarFilterPolicy.visibleNodes(
            in: tree,
            query: "",
            workspaceRoot: workspace
        ).map(\.name) == ["docs", "README.md", "更新日志.md"])
        #expect(SidebarFilterPolicy.visibleNodes(
            in: tree,
            query: " \n\t ",
            workspaceRoot: workspace
        ).map(\.name) == ["docs", "README.md", "更新日志.md"])
        #expect(!SidebarFilterPolicy.isFiltering(" \n\t "))
    }

    @Test("filter matches names and full relative paths in stable depth-first order")
    func nameAndPathMatching() {
        let tree = fixtureTree()

        #expect(SidebarFilterPolicy.visibleNodes(
            in: tree,
            query: "格式",
            workspaceRoot: workspace
        ).map(\.name) == ["格式示例.md"])
        #expect(SidebarFilterPolicy.visibleNodes(
            in: tree,
            query: " DOCS/CONFIG ",
            workspaceRoot: workspace
        ).map(\.name) == ["config.yaml"])
        #expect(SidebarFilterPolicy.visibleNodes(
            in: tree,
            query: "./readme",
            workspaceRoot: workspace
        ).map(\.name) == ["README.md"])
        #expect(SidebarFilterPolicy.visibleNodes(
            in: tree,
            query: ".md",
            workspaceRoot: workspace
        ).map(\.name) == ["格式示例.md", "README.md", "更新日志.md"])
    }

    @Test("filter results expose the prototype's complete relative path")
    func displayedRelativePaths() {
        let tree = fixtureTree()
        let config = tree[0].children[0]
        let readme = tree[1]

        #expect(SidebarFilterPolicy.displayRelativePath(
            for: config,
            workspaceRoot: workspace
        ) == "docs/config.yaml")
        #expect(SidebarFilterPolicy.displayRelativePath(
            for: readme,
            workspaceRoot: workspace
        ) == "./README.md")
    }

    private func fixtureTree() -> [FileNode] {
        let docs = workspace.appendingPathComponent("docs", isDirectory: true)
        return [
            FileNode(
                url: docs,
                name: "docs",
                isDirectory: true,
                children: [
                    FileNode(
                        url: docs.appendingPathComponent("config.yaml"),
                        name: "config.yaml",
                        isDirectory: false
                    ),
                    FileNode(
                        url: docs.appendingPathComponent("格式示例.md"),
                        name: "格式示例.md",
                        isDirectory: false
                    ),
                ]
            ),
            FileNode(
                url: workspace.appendingPathComponent("README.md"),
                name: "README.md",
                isDirectory: false
            ),
            FileNode(
                url: workspace.appendingPathComponent("更新日志.md"),
                name: "更新日志.md",
                isDirectory: false
            ),
        ]
    }
}
