import Foundation

// MARK: - Build version label
//
// Surfaces which build is running so the user can verify at a glance that they
// relaunched the latest binary. The marketing version (CFBundleShortVersionString)
// is fixed; the build value (CFBundleVersion) is the git short SHA injected by
// scripts/build.sh at package time, so it changes every build.
//
// Running unpackaged (e.g. `swift run`) there is no Info.plist with these keys,
// so the marketing version is read from the repo-root VERSION file (the same
// single source scripts/build.sh injects) and the build value falls back to "dev".
enum AppVersion {
    /// "v<VERSION> (<sha>)" packaged, "v<VERSION> (dev)" unpackaged.
    static let label: String = {
        let bundle = Bundle.main
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        let shortVersion = (short?.isEmpty == false) ? short! : (unpackagedVersion() ?? "dev")
        let buildVersion = (build?.isEmpty == false) ? build! : "dev"
        return "v\(shortVersion) (\(buildVersion))"
    }()

    /// Marketing version read from the repo-root `VERSION` file when running
    /// unpackaged (`swift run`), located relative to this source file. Returns nil
    /// if it cannot be read or is blank.
    private static func unpackagedVersion() -> String? {
        // .../Sources/MarkdownViewer/App/AppVersion.swift -> repo root is 4 levels up.
        let versionURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // App
            .deletingLastPathComponent()   // MarkdownViewer
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("VERSION")
        guard let text = try? String(contentsOf: versionURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
