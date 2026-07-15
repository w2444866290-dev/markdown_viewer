import Foundation

/// A persisted snapshot of where the user left off.
struct Session: Codable {
    static let currentSchemaVersion = 3

    private(set) var schemaVersion: Int
    var tabs: [DocumentTab]
    var activeTabID: UUID?
    var fontIndex: Int
    var sidebarWidth: CGFloat
    var sidebarOpen: Bool
    var directoryPath: String?
    var expandedFolderPaths: [String]?

    init(
        tabs: [DocumentTab],
        activeTabID: UUID?,
        fontIndex: Int,
        sidebarWidth: CGFloat,
        sidebarOpen: Bool,
        directoryPath: String?,
        expandedFolderPaths: [String]? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.tabs = tabs
        self.activeTabID = activeTabID
        self.fontIndex = fontIndex
        self.sidebarWidth = sidebarWidth
        self.sidebarOpen = sidebarOpen
        self.directoryPath = directoryPath
        self.expandedFolderPaths = expandedFolderPaths
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case tabs
        case activeTabID
        case fontIndex
        case sidebarWidth
        case sidebarOpen
        case directoryPath
        case expandedFolderPaths
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let persistedVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .schemaVersion
        ) ?? 0
        guard (0...Self.currentSchemaVersion).contains(persistedVersion) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported session schema version \(persistedVersion)"
            )
        }

        schemaVersion = Self.currentSchemaVersion
        tabs = try container.decode([DocumentTab].self, forKey: .tabs)
        activeTabID = try container.decodeIfPresent(UUID.self, forKey: .activeTabID)
        fontIndex = try container.decode(Int.self, forKey: .fontIndex)
        sidebarWidth = try container.decode(CGFloat.self, forKey: .sidebarWidth)
        sidebarOpen = try container.decode(Bool.self, forKey: .sidebarOpen)
        directoryPath = try container.decodeIfPresent(String.self, forKey: .directoryPath)
        expandedFolderPaths = try container.decodeIfPresent(
            [String].self,
            forKey: .expandedFolderPaths
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(tabs, forKey: .tabs)
        try container.encodeIfPresent(activeTabID, forKey: .activeTabID)
        try container.encode(fontIndex, forKey: .fontIndex)
        try container.encode(sidebarWidth, forKey: .sidebarWidth)
        try container.encode(sidebarOpen, forKey: .sidebarOpen)
        try container.encodeIfPresent(directoryPath, forKey: .directoryPath)
        try container.encodeIfPresent(expandedFolderPaths, forKey: .expandedFolderPaths)
    }
}

/// On-disk persistence for `Session`.
/// USER launches use `~/Library/Application Support/MarkdownViewer/session.json`.
/// Debug visual-test launches use the isolated path supplied by `AppEnv`.
///
/// All I/O is best-effort. Missing, empty, and corrupt files yield `nil`, while
/// save failures are logged and swallowed so persistence cannot crash the app.
enum SessionStore {
    static var fileURL: URL { AppEnv.sessionFileURL }

    /// Decode the saved session, or `nil` if the file is missing or unreadable/corrupt.
    static func load() -> Session? {
        load(from: fileURL)
    }

    /// URL-injected load used by migration tests and isolated Debug profiles.
    static func load(from url: URL) -> Session? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            MVLog.warn("session read failed (ignored): \(error)", category: "session")
            return nil
        }
        guard !data.isEmpty else { return nil }

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
        save(session, to: fileURL)
    }

    /// URL-injected save used by tests and isolated Debug profiles.
    @discardableResult
    static func save(_ session: Session, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(session)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            MVLog.warn("session save failed (ignored): \(error)", category: "session")
            return false
        }
    }
}
