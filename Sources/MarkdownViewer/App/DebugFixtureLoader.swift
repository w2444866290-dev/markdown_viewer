import Foundation

enum DebugFixtureLoader {
    enum LoaderError: Error, Equatable {
        case unavailableInRelease
        case invalidName
        case missingFixture(String)
    }

    static func load(named name: String, bundle: Bundle = .main) throws -> String {
        #if DEBUG
        let nameURL = URL(fileURLWithPath: name)
        let fileName = nameURL.deletingPathExtension().lastPathComponent
        let fileExtension = nameURL.pathExtension
        guard !fileName.isEmpty, !fileExtension.isEmpty else {
            throw LoaderError.invalidName
        }
        guard let url = bundle.url(
            forResource: fileName,
            withExtension: fileExtension,
            subdirectory: "DebugFixtures"
        ) else {
            throw LoaderError.missingFixture(name)
        }
        return try String(contentsOf: url, encoding: .utf8)
        #else
        throw LoaderError.unavailableInRelease
        #endif
    }

    /// Builds the prototype's deterministic sidebar tree inside the disposable
    /// visual-test profile. No path outside the isolated profile is touched.
    static func prepareWorkspace(fixtureName: String, fixtureText: String) throws -> URL {
        #if DEBUG
        guard AppEnv.visualTest else { throw LoaderError.unavailableInRelease }
        let workspace = AppEnv.temporaryDirectory
            .appendingPathComponent("Workspace", isDirectory: true)
        let docs = workspace.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: docs,
            withIntermediateDirectories: true
        )
        let files: [(URL, String)] = [
            (docs.appendingPathComponent("config.yaml"), "model: gpt-4o\ntemperature: 0.2\n"),
            (docs.appendingPathComponent(fixtureName), fixtureText),
            (workspace.appendingPathComponent("README.md"), "# Markdown Editor\n"),
            (workspace.appendingPathComponent("更新日志.md"), "# 更新日志\n"),
        ]
        for (url, text) in files {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return workspace
        #else
        throw LoaderError.unavailableInRelease
        #endif
    }
}
