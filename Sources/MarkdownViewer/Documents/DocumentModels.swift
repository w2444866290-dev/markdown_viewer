import SwiftUI
import UniformTypeIdentifiers

// MARK: - Models

struct FileNode: Identifiable {
    let url: URL
    let name: String
    var isDirectory: Bool
    var children: [FileNode] = []

    /// Stable identity keeps expansion, hover, and keyboard state attached to the
    /// same filesystem entry when the tree is rebuilt.
    var id: String { url.standardizedFileURL.path }
}

struct DocumentTab: Identifiable, Codable {
    let id: UUID
    var url: URL?
    var name: String
    var text: String
    var isDirty: Bool
    /// Whether the document renders as live Markdown. Derived from the file
    /// extension: `.md`/`.markdown` → true; untitled/new docs (url == nil) → true;
    /// everything else (e.g. .yaml/.json) → false, shown as plain source.
    var isMarkdown: Bool = true
    /// Persisted lossless block model for Markdown-compatible tabs.
    /// Legacy sessions without this field are migrated from `text` during decode.
    var markdownDocument: MarkdownDocument?
    /// Persisted vertical scroll offset (document-space y of the viewport top) so a
    /// restored tab reopens where it was left. Kept in sync with the live NSTextView
    /// only at discrete reconcile points (never per scroll frame) — see
    /// DocumentManager.reconcileActiveText / snapshotSession.
    var scrollY: CGFloat = 0
    /// UTF-16 selection used by the AppKit plain-source editor.
    /// The range is clamped against the live string when the tab mounts.
    var selectionLocation: Int = 0
    var selectionLength: Int = 0

    /// Memberwise init with a defaulted `id` (so decode can supply the persisted id
    /// while the app's own creators — openTab/newDocument — get a fresh one).
    init(id: UUID = UUID(), url: URL?, name: String, text: String,
         isDirty: Bool, isMarkdown: Bool = true, scrollY: CGFloat = 0,
         selectionLocation: Int = 0, selectionLength: Int = 0,
         markdownDocument: MarkdownDocument? = nil) {
        self.id = id
        self.url = url
        self.name = name
        self.text = text
        self.isDirty = isDirty
        self.isMarkdown = url.map { DocumentFormat(url: $0).isMarkdownRendered }
            ?? isMarkdown
        self.scrollY = scrollY
        self.selectionLocation = max(0, selectionLocation)
        self.selectionLength = max(0, selectionLength)
        self.markdownDocument = self.isMarkdown
            ? Self.consistentMarkdownDocument(markdownDocument, source: text)
            : nil
    }

    /// Explicit keys: `id` is persisted (it is otherwise a fresh-per-instance UUID),
    /// and `url` is stored as an optional *path string* rather than a URL container.
    enum CodingKeys: String, CodingKey {
        case id, url, name, text, isDirty, isMarkdown, scrollY
        case selectionLocation, selectionLength, markdownDocument
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        // Stored as a plain filesystem path (see encode); nil = untitled/new doc.
        if let persistedURL = try c.decodeIfPresent(String.self, forKey: .url) {
            url = Self.fileURL(fromPersistedValue: persistedURL)
        } else {
            url = nil
        }
        name = try c.decode(String.self, forKey: .name)
        text = try c.decode(String.self, forKey: .text)
        isDirty = try c.decode(Bool.self, forKey: .isDirty)
        let persistedMarkdown = try c.decodeIfPresent(Bool.self, forKey: .isMarkdown)
        isMarkdown = url.map { DocumentFormat(url: $0).isMarkdownRendered }
            ?? persistedMarkdown
            ?? true
        scrollY = try c.decodeIfPresent(CGFloat.self, forKey: .scrollY) ?? 0
        selectionLocation = max(
            0,
            try c.decodeIfPresent(Int.self, forKey: .selectionLocation) ?? 0
        )
        selectionLength = max(
            0,
            try c.decodeIfPresent(Int.self, forKey: .selectionLength) ?? 0
        )
        let persistedDocument = try c.decodeIfPresent(
            MarkdownDocument.self,
            forKey: .markdownDocument
        )
        markdownDocument = isMarkdown
            ? Self.consistentMarkdownDocument(persistedDocument, source: text)
            : nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(url?.path, forKey: .url)
        try c.encode(name, forKey: .name)
        try c.encode(text, forKey: .text)
        try c.encode(isDirty, forKey: .isDirty)
        try c.encode(isMarkdown, forKey: .isMarkdown)
        try c.encode(scrollY, forKey: .scrollY)
        try c.encode(selectionLocation, forKey: .selectionLocation)
        try c.encode(selectionLength, forKey: .selectionLength)
        try c.encodeIfPresent(markdownDocument, forKey: .markdownDocument)
    }

    var selectionRange: NSRange {
        NSRange(location: selectionLocation, length: selectionLength)
    }

    /// Classify a file URL as Markdown. `nil` (untitled/new) is treated as Markdown.
    static func isMarkdownExtension(of url: URL?) -> Bool {
        DocumentFormat(url: url).isMarkdownRendered
    }

    private static func consistentMarkdownDocument(
        _ document: MarkdownDocument?,
        source: String
    ) -> MarkdownDocument {
        guard let document, document.source == source else {
            return MarkdownDocument(source: source)
        }
        return document
    }

    private static func fileURL(fromPersistedValue value: String) -> URL {
        if let parsed = URL(string: value), parsed.isFileURL {
            return parsed
        }
        return URL(fileURLWithPath: value)
    }
}
