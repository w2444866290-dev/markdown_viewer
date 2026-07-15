import Foundation
import Testing
@testable import MarkdownViewer

@Suite("Markdown editing commands")
struct MarkdownEditingCommandsTests {
    @Test
    func ordinaryEnterSplitsAtCaretAndDeletesSelection() throws {
        let split = try apply(.enter, to: "helloworld", at: 5)
        #expect(split.replacementSource == "hello\n\nworld")
        #expect(split.selection == NSRange(location: 7, length: 0))
        #expect(split.boundaryAction == .splitBlock)

        let replacing = try apply(
            .enter,
            to: "helloXXworld",
            selection: NSRange(location: 5, length: 2)
        )
        #expect(replacing.replacementSource == "hello\n\nworld")
        #expect(replacing.selection == NSRange(location: 7, length: 0))
        #expect(replacing.boundaryAction == .splitBlock)
    }

    @Test
    func enterPreservesCRLFAndCodeUsesOneLineEnding() throws {
        let paragraph = try apply(
            .enter,
            to: "first\r\nsecond",
            at: 10
        )
        #expect(paragraph.replacementSource == "first\r\nsec\r\n\r\nond")
        #expect(paragraph.selection == NSRange(location: 14, length: 0))

        let code = try apply(
            .enter,
            to: "```swift\r\nlet x = 1\r\n```",
            at: 21,
            blockKind: .code
        )
        #expect(code.replacementSource == "```swift\r\nlet x = 1\r\n\r\n```")
        #expect(code.selection == NSRange(location: 23, length: 0))
        #expect(code.boundaryAction == nil)
    }

    @Test
    func unorderedListsContinueTheirMarkerAndSpacing() throws {
        let dash = try apply(.enter, to: "- one", at: 5, blockKind: .list)
        #expect(dash.replacementSource == "- one\n- ")
        #expect(dash.selection == NSRange(location: 8, length: 0))

        let plus = try apply(.enter, to: "+   item", at: 8, blockKind: .list)
        #expect(plus.replacementSource == "+   item\n+   ")
        #expect(plus.selection == NSRange(location: 13, length: 0))
    }

    @Test("Enter follows the current draft kind instead of the original block kind")
    func paragraphDraftThatBecomesListContinuesList() throws {
        let draft = "- item"
        let draftKind = MarkdownDocument.inferredBlockKind(forDraft: draft)

        let result = try apply(
            .enter,
            to: draft,
            at: (draft as NSString).length,
            blockKind: draftKind
        )

        #expect(draftKind == .list)
        #expect(result.replacementSource == "- item\n- ")
        #expect(result.selection == NSRange(location: 9, length: 0))
        #expect(result.boundaryAction == nil)
    }

    @Test("draft kind follows the block containing the caret after a multi-block paste")
    func multiBlockPasteUsesCaretLocalKind() throws {
        let draft = "intro paragraph\n\n- pasted item"
        let caret = (draft as NSString).length
        let draftKind = MarkdownDocument.inferredBlockKind(
            forDraft: draft,
            atUTF16Offset: caret
        )

        let result = try apply(
            .enter,
            to: draft,
            at: caret,
            blockKind: draftKind
        )

        #expect(draftKind == .list)
        #expect(result.replacementSource == draft + "\n- ")
        #expect(result.boundaryAction == nil)
    }

