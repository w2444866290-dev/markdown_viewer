import SwiftUI
import UniformTypeIdentifiers

// MARK: - Models

struct FileNode: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    var isDirectory: Bool
    var children: [FileNode] = []
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
    /// Persisted vertical scroll offset (document-space y of the viewport top) so a
    /// restored tab reopens where it was left. Kept in sync with the live NSTextView
    /// only at discrete reconcile points (never per scroll frame) — see
    /// DocumentManager.reconcileActiveText / snapshotSession.
    var scrollY: CGFloat = 0

    /// Memberwise init with a defaulted `id` (so decode can supply the persisted id
    /// while the app's own creators — openTab/newDocument — get a fresh one).
    init(id: UUID = UUID(), url: URL?, name: String, text: String,
         isDirty: Bool, isMarkdown: Bool = true, scrollY: CGFloat = 0) {
        self.id = id
        self.url = url
        self.name = name
        self.text = text
        self.isDirty = isDirty
        self.isMarkdown = isMarkdown
        self.scrollY = scrollY
    }

    /// Explicit keys: `id` is persisted (it is otherwise a fresh-per-instance UUID),
    /// and `url` is stored as an optional *path string* rather than a URL container.
    enum CodingKeys: String, CodingKey {
        case id, url, name, text, isDirty, isMarkdown, scrollY
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        // Stored as a plain filesystem path (see encode); nil = untitled/new doc.
        if let path = try c.decodeIfPresent(String.self, forKey: .url) {
            url = URL(fileURLWithPath: path)
        } else {
            url = nil
        }
        name = try c.decode(String.self, forKey: .name)
        text = try c.decode(String.self, forKey: .text)
        isDirty = try c.decode(Bool.self, forKey: .isDirty)
        isMarkdown = try c.decodeIfPresent(Bool.self, forKey: .isMarkdown) ?? true
        scrollY = try c.decodeIfPresent(CGFloat.self, forKey: .scrollY) ?? 0
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
    }

    /// Classify a file URL as Markdown. `nil` (untitled/new) is treated as Markdown.
    static func isMarkdownExtension(of url: URL?) -> Bool {
        guard let url else { return true }
        return ["md", "markdown"].contains(url.pathExtension.lowercased())
    }
}
