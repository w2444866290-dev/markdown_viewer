import Testing
@testable import MarkdownViewer

@MainActor
struct FeedbackOverlayPolicyTests {
    @Test("tooltip uses the prototype dwell and entry timings")
    func tooltipTimingMatchesPrototype() {
        #expect(MVTooltipTiming.dwell == 0.480)
        #expect(MVTooltipTiming.entryDuration == 0.12)
    }

    @Test("toast mounts and dismisses without an independent animation state")
    func toastVisibilityTracksItsOnePointSixSecondLifecycle() {
        let toaster = Toaster()
        toaster.flash("已复制代码")

        #expect(toaster.visible)
        #expect(toaster.message == "已复制代码")
        #expect(toaster.hasPendingDismissal)

        toaster.dismiss()
        #expect(!toaster.visible)
        #expect(!toaster.hasPendingDismissal)
    }
}
