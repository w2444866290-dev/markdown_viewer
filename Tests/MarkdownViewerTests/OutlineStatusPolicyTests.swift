import AppKit
import Foundation
import Testing
@testable import MarkdownViewer

@Suite(.serialized)
@MainActor
struct OutlineStatusPolicyTests {
    @Test("outline titles hide closing ATX markers and inline Markdown")
    func outlineHeadingPresentation() {
        let textView = NSTextView()
        textView.string = "# **Bold** and [Link](https://example.com) `code` ###\n"
        let controller = OutlineController()
        controller.textView = textView

        controller.rebuild()

        #expect(controller.headings.count == 1)
        #expect(controller.headings.first?.level == 1)
        #expect(controller.headings.first?.title == "Bold and Link code")
    }

    @Test("document geometry uses the 140 point current-heading threshold")
    func documentGeometryThreshold() {
        #expect(OutlineBehaviorPolicy.activeHeadingIndex(
            headingDocumentMinYs: [80, 240, 241],
            viewportTop: 100
        ) == 1)
        #expect(OutlineBehaviorPolicy.activeHeadingIndex(
            headingDocumentMinYs: [0, 140, 141],
            viewportTop: -20
        ) == 1)
        #expect(OutlineBehaviorPolicy.activeHeadingIndex(
            headingDocumentMinYs: [],
            viewportTop: 500
        ) == nil)
    }

    @Test("viewport geometry handles unrealized lazy-stack headings")
    func viewportGeometryThreshold() {
        let ids = ["first", "second", "third", "fourth"]

        #expect(OutlineBehaviorPolicy.activeHeadingIndex(
            orderedHeadingIDs: ids,
            viewportMinYByHeadingID: ["third": 141],
            previousIndex: 0
        ) == 1)
        #expect(OutlineBehaviorPolicy.activeHeadingIndex(
            orderedHeadingIDs: ids,
            viewportMinYByHeadingID: ["first": -500, "third": 100, "fourth": 141],
            previousIndex: 0
        ) == 2)
        #expect(OutlineBehaviorPolicy.activeHeadingIndex(
            orderedHeadingIDs: ids,
            viewportMinYByHeadingID: [:],
            previousIndex: 99
        ) == 3)
        #expect(OutlineBehaviorPolicy.activeHeadingIndex(
            orderedHeadingIDs: [String](),
            viewportMinYByHeadingID: [:],
            previousIndex: 2
        ) == nil)
    }

    @Test("rail leave grace ignores stale collapse requests and resets cleanly")
    func railLeaveGrace() {
        var state = OutlineRailInteractionState()
        state.enterRail()
        state.setHoveredIndex(2)
        let staleLeave = state.leaveRail()
        state.enterRail()

        let didRunStaleCollapse = state.collapse(ifCurrent: staleLeave)
        #expect(!didRunStaleCollapse)
        #expect(state.expanded)
        #expect(state.hoveredIndex == 2)

        let currentLeave = state.leaveRail()
        let didRunCurrentCollapse = state.collapse(ifCurrent: currentLeave)
        #expect(didRunCurrentCollapse)
        #expect(!state.expanded)
        #expect(state.hoveredIndex == nil)
        #expect(OutlineBehaviorPolicy.hoverLeaveDelay == 0.18)
        #expect(OutlineBehaviorPolicy.railExpansionDuration == 0.18)
        #expect(OutlineBehaviorPolicy.railRowHeightDuration == 0.24)
        #expect(OutlineBehaviorPolicy.railRowStagger == 0.012)
        #expect(abs(OutlineBehaviorPolicy.railExpansionSettlingDelay(
            rowIndex: 12
        ) - 0.384) < 0.000_001)

        state.enterRail()
        state.setHoveredIndex(1)
        state.reset()
        #expect(!state.expanded)
        #expect(state.hoveredIndex == nil)
    }

    @Test("new navigation invalidates an older pending wash")
    func navigationWashGeneration() {
        var state = OutlineWashState<String>()
        let first = state.beginNavigation()
        let second = state.beginNavigation()

        let didStartFirstWash = state.beginWash("first", ifCurrent: first)
        let didStartSecondWash = state.beginWash("second", ifCurrent: second)
        #expect(!didStartFirstWash)
        #expect(didStartSecondWash)
        #expect(state.blockID == "second")
        let didFinishFirstWash = state.finishWash(ifCurrent: first)
        let didFinishSecondWash = state.finishWash(ifCurrent: second)
        #expect(!didFinishFirstWash)
        #expect(didFinishSecondWash)
        #expect(state.blockID == nil)
        #expect(OutlineBehaviorPolicy.jumpDuration == 0.30)
        #expect(OutlineBehaviorPolicy.jumpTopInset == 40)
        #expect(OutlineBehaviorPolicy.washDuration == 0.90)
    }

    @Test("status recovery accepts only the latest scroll generation")
    func statusRecoveryGeneration() {
        var policy = StatusVisibilityPolicy()
        let first = policy.registerScrollActivity()
        let second = policy.registerScrollActivity()

        #expect(policy.isFaded)
        let didRunFirstRecovery = policy.recover(ifCurrent: first)
        #expect(!didRunFirstRecovery)
        #expect(policy.isFaded)
        let didRunSecondRecovery = policy.recover(ifCurrent: second)
        #expect(didRunSecondRecovery)
        #expect(!policy.isFaded)

        let staleAfterReset = policy.registerScrollActivity()
        policy.reset()
        let didRunStaleRecovery = policy.recover(ifCurrent: staleAfterReset)
        #expect(!didRunStaleRecovery)
        #expect(!policy.isFaded)
        #expect(StatusVisibilityPolicy.recoveryDelay == 0.80)
    }

    @Test("scroll activity excludes initial, stationary, and restored positions")
    func scrollActivityClassification() {
        var tracker = ScrollActivityTracker()

        let initial = tracker.observe(120)
        let stationary = tracker.observe(120.5)
        let moved = tracker.observe(121.1)
        let restored = tracker.observe(400, suppressed: true)
        let afterRestore = tracker.observe(400)
        let movedAfterRestore = tracker.observe(401)
        #expect(!initial)
        #expect(!stationary)
        #expect(moved)
        #expect(!restored)
        #expect(!afterRestore)
        #expect(movedAfterRestore)

        tracker.reset()
        let initialAfterReset = tracker.observe(900)
        #expect(!initialAfterReset)
    }

    @Test("shared editor models reject updates from an inactive document")
    func documentScopedModels() {
        let firstDocument = UUID()
        let secondDocument = UUID()

        let scroll = ScrollProgressModel()
        scroll.reset(for: firstDocument)
        scroll.publish(0.4, for: firstDocument, isScrollActivity: false)
        scroll.publish(0.5, for: firstDocument, isScrollActivity: true)
        #expect(scroll.value == 0.5)
        #expect(scroll.activityRevision == 1)

        scroll.reset(for: secondDocument)
        scroll.publish(0.9, for: firstDocument, isScrollActivity: true)
        #expect(scroll.value == 0)
        #expect(scroll.activityRevision == 1)
        scroll.publish(0.25, for: secondDocument, isScrollActivity: true)
        #expect(scroll.value == 0.25)
        #expect(scroll.activityRevision == 2)

        let activeHeading = ActiveHeadingModel()
        activeHeading.reset(for: firstDocument)
        activeHeading.publish(4, for: firstDocument)
        activeHeading.reset(for: secondDocument)
        activeHeading.publish(5, for: firstDocument)
        #expect(activeHeading.index == 0)
        activeHeading.publish(2, for: secondDocument)
        #expect(activeHeading.index == 2)

        let metrics = DocMetricsModel()
        metrics.reset(for: firstDocument)
        metrics.publish(charCount: 90, lineCount: 12, for: firstDocument)
        metrics.reset(for: secondDocument)
        metrics.publish(charCount: 50, lineCount: 8, for: firstDocument)
        #expect(metrics.charCount == 0)
        #expect(metrics.lineCount == 0)
        metrics.publish(charCount: 20, lineCount: 3, for: secondDocument)
        #expect(metrics.charCount == 20)
        #expect(metrics.lineCount == 3)
    }
}
