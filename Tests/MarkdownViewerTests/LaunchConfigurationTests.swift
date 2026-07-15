import Foundation
import Testing
@testable import MarkdownViewer

@Suite("Launch configuration")
struct LaunchConfigurationTests {
    @Test
    func visualTestConsumesOnlyItsExactBootstrapURL() {
        let token = UUID(uuidString: "D8C9C10D-4ED8-4A92-9345-178B82D87416")!
        let parsed = configuration(
            arguments: [
                "MarkdownViewer",
                "--visual-test",
                "--visual-test-launch-token", token.uuidString,
            ],
            isDebugBuild: true
        )

        #expect(parsed.visualTestLaunchToken == token)
        #expect(parsed.consumesVisualTestBootstrapURL(
            URL(string: "markdownviewer-debug-bootstrap://launch/\(token.uuidString)")!
        ))
        #expect(!parsed.consumesVisualTestBootstrapURL(
            URL(string: "markdownviewer-debug-bootstrap://launch/00000000-0000-0000-0000-000000000000")!
        ))
        #expect(!parsed.consumesVisualTestBootstrapURL(
            URL(fileURLWithPath: "/tmp/fixture.md")
        ))

        let release = configuration(
            arguments: [
                "MarkdownViewer",
                "--visual-test",
                "--visual-test-launch-token", token.uuidString,
            ],
            isDebugBuild: false
        )
        #expect(release.visualTestLaunchToken == nil)
        #expect(!release.consumesVisualTestBootstrapURL(
            URL(string: "markdownviewer-debug-bootstrap://launch/\(token.uuidString)")!
        ))
    }

    @Test
    func activationNotificationRequiresAValidDebugVisualToken() {
        let token = UUID(uuidString: "D8C9C10D-4ED8-4A92-9345-178B82D87416")!
        let otherToken = UUID(uuidString: "0DC782C9-FDD4-416E-8118-623AA427FB23")!
        let enabled = configuration(
            arguments: [
                "MarkdownViewer",
                "--visual-test",
                "--visual-test-launch-token", token.uuidString,
            ],
            isDebugBuild: true
        )
        let otherEnabled = configuration(
            arguments: [
                "MarkdownViewer",
                "--visual-test",
                "--visual-test-launch-token", otherToken.uuidString,
            ],
            isDebugBuild: true
        )
        let missingToken = configuration(
            arguments: ["MarkdownViewer", "--visual-test"],
            isDebugBuild: true
        )
        let malformedToken = configuration(
            arguments: [
                "MarkdownViewer",
                "--visual-test",
                "--visual-test-launch-token", "not-a-uuid",
            ],
            isDebugBuild: true
        )
        let debugWithoutVisualTest = configuration(
            arguments: [
                "MarkdownViewer",
                "--visual-test-launch-token", token.uuidString,
            ],
            isDebugBuild: true
        )
        let release = configuration(
            arguments: [
                "MarkdownViewer",
                "--visual-test",
                "--visual-test-launch-token", token.uuidString,
            ],
            isDebugBuild: false
        )

        #expect(enabled.visualTestActivationNotificationName?.rawValue ==
            "local.codex.markdownviewer.visual-test.activate.\(token.uuidString)")
        #expect(otherEnabled.visualTestActivationNotificationName !=
            enabled.visualTestActivationNotificationName)
        #expect(missingToken.visualTestActivationNotificationName == nil)
        #expect(malformedToken.visualTestActivationNotificationName == nil)
        #expect(debugWithoutVisualTest.visualTestActivationNotificationName == nil)
        #expect(release.visualTestActivationNotificationName == nil)
    }

    @Test
    func releaseVisualFlagsCannotEnableDiagnosticsOrRedirectPaths() {
        let baseline = configuration(isDebugBuild: false)
        let requested = configuration(
            arguments: [
                "MarkdownViewer",
                "--debug",
                "--visual-test",
                "--visual-test-root", "/tmp/MarkdownViewerVisualTestRelease",
                "--visual-test-document", "other.md",
                "--visual-test-size", "1440x900",
                "--visual-test-scroll", "300",
                "--visual-test-state", "preview",
                "--visual-test-restore-session",
            ],
            environment: ["MV_DEBUG": "1", "MV_VISUAL_TEST_ROOT": "/tmp/environment-root"],
            isDebugBuild: false
        )

        #expect(!requested.debugDiagnosticsEnabled)
        #expect(!requested.visualTestEnabled)
        #expect(!requested.visualTestRestoresSession)
        #expect(!requested.visualTestForegroundOnLaunch)
        #expect(!requested.diagnosticsVisible)
        #expect(requested.visualTestState == nil)
        #expect(requested.profileRoot == nil)
        #expect(requested.applicationSupportDirectory == baseline.applicationSupportDirectory)
        #expect(requested.sessionFileURL == baseline.sessionFileURL)
        #expect(requested.temporaryDirectory == baseline.temporaryDirectory)
        #expect(requested.crashLogDirectory == baseline.crashLogDirectory)
    }

    @Test
    func visualSessionRestoreRequiresAnExplicitDebugVisualLaunch() {
        let enabled = configuration(
            arguments: [
                "MarkdownViewer",
                "--visual-test",
                "--visual-test-restore-session",
            ],
            isDebugBuild: true
        )
        let debugWithoutVisualTest = configuration(
            arguments: ["MarkdownViewer", "--visual-test-restore-session"],
            isDebugBuild: true
        )
        let release = configuration(
            arguments: [
                "MarkdownViewer",
                "--visual-test",
                "--visual-test-restore-session",
            ],
            isDebugBuild: false
        )

        #expect(enabled.visualTestRestoresSession)
        #expect(!debugWithoutVisualTest.visualTestRestoresSession)
        #expect(!release.visualTestRestoresSession)
    }

    @Test
    func debugVisualTestRedirectsEveryWritablePathUnderProfileRoot() {
        let root = URL(fileURLWithPath: "/tmp/LaunchConfigurationTests/Profile/../Isolated", isDirectory: true)
            .standardizedFileURL
        let parsed = configuration(
            arguments: ["MarkdownViewer", "--visual-test", "--visual-test-root", root.path],
            isDebugBuild: true
        )

        #expect(parsed.visualTestEnabled)
        #expect(!parsed.visualTestForegroundOnLaunch)
        #expect(parsed.debugDiagnosticsEnabled)
        #expect(parsed.profileRoot == root)
        #expect(parsed.applicationSupportDirectory == root.appendingPathComponent("Application Support/MarkdownViewer", isDirectory: true))
        #expect(parsed.sessionFileURL == root.appendingPathComponent("Application Support/MarkdownViewer/session.json"))
        #expect(parsed.temporaryDirectory == root.appendingPathComponent("Temporary", isDirectory: true))
        #expect(parsed.crashLogDirectory == root.appendingPathComponent("Logs/crash", isDirectory: true))
    }

    @Test
    func defaultUserSessionRemainsInStandardApplicationSupport() {
        let parsed = configuration(isDebugBuild: false)
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let expected = base
            .appendingPathComponent("MarkdownViewer", isDirectory: true)
            .appendingPathComponent("session.json")

        #expect(parsed.profileRoot == nil)
        #expect(parsed.sessionFileURL == expected)
    }

    @Test
    func visualTestCanHideHudWithoutDisablingDiagnostics() {
        let visible = configuration(
            arguments: ["MarkdownViewer", "--visual-test"],
            isDebugBuild: true
        )
        let hidden = configuration(
            arguments: ["MarkdownViewer", "--visual-test", "--visual-test-hide-hud"],
            isDebugBuild: true
        )

        #expect(visible.debugDiagnosticsEnabled)
        #expect(visible.diagnosticsVisible)
        #expect(hidden.debugDiagnosticsEnabled)
        #expect(hidden.visualTestEnabled)
        #expect(!hidden.diagnosticsVisible)
    }

    @Test
    func foregroundLaunchRequiresAnExplicitDebugVisualTestFlag() {
        let background = configuration(
            arguments: ["MarkdownViewer", "--visual-test"],
            isDebugBuild: true
        )
        let foreground = configuration(
            arguments: [
                "MarkdownViewer",
                "--visual-test",
                "--visual-test-foreground",
            ],
            isDebugBuild: true
        )
        let release = configuration(
            arguments: [
                "MarkdownViewer",
                "--visual-test",
                "--visual-test-foreground",
            ],
            isDebugBuild: false
        )

        #expect(!background.visualTestForegroundOnLaunch)
        #expect(!background.allowsAutomaticFocusRequests)
        #expect(foreground.visualTestForegroundOnLaunch)
        #expect(foreground.allowsAutomaticFocusRequests)
        #expect(!release.visualTestForegroundOnLaunch)
        #expect(release.allowsAutomaticFocusRequests)
    }

    @Test
    func boundedActivationAllowsSubsequentProductionAutofocusRequests() {
        #expect(!AutomaticFocusPolicy.allows(
            configured: false,
            applicationIsActive: false
        ))
        #expect(AutomaticFocusPolicy.allows(
            configured: false,
            applicationIsActive: true
        ))
        #expect(AutomaticFocusPolicy.allows(
            configured: true,
            applicationIsActive: false
        ))
    }

    @Test
    func validWindowSizesParseAndInvalidSizesFallBack() {
        let uppercase = configuration(
            arguments: ["MarkdownViewer", "--visual-test", "--visual-test-size", "1440X900"],
            isDebugBuild: true
        )
        let minimum = configuration(
            arguments: ["MarkdownViewer", "--visual-test", "--visual-test-size=860x560"],
            isDebugBuild: true
        )
        let tooSmall = configuration(
            arguments: ["MarkdownViewer", "--visual-test", "--visual-test-size", "859x560"],
            isDebugBuild: true
        )
        let malformed = configuration(
            arguments: ["MarkdownViewer", "--visual-test", "--visual-test-size", "wide"],
            isDebugBuild: true
        )

        #expect(uppercase.windowSize == CGSize(width: 1_440, height: 900))
        #expect(minimum.windowSize == CGSize(width: 860, height: 560))
        #expect(tooSmall.windowSize == CGSize(width: 1_180, height: 760))
        #expect(malformed.windowSize == CGSize(width: 1_180, height: 760))
    }

    @Test
    func visualTestDocumentUsesDeterministicDefaultAndSupportsArguments() {
        let defaulted = configuration(
            arguments: ["MarkdownViewer", "--visual-test"],
            isDebugBuild: true
        )
        let separateArgument = configuration(
            arguments: ["MarkdownViewer", "--visual-test", "--visual-test-document", "edge-cases.md"],
            isDebugBuild: true
        )
        let inlineArgument = configuration(
            arguments: ["MarkdownViewer", "--visual-test", "--visual-test-document=table.md"],
            isDebugBuild: true
        )

        #expect(defaulted.fixtureName == "格式示例.md")
        #expect(separateArgument.fixtureName == "edge-cases.md")
        #expect(inlineArgument.fixtureName == "table.md")
    }

    @Test(arguments: VisualTestLaunchState.allCases)
    func visualTestStateParsesEveryExactSupportedValue(_ state: VisualTestLaunchState) {
        let separate = configuration(
            arguments: [
                "MarkdownViewer",
                "--visual-test",
                "--visual-test-state",
                state.rawValue,
            ],
            isDebugBuild: true
        )
        let inline = configuration(
            arguments: [
                "MarkdownViewer",
                "--visual-test",
                "--visual-test-state=\(state.rawValue)",
            ],
            isDebugBuild: true
        )

        #expect(separate.visualTestState == state)
        #expect(inline.visualTestState == state)
    }

    @Test
    func visualTestStateDefaultsDeterministicallyAndIsOtherwiseInert() {
        let defaulted = configuration(
            arguments: ["MarkdownViewer", "--visual-test"],
            isDebugBuild: true
        )
        let invalid = configuration(
            arguments: [
                "MarkdownViewer",
                "--visual-test",
                "--visual-test-state",
                "PREVIEW",
            ],
            isDebugBuild: true
        )
        let debugWithoutVisualTest = configuration(
            arguments: [
                "MarkdownViewer",
                "--visual-test-state",
                "preview",
            ],
            isDebugBuild: true
        )
        let release = configuration(
            arguments: [
                "MarkdownViewer",
                "--visual-test",
                "--visual-test-state",
                "preview",
            ],
            isDebugBuild: false
        )

        #expect(defaulted.visualTestState == .defaultState)
        #expect(invalid.visualTestState == .defaultState)
        #expect(debugWithoutVisualTest.visualTestState == nil)
        #expect(release.visualTestState == nil)
    }

    @Test(arguments: VisualTestLaunchState.allCases)
    @MainActor
    func visualTestStateAppliesEachExactFixtureMapping(_ state: VisualTestLaunchState) throws {
        let sessionURL = URL(fileURLWithPath: "/tmp/LaunchConfigurationTests/\(UUID().uuidString)/session.json")
        let manager = DocumentManager(
            sessionURL: sessionURL,
            visualTestEnabled: true
        )
        let findState = FindState()
        let toaster = Toaster()
        let source = """
        # First rendered block

        Body

        | A | B |
        | --- | --- |
        | one | two |
        """
        manager.loadVisualTestDocument(name: "state.md", text: source, scrollY: 0)

        VisualTestStateApplier.apply(
            state,
            documentManager: manager,
            findState: findState,
            toaster: toaster
        )

        let tab = try #require(manager.activeTab)
        let store = manager.blockEditorStore(for: tab)
        let firstBlock = try #require(store.document.blocks.first)
        let firstTable = try #require(store.document.blocks.first(where: { $0.kind == .table }))

        #expect(manager.paletteOpen == (state == .palette))
        #expect(findState.isOpen == (state == .find))
        #expect(manager.previewMode == (state == .preview))
        #expect(manager.sidebarOpen == (state != .sidebarHidden))
        #expect(store.activeBlockID == (state == .sourceEditor ? firstBlock.id : nil))
        #expect(store.activeSelection == (
            state == .sourceEditor
                ? NSRange(
                    location: (firstBlock.source as NSString).length,
                    length: 0
                )
                : nil
        ))
        #expect(store.activeTableID == (state == .tableEditor ? firstTable.id : nil))
        #expect(store.activeTableCell == (
            state == .tableEditor
                ? .header(0)
                : nil
        ))
        #expect(toaster.visible == (state == .preview))
        #expect(toaster.message == (
            state == .preview ? "纯预览 · 点击笔重新编辑" : ""
        ))
        #expect(!toaster.hasPendingDismissal)
    }

    @Test @MainActor
    func nilVisualTestStateApplierIsACompleteNoOp() throws {
        let manager = DocumentManager(visualTestEnabled: true)
        let findState = FindState()
        let toaster = Toaster()
        manager.loadVisualTestDocument(name: "state.md", text: "# Heading", scrollY: 0)

        VisualTestStateApplier.apply(
            nil,
            documentManager: manager,
            findState: findState,
            toaster: toaster
        )

        let tab = try #require(manager.activeTab)
        let store = manager.blockEditorStore(for: tab)
        #expect(!manager.paletteOpen)
        #expect(!findState.isOpen)
        #expect(!manager.previewMode)
        #expect(manager.sidebarOpen)
        #expect(store.activeBlockID == nil)
        #expect(store.activeTableID == nil)
        #expect(!toaster.visible)
        #expect(toaster.message.isEmpty)
        #expect(!toaster.hasPendingDismissal)
    }

    @Test @MainActor
    func pinnedVisualToastDoesNotDisableTheNextAutomaticDismissal() {
        let toaster = Toaster()

        #expect(Toaster.automaticDismissDelayNanoseconds == 1_600_000_000)
        toaster.flash("视觉测试")
        #expect(toaster.visible)
        #expect(toaster.hasPendingDismissal)

        toaster.pinCurrentToastUntilNextFlash()
        #expect(toaster.visible)
        #expect(toaster.message == "视觉测试")
        #expect(!toaster.hasPendingDismissal)

        toaster.flash("普通反馈")
        #expect(toaster.visible)
        #expect(toaster.message == "普通反馈")
        #expect(toaster.hasPendingDismissal)

        toaster.dismiss()
        #expect(!toaster.visible)
        #expect(!toaster.hasPendingDismissal)
    }

    @Test
    func profileArgumentTakesPrecedenceOverEnvironmentAndSupportsDefaults() {
        let temporary = URL(fileURLWithPath: "/tmp/LaunchConfigurationTests/Temporary", isDirectory: true)
        let environmentOnly = configuration(
            arguments: ["MarkdownViewer", "--visual-test"],
            environment: ["MV_VISUAL_TEST_ROOT": "/tmp/MarkdownViewerVisualTestEnvironment"],
            isDebugBuild: true,
            defaultTemporaryDirectory: temporary
        )
        let separateArgument = configuration(
            arguments: [
                "MarkdownViewer", "--visual-test",
                "--visual-test-root", "/tmp/MarkdownViewerVisualTestArgument",
            ],
            environment: ["MV_VISUAL_TEST_ROOT": "/tmp/MarkdownViewerVisualTestEnvironment"],
            isDebugBuild: true,
            defaultTemporaryDirectory: temporary
        )
        let inlineArgument = configuration(
            arguments: [
                "MarkdownViewer", "--visual-test",
                "--visual-test-root=/tmp/MarkdownViewerVisualTestInline",
            ],
            environment: ["MV_VISUAL_TEST_ROOT": "/tmp/MarkdownViewerVisualTestEnvironment"],
            isDebugBuild: true,
            defaultTemporaryDirectory: temporary
        )
        let defaulted = configuration(
            arguments: ["MarkdownViewer", "--visual-test"],
            isDebugBuild: true,
            defaultTemporaryDirectory: temporary
        )
        let debugOnly = configuration(
            arguments: ["MarkdownViewer", "--debug"],
            environment: ["MV_VISUAL_TEST_ROOT": "/tmp/MarkdownViewerVisualTestIgnored"],
            isDebugBuild: true,
            defaultTemporaryDirectory: temporary
        )

        #expect(environmentOnly.profileRoot?.path == "/tmp/MarkdownViewerVisualTestEnvironment")
        #expect(separateArgument.profileRoot?.path == "/tmp/MarkdownViewerVisualTestArgument")
        #expect(inlineArgument.profileRoot?.path == "/tmp/MarkdownViewerVisualTestInline")
        #expect(defaulted.profileRoot == temporary.appendingPathComponent("MarkdownViewerVisualTest", isDirectory: true).standardizedFileURL)
        #expect(debugOnly.profileRoot == nil)
    }

    @Test
    func scrollOffsetParsesAndClampsToZero() {
        let positive = configuration(
            arguments: ["MarkdownViewer", "--visual-test", "--visual-test-scroll", "312.5"],
            isDebugBuild: true
        )
        let negative = configuration(
            arguments: ["MarkdownViewer", "--visual-test", "--visual-test-scroll", "-20"],
            isDebugBuild: true
        )
        let malformed = configuration(
            arguments: ["MarkdownViewer", "--visual-test", "--visual-test-scroll", "down"],
            isDebugBuild: true
        )

        #expect(positive.initialScrollY == 312.5)
        #expect(negative.initialScrollY == 0)
        #expect(malformed.initialScrollY == 0)
    }

    private func configuration(
        arguments: [String] = ["MarkdownViewer"],
        environment: [String: String] = [:],
        isDebugBuild: Bool,
        defaultTemporaryDirectory: URL = URL(fileURLWithPath: "/tmp/LaunchConfigurationTests/Default", isDirectory: true)
    ) -> LaunchConfiguration {
        LaunchConfiguration.parse(
            arguments: arguments,
            environment: environment,
            isDebugBuild: isDebugBuild,
            defaultTemporaryDirectory: defaultTemporaryDirectory
        )
    }
}
