import Foundation
import UniformTypeIdentifiers

/// A file format's product behavior, independent of how the document was opened.
enum DocumentFormat: Equatable, Sendable {
    case markdown
    case plainSource
    case unsupported

    /// Extensions that use the rendered Markdown document experience.
    static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdx",
    ]

    /// Text formats that remain editable but render as unstyled source.
    ///
    /// `mdown` and `mkd` intentionally preserve their existing source-mode behavior.
    static let plainSourceExtensions: Set<String> = [
        "mdown", "mkd",
        "txt", "text",
        "yaml", "yml", "json", "toml",
        "swift", "sh", "py", "js", "ts",
        "html", "css", "xml",
        "rb", "go", "rs", "java", "kt",
    ]

    static let openableExtensions = markdownExtensions.union(plainSourceExtensions)

    /// Deliberately narrower drag-and-drop surface from the product definition.
    static let dropExtensions: Set<String> = ["md", "markdown", "txt", "mdx"]

    /// Exact filename-extension allowlist for file panels and drag-and-drop entry points.
    static let openPanelFilenameExtensions = openableExtensions

    /// Available UTTypes for the exact open-panel extension allowlist.
    ///
    /// Some extensions may not have a registered UTType on every supported macOS
    /// version, so unavailable values are omitted instead of force-unwrapped.
    static let openPanelContentTypes: [UTType] = {
        var identifiers = Set<String>()
        return openPanelFilenameExtensions.sorted().compactMap { filenameExtension in
            guard let type = UTType(filenameExtension: filenameExtension),
                  identifiers.insert(type.identifier).inserted else {
                return nil
            }
            return type
        }
    }()

    /// Untitled documents have no URL and use the Markdown editing experience.
    init(url: URL?) {
        guard let url else {
            self = .markdown
            return
        }
        self.init(filenameExtension: url.pathExtension)
    }

    /// Classifies a filename extension after normalizing case, whitespace, and dots.
    init(filenameExtension: String) {
        var normalized = filenameExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        while normalized.first == "." {
            normalized.removeFirst()
        }

        if Self.markdownExtensions.contains(normalized) {
            self = .markdown
        } else if Self.plainSourceExtensions.contains(normalized) {
            self = .plainSource
        } else {
            self = .unsupported
        }
    }

    var isOpenable: Bool {
        self != .unsupported
    }

    var isMarkdownRendered: Bool {
        self == .markdown
    }

    var supportsPreview: Bool {
        self == .markdown
    }
}
