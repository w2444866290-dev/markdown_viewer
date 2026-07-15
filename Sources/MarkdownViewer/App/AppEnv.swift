import AppKit
import Foundation

enum VisualTestLaunchState: String, CaseIterable, Equatable, Sendable {
    case defaultState = "default"
    case palette
    case find
    case preview
    case sidebarHidden = "sidebar-hidden"
    case sourceEditor = "source-editor"
    case tableEditor = "table-editor"
}

/// Parsed launch options with an explicit build-mode gate.
///
/// Visual-test arguments are inert in release builds.
/// A Debug visual-test launch receives its own Application Support, session,
/// temporary, and crash-log directories under one disposable profile root.
struct LaunchConfiguration: Equatable {
    let isDebugBuild: Bool
    let debugDiagnosticsEnabled: Bool
    let visualTestEnabled: Bool
    let visualTestRestoresSession: Bool
    let visualTestForegroundOnLaunch: Bool
    let diagnosticsVisible: Bool
    let profileRoot: URL?
    let visualTestLaunchToken: UUID?
    let fixtureName: String
    let windowSize: CGSize
    let initialScrollY: CGFloat
    let visualTestState: VisualTestLaunchState?

    /// Passive visual launches must never take the user's keyboard focus.
    /// Ordinary app launches and the explicitly bounded foreground E2E tier keep
    /// the production autofocus behavior.
    var allowsAutomaticFocusRequests: Bool {
        !visualTestEnabled || visualTestForegroundOnLaunch
    }

