import Foundation

/// A persisted snapshot of "where the user left off": the open tabs (including
/// unsaved/dirty content), the active tab, the body font index, the sidebar
/// geometry, the opened folder (to rebuild the sidebar tree), and — inside each
/// `DocumentTab` — its scroll position. Serialized as a single JSON file.
struct Session: Codable {
    var tabs: [DocumentTab]
    var activeTabID: UUID?
    var fontIndex: Int
    var sidebarWidth: CGFloat
    var sidebarOpen: Bool
    var directoryPath: String?
}

/// On-disk persistence for `Session`, stored at
/// `~/Library/Application Support/MarkdownViewer/session.json`.
///
/// All I/O is best-effort: a missing/corrupt file yields `nil` on load (→ the
/// caller falls back to a single blank untitled doc, exactly like first run), and
/// any encode/write error on save is logged and swallowed — persistence must never
/// crash the app.
enum SessionStore {
    /// `~/Library/Application Support/MarkdownViewer/session.json`.
    private static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("MarkdownViewer", isDirectory: true)
            .appendingPathComponent("session.json")
    }

    /// Decode the saved session, or `nil` if the file is missing or unreadable/corrupt.
    static func load() -> Session? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try JSONDecoder().decode(Session.self, from: data)
        } catch {
            MVLog.warn("session load failed (ignored): \(error)", category: "session")
            return nil
        }
    }

    /// Encode and write the session ATOMICALLY, creating the directory if needed.
    /// Best-effort: any I/O or encoding error is logged and swallowed.
    static func save(_ session: Session) {
        let url = fileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(session)
            try data.write(to: url, options: .atomic)
        } catch {
            MVLog.warn("session save failed (ignored): \(error)", category: "session")
        }
    }
}
