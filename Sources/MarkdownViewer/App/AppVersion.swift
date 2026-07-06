import Foundation

// MARK: - Build version label
//
// Surfaces which build is running so the user can verify at a glance that they
// relaunched the latest binary. The marketing version (CFBundleShortVersionString)
// is fixed; the build value (CFBundleVersion) is the git short SHA injected by
// scripts/build.sh at package time, so it changes every build.
//
// Running unpackaged (e.g. `swift run`) there is no Info.plist with these keys,
// so we fall back to a stable dev string instead of showing a blank/odd label.
enum AppVersion {
    /// e.g. "v1.0.0 (a1b2c3d)" for a packaged build, "v1.0.0 (dev)" unpackaged.
    static let label: String = {
        let bundle = Bundle.main
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        let shortVersion = (short?.isEmpty == false) ? short! : "1.0.0"
        let buildVersion = (build?.isEmpty == false) ? build! : "dev"
        return "v\(shortVersion) (\(buildVersion))"
    }()
}