    static func parse(
        arguments: [String],
        environment: [String: String],
        isDebugBuild: Bool,
        defaultTemporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> LaunchConfiguration {
        let visualRequested = arguments.contains("--visual-test")
        let visualTestEnabled = isDebugBuild && visualRequested
        let visualTestRestoresSession = visualTestEnabled
            && arguments.contains("--visual-test-restore-session")
        let visualTestForegroundOnLaunch = visualTestEnabled
            && arguments.contains("--visual-test-foreground")
        let debugRequested = arguments.contains("--debug") || environment["MV_DEBUG"] == "1"
        let debugDiagnosticsEnabled = isDebugBuild && (debugRequested || visualTestEnabled)
        let diagnosticsVisible = debugDiagnosticsEnabled
            && !arguments.contains("--visual-test-hide-hud")

        let profileArgument = value(for: "--visual-test-root", in: arguments)
            ?? environment["MV_VISUAL_TEST_ROOT"]
        let profileRoot: URL?
        if visualTestEnabled {
            let path = profileArgument
                ?? defaultTemporaryDirectory
                    .appendingPathComponent("MarkdownViewerVisualTest", isDirectory: true)
                    .path
            profileRoot = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        } else {
            profileRoot = nil
        }
        let visualTestLaunchToken = visualTestEnabled
            ? value(for: "--visual-test-launch-token", in: arguments).flatMap(UUID.init(uuidString:))
            : nil

        let fixtureName = value(for: "--visual-test-document", in: arguments)
            ?? "格式示例.md"
        let windowSize = parseSize(value(for: "--visual-test-size", in: arguments))
            ?? CGSize(width: 1_180, height: 760)
        let initialScrollY = max(
            0,
            CGFloat(Double(value(for: "--visual-test-scroll", in: arguments) ?? "") ?? 0)
        )
        let visualTestState: VisualTestLaunchState?
        if visualTestEnabled {
            visualTestState = value(for: "--visual-test-state", in: arguments)
                .flatMap(VisualTestLaunchState.init(rawValue:))
                ?? .defaultState
        } else {
            // The state flag must remain entirely inert outside an explicitly
            // enabled Debug visual-test launch.
            visualTestState = nil
        }

        return LaunchConfiguration(
            isDebugBuild: isDebugBuild,
            debugDiagnosticsEnabled: debugDiagnosticsEnabled,
            visualTestEnabled: visualTestEnabled,
            visualTestRestoresSession: visualTestRestoresSession,
            visualTestForegroundOnLaunch: visualTestForegroundOnLaunch,
            diagnosticsVisible: diagnosticsVisible,
            profileRoot: profileRoot,
            visualTestLaunchToken: visualTestLaunchToken,
            fixtureName: fixtureName,
            windowSize: windowSize,
            initialScrollY: initialScrollY,
            visualTestState: visualTestState
        )
    }

    var applicationSupportDirectory: URL {
        if let profileRoot {
            return profileRoot
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("MarkdownViewer", isDirectory: true)
        }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("MarkdownViewer", isDirectory: true)
    }

    var sessionFileURL: URL {
        applicationSupportDirectory.appendingPathComponent("session.json")
    }

    var temporaryDirectory: URL {
        profileRoot?.appendingPathComponent("Temporary", isDirectory: true)
            ?? FileManager.default.temporaryDirectory
    }

    var crashLogDirectory: URL {
        if let profileRoot {
            return profileRoot
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("crash", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/MarkdownViewer/crash", isDirectory: true)
    }

    var diagnosticStateFileURL: URL? {
        guard debugDiagnosticsEnabled, let profileRoot else { return nil }
        return profileRoot
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    var visualTestActivationNotificationName: Notification.Name? {
        guard visualTestEnabled, let visualTestLaunchToken else { return nil }
        return Notification.Name(
            "local.codex.markdownviewer.visual-test.activate."
                + visualTestLaunchToken.uuidString
        )
    }

    func consumesVisualTestBootstrapURL(_ url: URL) -> Bool {
        guard visualTestEnabled,
              url.scheme?.lowercased() == "markdownviewer-debug-bootstrap",
              url.host?.lowercased() == "launch",
              url.query == nil,
              url.fragment == nil,
              let expectedToken = visualTestLaunchToken else {
            return false
        }
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard pathComponents.count == 1,
              let receivedToken = UUID(uuidString: pathComponents[0]) else {
            return false
        }
        return receivedToken == expectedToken
    }

    private static func value(for flag: String, in arguments: [String]) -> String? {
        if let inline = arguments.first(where: { $0.hasPrefix(flag + "=") }) {
            return String(inline.dropFirst(flag.count + 1))
        }
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func parseSize(_ value: String?) -> CGSize? {
        guard let value else { return nil }
        let pieces = value.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              let width = Double(pieces[0]),
              let height = Double(pieces[1]),
              width >= 860,
              height >= 560 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}

enum AutomaticFocusPolicy {
    static func allows(configured: Bool, applicationIsActive: Bool) -> Bool {
        configured || applicationIsActive
    }
}

enum AppEnv {
    static let configuration = LaunchConfiguration.parse(
        arguments: ProcessInfo.processInfo.arguments,
        environment: ProcessInfo.processInfo.environment,
        isDebugBuild: debugBuild
    )

    static let debug = configuration.debugDiagnosticsEnabled
    static let diagnosticsVisible = configuration.diagnosticsVisible
    static let visualTest = configuration.visualTestEnabled
    static let visualTestRestoresSession = configuration.visualTestRestoresSession
    static let visualTestForegroundOnLaunch = configuration.visualTestForegroundOnLaunch
    /// A background visual launch suppresses autofocus while it remains
    /// inactive. Requests created after a bounded foreground driver activates
    /// that process use the production focus behavior.
    static var allowsAutomaticFocusRequests: Bool {
        AutomaticFocusPolicy.allows(
            configured: configuration.allowsAutomaticFocusRequests,
            applicationIsActive: NSApp.isActive
        )
    }
    static let visualTestFixtureName = configuration.fixtureName
    static let visualTestWindowSize = configuration.windowSize
    static let visualTestInitialScrollY = configuration.initialScrollY
    static let visualTestLaunchState = configuration.visualTestState
    static let visualTestActivationNotificationName =
        configuration.visualTestActivationNotificationName
    static func consumesVisualTestBootstrapURL(_ url: URL) -> Bool {
        configuration.consumesVisualTestBootstrapURL(url)
    }
    static let sessionFileURL = releaseSmokeRoot?
        .appendingPathComponent("Application Support/MarkdownViewer/session.json")
        ?? configuration.sessionFileURL
    static let temporaryDirectory = releaseSmokeRoot?
        .appendingPathComponent("Temporary", isDirectory: true)
        ?? configuration.temporaryDirectory
    static let crashLogDirectory = releaseSmokeRoot?
        .appendingPathComponent("Logs/crash", isDirectory: true)
        ?? configuration.crashLogDirectory
    static let diagnosticStateFileURL = configuration.diagnosticStateFileURL

    /// A copied and re-identified bundle can opt into a disposable path for the
    /// release smoke. The production bundle identifier can never enter this branch.
    private static let releaseSmokeRoot: URL? = {
        #if DEBUG
        return nil
        #else
        guard Bundle.main.bundleIdentifier == "local.codex.markdownviewer.release-smoke" else {
            return nil
        }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--release-smoke-root"),
              arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            .standardizedFileURL
        #endif
    }()

    private static var debugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
