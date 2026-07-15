import Foundation

/// Pure sidebar filtering and path presentation rules shared by the view and
/// deterministic tests.
enum SidebarFilterPolicy {
    static func normalizedQuery(_ rawQuery: String) -> String {
        rawQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func isFiltering(_ rawQuery: String) -> Bool {
        !normalizedQuery(rawQuery).isEmpty
    }

    /// Returns top-level browse nodes for an empty query and a flat, depth-first
    /// list of matching files for a nonempty query.
    static func visibleNodes(
        in nodes: [FileNode],
        query rawQuery: String,
        workspaceRoot: URL?
    ) -> [FileNode] {
        let query = normalizedQuery(rawQuery)
        guard !query.isEmpty else { return nodes }
        return flattenFiles(nodes).filter { node in
            let path = displayRelativePath(
                for: node,
                workspaceRoot: workspaceRoot
            ) ?? node.name
            return node.name.lowercased().contains(query)
                || path.lowercased().contains(query)
        }
    }

    /// Mirrors the prototype's filter-result path: nested files use their full
    /// workspace-relative path and root files retain the leading `./` marker.
    static func displayRelativePath(
        for node: FileNode,
        workspaceRoot: URL?
    ) -> String? {
        guard let relativePath = relativePath(
            for: node.url,
            workspaceRoot: workspaceRoot
        ) else {
            return nil
        }
        return relativePath.contains("/") ? relativePath : "./\(relativePath)"
    }

    private static func relativePath(
        for url: URL,
        workspaceRoot: URL?
    ) -> String? {
        guard let workspaceRoot else { return nil }
        let rootComponents = workspaceRoot.standardizedFileURL.pathComponents
        let fileComponents = url.standardizedFileURL.pathComponents
        guard fileComponents.count > rootComponents.count,
              Array(fileComponents.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }
        return fileComponents
            .suffix(from: rootComponents.count)
            .joined(separator: "/")
    }

    private static func flattenFiles(_ nodes: [FileNode]) -> [FileNode] {
        nodes.flatMap { node in
            node.isDirectory ? flattenFiles(node.children) : [node]
        }
    }
}
