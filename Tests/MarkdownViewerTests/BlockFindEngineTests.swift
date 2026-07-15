import Foundation
import Testing
@testable import MarkdownViewer

@Suite
struct BlockFindEngineTests {
    @Test
    func representativeMarkdownProjectsOnlyObservableText() throws {
        let source = """
        # Visible **Heading**

        - [x] Task with [Link](https://hidden.example/path) and `inlineCode`

        1. Run command:
           ```bash
           npm run dev
           ```

        > Quoted reference[^scope]

        Text with <u>underline</u>.

        ```swift
        let emoji = "😀"
        ```

        | Name | Details |
        | --- | :---: |
        | Ada | a\\|b |

        ![Screenshot](private/image.png)

        [^scope]: Footnote prose
        """
        let document = MarkdownDocument(source: source)

        for visible in [
            "Visible Heading", "Task with Link and inlineCode", "Run command", "npm run dev",
            "Quoted reference", "scope", "underline", "let emoji", "😀",
            "Name", "Details", "Ada", "a|b", "Screenshot", "Footnote prose",
        ] {
            #expect(search(visible, in: document).matches.count == 1)
        }

        for hidden in [
            "https://hidden.example/path", "private/image.png", "swift", "[^scope]",
            "[x]", "**", "```", "bash", "<u>", ":---:",
        ] {
            #expect(search(hidden, in: document).matches.isEmpty)
        }

        let heading = try #require(document.blocks.first)
        let projection = BlockFindEngine.projection(for: heading)
        let visibleRange = (projection.text as NSString).range(of: "Visible Heading")
        let sourceRange = try #require(
            projection.sourceRange(forVisibleRange: visibleRange)
        )
        #expect((heading.source as NSString).substring(with: sourceRange) == "Visible **Heading")
    }

    @Test
    func activeSourceModeMakesDisplayedSyntaxSearchable() throws {
        let document = MarkdownDocument(
            source: "Read [Link](https://hidden.example/path) and **bold**"
        )
        let blockID = try #require(document.blocks.first?.id)

        #expect(search("https://hidden.example/path", in: document).matches.isEmpty)
        #expect(search("**", in: document).matches.isEmpty)
        #expect(search(
            "https://hidden.example/path",
            in: document,
            activeSourceBlockID: blockID
        ).matches.count == 1)
        #expect(search(
            "**",
            in: document,
            activeSourceBlockID: blockID
        ).matches.count == 2)
    }

    @Test("active table mode searches the exact editable cell value and maps the cell range")
    func activeTableModeMapsEditableCellValues() throws {
        var document = MarkdownDocument(source: """
        | **Name** | Value |
        | --- | --- |
        | [Link](secret) | a\\|b |
        """)
        let tableID = try #require(document.blocks.first?.id)

        #expect(search("secret", in: document).matches.isEmpty)

        let destination = try #require(search(
            "secret",
            in: document,
            activeTableBlockID: tableID
        ).matches.first)
        #expect(destination.tableCell?.row == 0)
        #expect(destination.tableCell?.column == 0)
        #expect(destination.tableCell?.range == NSRange(location: 7, length: 6))

        let escapedPipe = try #require(search(
            "|",
            in: document,
            activeTableBlockID: tableID
        ).matches.first)
        #expect(escapedPipe.tableCell?.row == 0)
        #expect(escapedPipe.tableCell?.column == 1)
        #expect(escapedPipe.tableCell?.range == NSRange(location: 1, length: 1))

        _ = try BlockFindEngine.replace(escapedPipe, with: #"x|y\z"#, in: &document)

        let grid = try document.tableGrid(for: tableID)
        #expect(grid.rows[0][1] == #"ax|y\zb"#)
    }

    @Test
    func unicodeProjectionAndReplacementUseUTF16SafeRanges() throws {
        var document = MarkdownDocument(source: "before\n\n**A😀B**\n\nafter")
        let before = document.blocks
        let result = search("😀", in: document)
        let match = try #require(result.matches.first)

        #expect(match.visibleRange.length == 2)
        #expect((before[1].source as NSString).substring(with: match.sourceRange) == "😀")

        _ = try BlockFindEngine.replace(match, with: "🌟", in: &document)

        #expect(document.source == "before\n\n**A🌟B**\n\nafter")
        #expect(document.blocks[0] == before[0])
        #expect(document.blocks[1].id == before[1].id)
        #expect(document.blocks[2] == before[2])
    }

    @Test
    func replacementAcrossHiddenInlineSyntaxKeepsBalancedMarkdown() throws {
        let cases = [
            (
                source: "prefix **bold** suffix",
                query: "prefix bold",
                expected: "**fresh** suffix"
            ),
            (
                source: "prefix [label](https://example.com) suffix",
                query: "prefix label",
                expected: "[fresh](https://example.com) suffix"
            ),
            (
                source: "prefix `code` suffix",
                query: "prefix code",
                expected: "`fresh` suffix"
            ),
            (
                source: "prefix **bold** and [link](https://example.com) suffix",
                query: "prefix bold and link",
                expected: "fresh suffix"
            ),
        ]

        for item in cases {
            var document = MarkdownDocument(source: item.source)
            let match = try #require(search(item.query, in: document).matches.first)

            _ = try BlockFindEngine.replace(match, with: "fresh", in: &document)

            #expect(document.source == item.expected)
            #expect(search("fresh suffix", in: document).matches.count == 1)
        }
    }

    @Test
    func replaceAllAcrossHiddenSyntaxUsesOneStableSnapshot() throws {
        var document = MarkdownDocument(source: """
        prefix **bold** suffix

        prefix [label](https://example.com) suffix
        """)
        let result = search(
            #"prefix (?:bold|label)"#,
            in: document,
            useRegex: true
        )

        let count = try BlockFindEngine.replaceAll(
            result,
            with: "fresh",
            in: &document
        )

        #expect(count == 2)
        #expect(document.source == """
        **fresh** suffix

        [fresh](https://example.com) suffix
        """)
    }

    @Test
    func replacementRejectsAStaleBlockSnapshotEvenWhenVisibleTextStillMatches() throws {
        var document = MarkdownDocument(source: "prefix **bold** suffix")
        let match = try #require(search("bold", in: document).matches.first)
        let blockID = try #require(document.blocks.first?.id)
        _ = try document.replaceBlock(id: blockID, with: "prefix __bold__ suffix")

        #expect(throws: BlockFindMutationError.staleMatch(blockID, match.sourceRange)) {
            _ = try BlockFindEngine.replace(match, with: "fresh", in: &document)
        }
    }

    @Test
    func caseAndWholeWordOptionsAreIndependent() {
        let document = MarkdownDocument(source: "Alpha alpha alphabet ALPHA")

        #expect(search("Alpha", in: document, caseSensitive: true).matches.count == 1)
        #expect(search("alpha", in: document).matches.count == 4)
        #expect(search("alpha", in: document, wholeWord: true).matches.count == 3)
        #expect(search(
            "Alpha",
            in: document,
            caseSensitive: true,
            wholeWord: true
        ).matches.count == 1)
    }

    @Test
    func invalidRegexIsReportedWithoutMatches() {
        let document = MarkdownDocument(source: "visible text")
        let result = search("([", in: document, useRegex: true)

        #expect(result.error == .invalidRegularExpression)
        #expect(result.matches.isEmpty)
    }

    @Test
    func regexCaptureReplacementPreservesNeighborBlocksAndBytes() throws {
        let original = "prefix\r\n\r\nName: Ada\r\n\r\nsuffix\r\n  "
        var document = MarkdownDocument(source: original)
        let blocks = document.blocks
        let result = search(#"Name: (\w+)"#, in: document, useRegex: true)
        let match = try #require(result.matches.first)

        #expect(match.expandedReplacement(for: "Person: $1 Lovelace") == "Person: Ada Lovelace")
        _ = try BlockFindEngine.replace(
            match,
            with: "Person: $1 Lovelace",
            in: &document
        )

        #expect(document.source == "prefix\r\n\r\nPerson: Ada Lovelace\r\n\r\nsuffix\r\n  ")
        #expect(document.blocks[0] == blocks[0])
        #expect(document.blocks[1].id == blocks[1].id)
        #expect(document.blocks[2] == blocks[2])
    }

    @Test
    func replaceAllUsesLocalBlockReplacementAndStableOrdering() throws {
        var document = MarkdownDocument(source: "left\n\nbeta 1\r\n\r\nbeta 2\n\nright")
        let before = document.blocks
        let result = search(#"beta (\d)"#, in: document, useRegex: true)

        #expect(result.matches.count == 2)
        #expect(result.wrappedIndex(from: 0, delta: -1) == 1)
        #expect(result.wrappedIndex(from: 1, delta: 1) == 0)
        let count = try BlockFindEngine.replaceAll(
            result,
            with: "item-$1",
            in: &document
        )

        #expect(count == 2)
        #expect(document.source == "left\n\nitem-1\r\n\r\nitem-2\n\nright")
        #expect(document.blocks.map(\.id) == before.map(\.id))
        #expect(document.blocks[0] == before[0])
        #expect(document.blocks[3] == before[3])
    }

    @Test
    func syntaxOnlyQueriesDoNotLeakFromLinksCodeFencesOrTables() {
        let document = MarkdownDocument(source: """
        [shown](secret-destination)

        ```language-label
        code-content
        ```

        | Cell |
        | --- |
        | TableBody |
        """)

        #expect(search("shown", in: document).matches.count == 1)
        #expect(search("code-content", in: document).matches.count == 1)
        #expect(search("Cell", in: document).matches.count == 1)
        #expect(search("TableBody", in: document).matches.count == 1)
        #expect(search("secret-destination", in: document).matches.isEmpty)
        #expect(search("language-label", in: document).matches.isEmpty)
        #expect(search("---", in: document).matches.isEmpty)
        #expect(search("|", in: document).matches.isEmpty)
    }

    private func search(
        _ query: String,
        in document: MarkdownDocument,
        caseSensitive: Bool = false,
        wholeWord: Bool = false,
        useRegex: Bool = false,
        activeSourceBlockID: UUID? = nil,
        activeTableBlockID: UUID? = nil
    ) -> BlockFindResult {
        BlockFindEngine.search(
            in: document,
            options: BlockFindOptions(
                query: query,
                caseSensitive: caseSensitive,
                wholeWord: wholeWord,
                useRegex: useRegex,
                activeSourceBlockID: activeSourceBlockID,
                activeTableBlockID: activeTableBlockID
            )
        )
    }
}
