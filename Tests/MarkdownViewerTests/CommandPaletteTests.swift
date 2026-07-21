import AppKit
import Testing
@testable import MarkdownViewer

@Suite("Command palette")
struct CommandPaletteTests {
    @Test
    func paletteUsesTheOwningWindowForEveryLaunchMode() {
        #expect(PalettePresentationPolicy.mode(
            isVisualTest: true,
            launchesForeground: false,
            hasActivated: false
        ) == .inlineMain)
        #expect(PalettePresentationPolicy.mode(
            isVisualTest: true,
            launchesForeground: false,
            hasActivated: true
        ) == .inlineMain)
    }

    @Test
    func ordinaryAndExplicitForegroundLaunchesUseTheOwningWindow() {
        #expect(PalettePresentationPolicy.mode(
            isVisualTest: false,
            launchesForeground: false,
            hasActivated: false
        ) == .inlineMain)
        #expect(PalettePresentationPolicy.mode(
            isVisualTest: true,
            launchesForeground: true,
            hasActivated: false
        ) == .inlineMain)
    }

    @Test
    func referenceContentBoxMetricsProduceFourHundredThreePointPanel() {
        #expect(PalettePresentationMetrics.listContentMaxHeight == 340)
        #expect(PalettePresentationMetrics.listOuterMaxHeight == 356)
        #expect(PalettePresentationMetrics.panelMaxHeight == 403)
        #expect(PalettePresentationMetrics.veilOpacity == 0.6)
        #expect(PalettePresentationMetrics.entranceDuration == 0.12)
        #expect(PalettePresentationMetrics.entranceOffset == 4)
    }

    @Test
    func panelWidthRetainsReferenceHorizontalInsetsWhenConstrained() {
        #expect(PalettePresentationMetrics.panelWidth(for: 1_180) == 460)
        #expect(PalettePresentationMetrics.panelWidth(for: 500) == 452)
        #expect(PalettePresentationMetrics.panelWidth(for: 48) == 0)
    }

    @Test
    func keyboardMappingCoversArrowsBothEnterKeysAndEscape() {
        #expect(PaletteKeyboard.command(forKeyCode: 125) == .moveDown)
        #expect(PaletteKeyboard.command(forKeyCode: 126) == .moveUp)
        #expect(PaletteKeyboard.command(forKeyCode: 36) == .activate)
        #expect(PaletteKeyboard.command(forKeyCode: 76) == .activate)
        #expect(PaletteKeyboard.command(forKeyCode: 53) == .dismiss)
        #expect(PaletteKeyboard.command(forKeyCode: 0) == nil)
    }

    @Test
    func commandKClosesTheInWindowPaletteWithoutDoubleToggling() {
        #expect(PaletteKeyboard.command(
            forKeyCode: 40,
            modifiers: .command
        ) == .dismiss)
        #expect(PaletteKeyboard.command(
            forKeyCode: 40,
            modifiers: [.command, .shift]
        ) == nil)
        #expect(PaletteKeyboard.command(forKeyCode: 40) == nil)
    }

    @Test
    func keyboardSelectionWrapsAndNormalizesChangingResults() {
        #expect(PaletteKeyboard.movedSelection(from: 3, itemCount: 4, delta: 1) == 0)
        #expect(PaletteKeyboard.movedSelection(from: 0, itemCount: 4, delta: -1) == 3)
        #expect(PaletteKeyboard.normalizedSelection(10, itemCount: 4) == 2)
        #expect(PaletteKeyboard.normalizedSelection(-1, itemCount: 4) == 3)
        #expect(PaletteKeyboard.movedSelection(from: 8, itemCount: 0, delta: 1) == 0)
    }

    @Test
    func filteringTrimsWhitespaceAndMatchesCaseInsensitively() {
        #expect(PaletteFilter.normalizedQuery("  \n字号\t") == "字号")
        #expect(PaletteFilter.matches("放大字号", query: "  字号 "))
        #expect(PaletteFilter.matches("README.md", query: " readme "))
        #expect(PaletteFilter.matches("新建文档", query: "   "))
        #expect(!PaletteFilter.matches("保存", query: "打开"))
    }

    @Test
    func requiredCommandCatalogMatchesTheAuthoritativePalette() {
        #expect(PaletteCommandCatalog.required.map(\.id) == [
            .newDocument,
            .save,
            .findAndReplace,
            .togglePreview,
            .open,
            .increaseFont,
            .decreaseFont,
            .resetFont,
            .toggleSidebar,
        ])
        #expect(PaletteCommandCatalog.required.map(\.shortcut) == [
            "⌘N", "⌘S", "⌘F", "⌘⇧P", "⌘O", "⌘ +", "⌘ -", "⌘ 0", "⌘\\",
        ])
    }

    @Test
    func reopenCommandExistsOnlyWhenThereIsAClosedTab() throws {
        #expect(PaletteCommandCatalog.commands(lastClosedName: nil) == PaletteCommandCatalog.required)
        let commands = PaletteCommandCatalog.commands(lastClosedName: "draft.md")
        let reopen = try #require(commands.last)
        #expect(reopen.id == .reopenClosedTab)
        #expect(reopen.title == "恢复刚关闭的标签 · draft.md")
        #expect(reopen.shortcut == "⌘⇧T")
    }

    @Test
    func doubleShiftUsesAThreeHundredFiftyMillisecondExclusiveWindow() {
        let tracker = DoubleShiftTracker()
        #expect(!tracker.registerPress(at: 10))
        #expect(tracker.registerPress(at: 10.349))

        #expect(!tracker.registerPress(at: 20))
        #expect(!tracker.registerPress(at: 20.35))
        #expect(tracker.registerPress(at: 20.60))

        #expect(!tracker.registerPress(at: 30))
        tracker.reset()
        #expect(!tracker.registerPress(at: 30.1))
    }

    @Test @MainActor
    func openingPaletteCommitsBeforePublishingAndClosingDoesNotCommit() {
        let manager = DocumentManager()
        var paletteStateAtCommit: [Bool] = []
        manager.commitActiveEditing = {
            paletteStateAtCommit.append(manager.paletteOpen)
        }

        manager.openCommandPalette()
        #expect(manager.paletteOpen)
        #expect(paletteStateAtCommit == [false])

        manager.openCommandPalette()
        #expect(paletteStateAtCommit == [false])

        manager.toggleCommandPalette()
        #expect(!manager.paletteOpen)
        #expect(paletteStateAtCommit == [false])

        manager.toggleCommandPalette()
        #expect(manager.paletteOpen)
        #expect(paletteStateAtCommit == [false, false])
    }

    @Test
    func globalShortcutCatalogCoversEveryGoalShortcut() {
        #expect(AppShortcutCatalog.required.map(\.id) == AppShortcutID.allCases)
        let byID = Dictionary(uniqueKeysWithValues: AppShortcutCatalog.required.map {
            ($0.id, ($0.key.character, $0.modifiers))
        })
        #expect(byID[.newDocument]?.0 == "n")
        #expect(byID[.save]?.0 == "s")
        #expect(byID[.open]?.0 == "o")
        #expect(byID[.closeTab]?.0 == "w")
        #expect(byID[.find]?.0 == "f")
        #expect(byID[.commandPalette]?.0 == "k")
        #expect(byID[.toggleSidebar]?.0 == "\\")
        #expect(byID[.increaseFont]?.0 == "+")
        #expect(byID[.decreaseFont]?.0 == "-")
        #expect(byID[.resetFont]?.0 == "0")
        #expect(byID[.togglePreview]?.0 == "p")
        #expect(byID[.reopenClosedTab]?.0 == "t")
        #expect(byID[.togglePreview]?.1 == [.command, .shift])
        #expect(byID[.reopenClosedTab]?.1 == [.command, .shift])
        #expect(AppShortcutCatalog.required
            .filter { ![.togglePreview, .reopenClosedTab].contains($0.id) }
            .allSatisfy { $0.modifiers == .command })
    }
}