    @Test
    func taskContinuationIsAlwaysUnchecked() throws {
        for source in ["- [x] done", "- [X] done", "- [ ] done"] {
            let result = try apply(
                .enter,
                to: source,
                at: (source as NSString).length,
                blockKind: .list
            )
            #expect(result.replacementSource == source + "\n- [ ] ")
            #expect(result.selection == NSRange(
                location: (result.replacementSource as NSString).length,
                length: 0
            ))
        }

        let ordered = "  a. [x] child"
        let orderedResult = try apply(
            .enter,
            to: ordered,
            at: (ordered as NSString).length,
            blockKind: .list
        )
        #expect(orderedResult.replacementSource == ordered + "\n  b. [ ] ")
    }

    @Test
    func emptyListItemExitsListWithoutLeavingMarkup() throws {
        let onlyItem = try apply(.enter, to: "- ", at: 2, blockKind: .list)
        #expect(onlyItem.replacementSource == "")
        #expect(onlyItem.selection == NSRange(location: 0, length: 0))
        #expect(onlyItem.boundaryAction == .exitList)

        let source = "- one\r\n- [x] "
        let afterItem = try apply(
            .enter,
            to: source,
            at: (source as NSString).length,
            blockKind: .list
        )
        #expect(afterItem.replacementSource == "- one\r\n")
        #expect(afterItem.selection == NSRange(location: 7, length: 0))
        #expect(afterItem.boundaryAction == .exitList)
    }

    @Test
    func orderedListsCycleNumericAlphaAndRomanByLevel() throws {
        try expectContinuation(from: "1. first", marker: "2. ")
        try expectContinuation(from: "9) ninth", marker: "10) ")
        try expectContinuation(from: "  a. child", marker: "  b. ")
        try expectContinuation(from: "  z) child", marker: "  aa) ")
        try expectContinuation(from: "    iv. deep", marker: "    v. ")
        try expectContinuation(from: "   1. child", marker: "   b. ")
        try expectContinuation(from: "      1. deep", marker: "      ii. ")
    }

    @Test
    func nestedQuoteListRetainsQuoteAndUsesListLevel() throws {
        let source = ">   a. child"
        let result = try apply(
            .enter,
            to: source,
            at: (source as NSString).length,
            blockKind: .quote
        )
        #expect(result.replacementSource == ">   a. child\n>   b. ")
        #expect(result.boundaryAction == nil)
    }

    @Test
    func quoteContinuationAndExitPreserveNestingAndCRLF() throws {
        let nested = try apply(
            .enter,
            to: "> > deep\r\n> tail",
            at: 8,
            blockKind: .quote
        )
        #expect(nested.replacementSource == "> > deep\r\n> > \r\n> tail")
        #expect(nested.selection == NSRange(location: 14, length: 0))

        let empty = try apply(
            .enter,
            to: "> ",
            at: 2,
            blockKind: .quote
        )
        #expect(empty.replacementSource == "")
        #expect(empty.selection == NSRange(location: 0, length: 0))
        #expect(empty.boundaryAction == .exitQuote)
    }

    @Test
    func blockStartBackspaceRequestsMergeAndOtherBackspaceEditsText() throws {
        let merge = try apply(.backspace, to: "current", at: 0)
        #expect(merge.replacementSource == "current")
        #expect(merge.selection == NSRange(location: 0, length: 0))
        #expect(merge.boundaryAction == .mergeWithPrevious)

        let deletion = try apply(.backspace, to: "abcd", at: 3)
        #expect(deletion.replacementSource == "abd")
        #expect(deletion.selection == NSRange(location: 2, length: 0))

        let selected = try apply(
            .backspace,
            to: "abcd",
            selection: NSRange(location: 1, length: 2)
        )
        #expect(selected.replacementSource == "ad")
        #expect(selected.selection == NSRange(location: 1, length: 0))
    }

    @Test
    func arrowsOnlyRequestNavigationAtBlockEdges() throws {
        let source = "first\nsecond"
        #expect(try apply(.arrowUp, to: source, at: 3).boundaryAction == .navigateToPreviousBlock)
        #expect(try apply(.arrowUp, to: source, at: 9).boundaryAction == nil)
        #expect(try apply(.arrowDown, to: source, at: 3).boundaryAction == nil)
        #expect(try apply(.arrowDown, to: source, at: 9).boundaryAction == .navigateToNextBlock)

        let selected = try apply(
            .arrowDown,
            to: source,
            selection: NSRange(location: 7, length: 3)
        )
        #expect(selected.boundaryAction == nil)
    }

    @Test
    func tabInsertsAtCaretPastLeadingWhitespaceOutsideContainers() throws {
        let indented = try apply(.tab, to: "item", at: 2)
        #expect(indented.replacementSource == "it  em")
        #expect(indented.selection == NSRange(location: 4, length: 0))

        let afterIndent = try apply(.tab, to: "  item", at: 3)
        #expect(afterIndent.replacementSource == "  i  tem")
        #expect(afterIndent.selection == NSRange(location: 5, length: 0))
    }

    @Test
    func tabIndentsContainersAndCaretWithinLeadingWhitespace() throws {
        let atIndentBoundary = try apply(.tab, to: "  item", at: 2)
        #expect(atIndentBoundary.replacementSource == "    item")
        #expect(atIndentBoundary.selection == NSRange(location: 4, length: 0))

        let list = try apply(.tab, to: "- item", at: 4, blockKind: .list)
        #expect(list.replacementSource == "  - item")
        #expect(list.selection == NSRange(location: 6, length: 0))

        let quote = try apply(.tab, to: "> item", at: 4, blockKind: .quote)
        #expect(quote.replacementSource == "  > item")
        #expect(quote.selection == NSRange(location: 6, length: 0))
    }

    @Test
    func shiftTabOutdentsSingleLineAndPreservesCaret() throws {
        let outdented = try apply(.shiftTab, to: "  item", at: 4)
        #expect(outdented.replacementSource == "item")
        #expect(outdented.selection == NSRange(location: 2, length: 0))

        let tabOutdented = try apply(.shiftTab, to: "\titem", at: 3)
        #expect(tabOutdented.replacementSource == "item")
        #expect(tabOutdented.selection == NSRange(location: 2, length: 0))
    }

    @Test
    func shiftEnterUsesContextSpecificLineAndBlockBehavior() throws {
        let list = try apply(
            .shiftEnter,
            to: "- item",
            at: 6,
            blockKind: .list
        )
        #expect(list.replacementSource == "- item\n")
        #expect(list.selection == NSRange(location: 7, length: 0))
        #expect(list.boundaryAction == nil)

        let quote = try apply(
            .shiftEnter,
            to: "> quoted",
            at: 8,
            blockKind: .quote
        )
        #expect(quote.replacementSource == "> quoted\n> ")
        #expect(quote.selection == NSRange(location: 11, length: 0))
        #expect(quote.boundaryAction == nil)

        let emptyQuote = try apply(
            .shiftEnter,
            to: "> ",
            at: 2,
            blockKind: .quote
        )
        #expect(emptyQuote.replacementSource == "> \n> ")
        #expect(emptyQuote.boundaryAction == nil)

        let paragraph = try apply(.shiftEnter, to: "helloworld", at: 5)
        #expect(paragraph.replacementSource == "hello\n\nworld")
        #expect(paragraph.selection == NSRange(location: 7, length: 0))
        #expect(paragraph.boundaryAction == .splitBlock)

        for kind in [MarkdownBlockKind.code, .table] {
            let literal = try apply(
                .shiftEnter,
                to: "left|right",
                at: 4,
                blockKind: kind
            )
            #expect(literal.replacementSource == "left\n|right")
            #expect(literal.selection == NSRange(location: 5, length: 0))
            #expect(literal.boundaryAction == nil)
        }
    }

    @Test
    func multilineIndentExcludesLineAtSelectionEnd() throws {
        let source = "one\r\ntwo\r\nthree"
        let selection = NSRange(location: 0, length: 10)
        let result = try apply(.tab, to: source, selection: selection)
        #expect(result.replacementSource == "  one\r\n  two\r\nthree")
        #expect(result.selection == NSRange(location: 2, length: 12))
    }

    @Test
    func multilineOutdentHandlesSpacesTabsAndOrderedUnits() throws {
        let source = "   1. one\r\n\t- two\r\n one"
        let result = try apply(
            .shiftTab,
            to: source,
            selection: NSRange(location: 0, length: (source as NSString).length)
        )
        #expect(result.replacementSource == "1. one\r\n- two\r\none")
        #expect(result.selection.location == 0)
        #expect(result.selection.length == (result.replacementSource as NSString).length)
    }

    @Test
    func formattingWrapsSelectionsOrInsertsPairedMarkers() throws {
        let bold = try apply(
            .bold,
            to: "hello",
            selection: NSRange(location: 1, length: 3)
        )
        #expect(bold.replacementSource == "h**ell**o")
        #expect(bold.selection == NSRange(location: 3, length: 3))

        let italic = try apply(.italic, to: "text", at: 2)
        #expect(italic.replacementSource == "te**xt")
        #expect(italic.selection == NSRange(location: 3, length: 0))

        let code = try apply(.inlineCode, to: "text", at: 4)
        #expect(code.replacementSource == "text``")
        #expect(code.selection == NSRange(location: 5, length: 0))
    }

    @Test
    func emojiSelectionsUseUTF16AndBackspaceDeletesWholeGrapheme() throws {
        let source = "A😀B"
        let bold = try apply(
            .bold,
            to: source,
            selection: NSRange(location: 1, length: 2)
        )
        #expect(bold.replacementSource == "A**😀**B")
        #expect(bold.selection == NSRange(location: 3, length: 2))

        let deleted = try apply(.backspace, to: source, at: 3)
        #expect(deleted.replacementSource == "AB")
        #expect(deleted.selection == NSRange(location: 1, length: 0))

        let family = "A👨‍👩‍👧‍👦B"
        let familyRange = (family as NSString).range(of: "👨‍👩‍👧‍👦")
        let familyDeleted = try apply(
            .backspace,
            to: family,
            at: NSMaxRange(familyRange)
        )
        #expect(familyDeleted.replacementSource == "AB")
        #expect(familyDeleted.selection == NSRange(location: 1, length: 0))
    }

    @Test
    func invalidUTF16RangesAreRejectedWithoutMutation() {
        let source = "A😀B"
        let invalidRanges = [
            NSRange(location: -1, length: 0),
            NSRange(location: 5, length: 0),
            NSRange(location: 2, length: 0),
            NSRange(location: 1, length: 1),
            NSRange(location: Int.max - 2, length: 10),
        ]

        for range in invalidRanges {
            #expect(throws: MarkdownEditingCommandError.invalidSelection(range)) {
                try MarkdownEditingCommands.apply(
                    .bold,
                    to: source,
                    selection: range,
                    blockKind: .paragraph
                )
            }
        }

        let family = "A👨‍👩‍👧‍👦B"
        let familyRange = (family as NSString).range(of: "👨‍👩‍👧‍👦")
        let insideFamily = NSRange(location: familyRange.location + 2, length: 0)
        #expect(throws: MarkdownEditingCommandError.invalidSelection(insideFamily)) {
            try MarkdownEditingCommands.apply(
                .bold,
                to: family,
                selection: insideFamily,
                blockKind: .paragraph
            )
        }
    }

    private func expectContinuation(from source: String, marker: String) throws {
        let result = try apply(
            .enter,
            to: source,
            at: (source as NSString).length,
            blockKind: .list
        )
        #expect(result.replacementSource == source + "\n" + marker)
        #expect(result.selection == NSRange(
            location: (result.replacementSource as NSString).length,
            length: 0
        ))
    }

    private func apply(
        _ command: MarkdownEditingCommand,
        to source: String,
        at location: Int,
        blockKind: MarkdownBlockKind = .paragraph
    ) throws -> MarkdownEditingResult {
        try apply(
            command,
            to: source,
            selection: NSRange(location: location, length: 0),
            blockKind: blockKind
        )
    }

    private func apply(
        _ command: MarkdownEditingCommand,
        to source: String,
        selection: NSRange,
        blockKind: MarkdownBlockKind = .paragraph
    ) throws -> MarkdownEditingResult {
        try MarkdownEditingCommands.apply(
            command,
            to: source,
            selection: selection,
            blockKind: blockKind
        )
    }
}
