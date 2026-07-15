import Foundation
import Testing
@testable import MarkdownViewer

@Suite
struct PreviewInteractionTests {
    private final class CallbackOwner {}

    @Test
    func previewPolicyKeepsTaskTogglesButSuppressesEditingAndHoverCues() {
        let preview = MarkdownBlockInteractionPolicy(previewMode: true)
        var taskMutationCount = 0
        var blockActivationCount = 0

        preview.performTaskToggle { taskMutationCount += 1 }
        preview.performEditingAction { blockActivationCount += 1 }

        #expect(!preview.allowsEditingActions)
        #expect(preview.allowsTaskToggle)
        #expect(!preview.exposesBlockAccessibilityAction(kind: .paragraph))
        #expect(!preview.exposesBlockAccessibilityAction(kind: .table))
        #expect(!preview.showsEditHoverCue(hovered: true))
        #expect(taskMutationCount == 1)
        #expect(blockActivationCount == 0)
    }

    @Test
    func editPolicyAllowsActionsAndHoverCues() {
        let editing = MarkdownBlockInteractionPolicy(previewMode: false)
        var actionCount = 0
        var taskMutationCount = 0

        editing.performEditingAction { actionCount += 1 }
        editing.performTaskToggle { taskMutationCount += 1 }

        #expect(editing.allowsEditingActions)
        #expect(editing.allowsTaskToggle)
        #expect(editing.exposesBlockAccessibilityAction(kind: .paragraph))
        #expect(!editing.exposesBlockAccessibilityAction(kind: .table))
        #expect(editing.showsEditHoverCue(hovered: true))
        #expect(!editing.showsEditHoverCue(hovered: false))
        #expect(actionCount == 1)
        #expect(taskMutationCount == 1)
    }

    @Test
    func rendererEqualityIncludesCallbackOwnerIdentity() {
        let block = MarkdownDocument(source: "body").blocks[0]
        let firstOwner = CallbackOwner()
        let secondOwner = CallbackOwner()

        func renderer(owner: CallbackOwner) -> MarkdownBlockRenderer {
            MarkdownBlockRenderer(
                block: block,
                bodyFontSize: 16.5,
                previewMode: false,
                isFirstBlock: true,
                paperWidth: 760,
                windowWidth: 1_180,
                previousBottomMargin: 0,
                revision: 0,
                findMatches: [],
                currentFindMatch: nil,
                diagnosticIndex: 0,
                callbackOwnerIdentity: ObjectIdentifier(owner),
                onActivate: {},
                onTaskToggle: { _ in },
                onTableCell: { _ in }
            )
        }

        #expect(renderer(owner: firstOwner) == renderer(owner: firstOwner))
        #expect(renderer(owner: firstOwner) != renderer(owner: secondOwner))
    }
}
