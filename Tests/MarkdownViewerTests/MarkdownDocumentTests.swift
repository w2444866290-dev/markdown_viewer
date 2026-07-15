import Foundation
import Testing
@testable import MarkdownViewer

@Suite("Lossless Markdown document")
struct MarkdownDocumentTests {
    @Test("untouched source preserves mixed terminators and no final newline")
    func mixedLineEndingRoundTrip() {
        let source = "\r\n \t\r# Heading\r\n\r\nBody line one\rBody line two\nTail without final newline"
        let document = MarkdownDocument(source: source)

        #expect(document.source == source)
        #expect(Array(document.source.utf8) == Array(source.utf8))
        #expect(document.blocks.first?.leadingTrivia == "\r\n \t\r")
        #expect(document.trailingTrivia.isEmpty)
        #expect(document.preferredLineEnding == "\r\n")
    }

    @Test("leading and trailing blank trivia remain exact")
    func blankTriviaRoundTrip() {
        let source = "\n\r\n# Heading\r\n\r\n  \t\r"
        let document = MarkdownDocument(source: source)

        #expect(document.source == source)
        #expect(document.blocks.count == 1)
        #expect(document.blocks[0].leadingTrivia == "\n\r\n")
        #expect(document.blocks[0].source == "# Heading")
        #expect(document.trailingTrivia == "\r\n\r\n  \t\r")
    }

    @Test("blank-only documents expose one editable paragraph without data loss")
    func blankOnlyDocument() {
        for source in ["", "\n", "\r\n \t\r"] {
            let document = MarkdownDocument(source: source)
            #expect(document.blocks.count == 1)
            #expect(document.blocks[0].kind == .paragraph)
            #expect(document.blocks[0].source.isEmpty)
            #expect(document.source == source)
        }
    }

    @Test("all required block kinds are recognized")
    func allBlockKinds() {
        let source = [
            "# Heading",
            "plain paragraph",
            "> quoted",
            "- list item\n  - nested item",
            "```swift\nlet value = 1\n```",
            "| A | B |\n| --- | :---: |\n| 1 | 2 |",
            "![alt](image.png)",
            "---",
            "[^note]: Footnote text",
        ].joined(separator: "\n\n")
        let document = MarkdownDocument(source: source)

        #expect(document.source == source)
        #expect(document.blocks.map(\.kind) == [
            .heading, .paragraph, .quote, .list, .code, .table, .image,
            .horizontalRule, .footnotes,
        ])
    }

    @Test("stable IDs survive Codable persistence")
    func codableStableIDs() throws {
        let document = MarkdownDocument(source: "# One\n\nTwo\n\n> Three")
        let encoded = try JSONEncoder().encode(document)
        let restored = try JSONDecoder().decode(MarkdownDocument.self, from: encoded)

        #expect(restored == document)
        #expect(restored.blocks.map(\.id) == document.blocks.map(\.id))
        #expect(restored.source == document.source)
    }

    @Test("single-block replacement keeps unrelated blocks and IDs identical")
    func localReplacementStability() throws {
        var document = MarkdownDocument(source: "alpha\r\n\r\nbeta\r\n\r\ngamma")
        let before = document.blocks
        let replacedID = before[1].id

        let replacementIDs = try document.replaceBlock(id: replacedID, with: "# changed")

        #expect(replacementIDs == [replacedID])
        #expect(document.blocks.count == 3)
        #expect(document.blocks[0] == before[0])
        #expect(document.blocks[2] == before[2])
        #expect(document.blocks[1].id == replacedID)
        #expect(document.blocks[1].kind == .heading)
        #expect(document.source == "alpha\r\n\r\n# changed\r\n\r\ngamma")
    }

    @Test("multi-paragraph paste reparses only the replacement slice")
    func multiParagraphReplacement() throws {
        var document = MarkdownDocument(source: "A\n\nB\n\nC\n\nD")
        let before = document.blocks
        let replacedID = before[1].id
        let c = before[2]
        let d = before[3]

        let inserted = try document.replaceBlock(
            id: replacedID,
            with: "first paragraph\n\nsecond paragraph\n\n> quote"
        )

        #expect(inserted.count == 3)
        #expect(inserted[0] == replacedID)
        #expect(Set(inserted).count == 3)
        #expect(document.blocks.map(\.kind) == [
            .paragraph, .paragraph, .paragraph, .quote, .paragraph, .paragraph,
        ])
        #expect(document.blocks[4] == c)
        #expect(document.blocks[5] == d)
        #expect(document.source == "A\n\nfirst paragraph\n\nsecond paragraph\n\n> quote\n\nC\n\nD")
    }

    @Test("replacement preserves both unedited byte regions")
    func uneditedRegionPreservation() throws {
        let prefix = "prefix\n\n"
        let suffix = "\r\n\r\nsuffix\r\n  "
        let replacement = "\rX\r\rY\n"
        var document = MarkdownDocument(source: prefix + "old" + suffix)
        let id = try #require(document.blocks.first(where: { $0.source == "old" })?.id)

        _ = try document.replaceBlock(id: id, with: replacement)

        #expect(document.source == prefix + replacement + suffix)
        #expect(document.source.hasPrefix(prefix))
        #expect(document.source.hasSuffix(suffix))
    }

    @Test("blank replacement retains an editable block and its ID")
    func blankReplacement() throws {
        var document = MarkdownDocument(source: "before\n\nto remove\n\nafter")
        let id = document.blocks[1].id

        let replacementIDs = try document.replaceBlock(id: id, with: "\r\n")

        #expect(replacementIDs == [id])
        #expect(document.blocks[1].id == id)
        #expect(document.blocks[1].kind == .paragraph)
        #expect(document.blocks[1].source.isEmpty)
        #expect(document.source == "before\n\n\r\n\n\nafter")
    }

    @Test("split retains the left ID and uses the exact requested separator")
    func splitBlock() throws {
        var document = MarkdownDocument(source: "hello world")
        let leftID = document.blocks[0].id

        let rightID = try document.splitBlock(
            id: leftID,
            atUTF16Offset: 5,
            separator: "\r\n\r\n"
        )

        #expect(document.blocks.count == 2)
        #expect(document.blocks[0].id == leftID)
        #expect(document.blocks[1].id == rightID)
        #expect(rightID != leftID)
        #expect(document.blocks[0].source == "hello")
        #expect(document.blocks[1].source == " world")
        #expect(document.source == "hello\r\n\r\n world")
    }

    @Test("split rejects a UTF-16 offset inside a surrogate pair")
    func splitRejectsBrokenUnicodeBoundary() throws {
        var document = MarkdownDocument(source: "A😀B")
        let id = document.blocks[0].id

        do {
            _ = try document.splitBlock(id: id, atUTF16Offset: 2, separator: "\n\n")
            Issue.record("Expected the split inside an emoji surrogate pair to fail")
        } catch let error as MarkdownDocumentError {
            #expect(error == .invalidUTF16Offset(2))
        }
        #expect(document.source == "A😀B")
        #expect(document.blocks[0].id == id)
    }

    @Test("empty paragraph insertion preserves existing separator bytes")
    func emptyParagraphInsertion() throws {
        var document = MarkdownDocument(source: "- one\r\n\r\n- three")
        let firstID = document.blocks[0].id
        let followingID = document.blocks[1].id

        let emptyID = try document.insertEmptyParagraph(after: firstID)

        #expect(document.source == "- one\r\n\r\n\r\n\r\n- three")
        #expect(document.blocks.map(\.id) == [firstID, emptyID, followingID])
        #expect(document.blocks[1].kind == .paragraph)
        #expect(document.blocks[1].source.isEmpty)
        #expect(document.blocks[1].leadingTrivia == "\r\n\r\n")
        #expect(document.blocks[2].leadingTrivia == "\r\n\r\n")

        let reopened = MarkdownDocument(source: document.source)
        #expect(reopened.blocks.map(\.kind) == [.list, .paragraph, .list])
        #expect(reopened.blocks[1].source.isEmpty)
        #expect(reopened.source == document.source)
    }

    @Test("container trailing boundaries survive a complete document rebuild")
    func trailingContainerEmptyParagraphRoundTrip() throws {
        for source in ["- last item\n\n", "> last quote\r\n\r\n"] {
            let document = MarkdownDocument(source: source)

            #expect(document.blocks.map(\.kind) == [
                source.hasPrefix("-") ? .list : .quote,
                .paragraph,
            ])
            #expect(document.blocks.last?.source.isEmpty == true)
            #expect(document.source == source)
            #expect(MarkdownDocument(source: document.source).blocks.map(\.kind) == document.blocks.map(\.kind))
        }

        #expect(MarkdownDocument(source: "- last item\n").blocks.map(\.kind) == [.list])
        #expect(MarkdownDocument(source: "> last quote\r\n").blocks.map(\.kind) == [.quote])
    }

    @Test("middle empty paragraph adds only a minimal boundary before existing trivia")
    func emptyParagraphDoesNotDuplicateFollowingTrivia() throws {
        let originalTrivia = "\r\n \t\r\n\r\n"
        var document = MarkdownDocument(source: "- one" + originalTrivia + "# Next")
        let listID = try #require(document.blocks.first?.id)

        _ = try document.insertEmptyParagraph(after: listID)

        #expect(document.source == "- one\r\n\r\n" + originalTrivia + "# Next")
        #expect(document.blocks[2].leadingTrivia == originalTrivia)
        let reopened = MarkdownDocument(source: document.source)
        #expect(reopened.blocks.map(\.kind) == [.list, .paragraph, .heading])
        #expect(reopened.blocks[2].leadingTrivia == originalTrivia)
    }

    @Test("merge removes only the selected boundary and retains the first ID")
    func mergeBlock() throws {
        var document = MarkdownDocument(source: "left\n\nright\r\n\r\nlast")
        let before = document.blocks

        let retained = try document.mergeBlockWithPrevious(
            id: before[1].id,
            separator: " "
        )

        #expect(retained == before[0].id)
        #expect(document.blocks.count == 2)
        #expect(document.blocks[0].id == before[0].id)
        #expect(document.blocks[1] == before[2])
        #expect(document.source == "left right\r\n\r\nlast")
    }

    @Test("task toggles preserve line endings and block identity")
    func taskToggle() throws {
        let source = "- [ ] first\r\n- [X] second\r\n- ordinary"
        var document = MarkdownDocument(source: source)
        let id = document.blocks[0].id

        let firstChecked = try document.toggleTask(blockID: id, itemIndex: 0)
        let secondChecked = try document.toggleTask(blockID: id, itemIndex: 1)

        #expect(firstChecked)
        #expect(!secondChecked)
        #expect(document.blocks[0].id == id)
        #expect(document.source == "- [x] first\r\n- [ ] second\r\n- ordinary")
    }

    @Test("table parsing and serialization preserve grid semantics")
    func tableRoundTrip() throws {
        let source = "| Name | Score | Note |\r\n| --- | :---: | ---: |\r\n| Ada | 10 | a\\|b |"
        let grid = try MarkdownTableGrid(parsing: source)

        #expect(grid.header == ["Name", "Score", "Note"])
        #expect(grid.rows == [["Ada", "10", "a|b"]])
        #expect(grid.alignments == [.left, .center, .right])
        #expect(grid.lineEnding == "\r\n")
        #expect(grid.serialized() == source)
        #expect(try MarkdownTableGrid(parsing: grid.serialized()) == grid)
    }

    @Test("editing one table cell preserves every unrelated source lexeme")
    func tableCellEditIsLexicallyLocal() throws {
        let source = " \t|  Name| Score  |Note |\r\n:----- | :----:|-----:\r\n| Ada  | 10 | a\\|b |\r\nBob| 7| plain  |"
        var grid = try MarkdownTableGrid(parsing: source)

        try grid.setCell(row: 0, column: 1, value: "11")

        #expect(grid.serialized() == source.replacingOccurrences(of: "| 10 |", with: "| 11 |"))
        #expect(grid.serialized().contains(":----- | :----:|-----:"))
        #expect(grid.serialized().contains("a\\|b"))

        let reproduced96Bytes = "| Name | Value| Note |\n| --- | ---:| :---: |\n| alpha | 8| keep   spacing |\n| beta | 7 | second |"
        var reproducedGrid = try MarkdownTableGrid(parsing: reproduced96Bytes)
        try reproducedGrid.setCell(row: 1, column: 1, value: "11")

        #expect(reproduced96Bytes.utf8.count == 96)
        #expect(reproducedGrid.serialized().utf8.count == 97)
        #expect(reproducedGrid.serialized() == reproduced96Bytes.replacingOccurrences(
            of: "| beta | 7 |",
            with: "| beta | 11 |"
        ))

        let ragged = "A |B\n---|---\n1| 2|3\n4 |5"
        var existingCellGrid = try MarkdownTableGrid(parsing: ragged)
        try existingCellGrid.setCell(row: 0, column: 0, value: "changed")
        #expect(existingCellGrid.serialized() == ragged.replacingOccurrences(
            of: "1| 2|3",
            with: "changed| 2|3"
        ))

        var implicitCellGrid = try MarkdownTableGrid(parsing: ragged)
        try implicitCellGrid.setCell(row: 1, column: 2, value: "6")
        #expect(implicitCellGrid.serialized() == ragged.replacingOccurrences(
            of: "4 |5",
            with: "4 |5|6"
        ))

        var implicitHeaderGrid = try MarkdownTableGrid(parsing: ragged)
        try implicitHeaderGrid.setHeader(column: 2, value: "C")
        #expect(implicitHeaderGrid.serialized() == "A |B|C\n---|---|---\n1| 2|3\n4 |5")
    }

    @Test("table alignment and reversible structural edits retain row-local style")
    func tableStructuralEditsInheritAndRestoreLexemes() throws {
        let source = "A |B  | C\r\n:-----| :----: |-----:\r\n1| two |3\r\n4 |five| 6"
        var grid = try MarkdownTableGrid(parsing: source)

        _ = try grid.cycleAlignment(at: 0)
        #expect(grid.serialized() == source.replacingOccurrences(of: ":-----|", with: ":-----:|"))

        _ = try grid.cycleAlignment(at: 0)
        _ = try grid.cycleAlignment(at: 0)
        #expect(grid.serialized() == source)

        grid.addRow(["7", "eight", "9"])
        #expect(grid.serialized().hasPrefix(source + "\r\n"))
        let deletedRow = grid.deleteRow(at: grid.rows.count - 1)
        #expect(deletedRow)
        #expect(grid.serialized() == source)

        grid.addColumn(header: "D", defaultCell: "x", alignment: .right)
        let deletedColumn = grid.deleteColumn(at: grid.columnCount - 1)
        #expect(deletedColumn)
        #expect(grid.serialized() == source)
    }

    @Test("ragged table structural operations preserve valid rectangular Markdown")
    func raggedTableStructuralOperationsRemainTables() throws {
        do {
            var document = MarkdownDocument(source: "A|B\n---|---\n1|2|3")
            let tableID = try #require(document.blocks.first?.id)
            var grid = try document.tableGrid(for: tableID)

            let deletedColumn = grid.deleteColumn(at: 0)
            #expect(deletedColumn)
            try document.replaceTable(blockID: tableID, with: grid)

            #expect(document.blocks.map(\.kind) == [.table])
            #expect(try document.tableGrid(for: tableID) == grid)
            #expect(document.source == "|B||\n---|---\n2|3")
        }

        do {
            var document = MarkdownDocument(source: "A|B\n---|---\n1|2|3")
            let tableID = try #require(document.blocks.first?.id)
            var grid = try document.tableGrid(for: tableID)
            _ = try grid.cycleAlignment(at: 2)
            try document.replaceTable(blockID: tableID, with: grid)

            #expect(document.blocks.map(\.kind) == [.table])
            #expect(try document.tableGrid(for: tableID) == grid)
            #expect(grid.columnCount == 3)
        }

        do {
            var document = MarkdownDocument(source: "A|B\n---|---\n1|2|3")
            let tableID = try #require(document.blocks.first?.id)
            var grid = try document.tableGrid(for: tableID)
            try grid.setHeader(column: 2, value: "C")
            try document.replaceTable(blockID: tableID, with: grid)

            #expect(document.blocks.map(\.kind) == [.table])
            #expect(try document.tableGrid(for: tableID) == grid)
            #expect(grid.header == ["A", "B", "C"])
        }

        do {
            let source = "A|B\n---|---\n1|2|3"
            var grid = try MarkdownTableGrid(parsing: source)
            grid.addRow(["4", "5", "6"])
            let deletedRow = grid.deleteRow(at: grid.rows.count - 1)
            #expect(deletedRow)
            let serialized = grid.serialized()
            let reparsed = MarkdownDocument(source: serialized)

            #expect(serialized == source)
            #expect(reparsed.blocks.map(\.kind) == [.table])
            #expect(try MarkdownTableGrid(parsing: serialized) == grid)
        }

        do {
            let source = "A|B\n---|---\n1|2|3\n4|5"
            var grid = try MarkdownTableGrid(parsing: source)
            let deletedRow = grid.deleteRow(at: 1)
            #expect(deletedRow)
            let serialized = grid.serialized()

            #expect(serialized == "A|B\n---|---\n1|2|3")
            #expect(MarkdownDocument(source: serialized).blocks.map(\.kind) == [.table])
            #expect(try MarkdownTableGrid(parsing: serialized) == grid)
        }

        do {
            let header = "|A|B|C|\n|---|---|---|\n"
            let body = ["1|2\n", "3|4|5\n", "6|7"]
            let expectedSources = [
                header + "3|4|5\n6|7",
                header + "1|2\n6|7",
                header + "1|2\n3|4|5",
            ]
            for deletedIndex in body.indices {
                var grid = try MarkdownTableGrid(parsing: header + body.joined())
                let deletedRow = grid.deleteRow(at: deletedIndex)
                #expect(deletedRow)
                let expected = expectedSources[deletedIndex]

                #expect(grid.serialized() == expected)
                #expect(MarkdownDocument(source: expected).blocks.map(\.kind) == [.table])
                #expect(try MarkdownTableGrid(parsing: expected) == grid)
            }
        }

        do {
            var grid = try MarkdownTableGrid(parsing: "A|B\n---|---\n1|2|3\n4|5")
            let deletedRow = grid.deleteRow(at: 0)
            #expect(deletedRow)
            let serialized = grid.serialized()

            #expect(serialized == "A|B||\n---|---|---\n4|5")
            #expect(MarkdownDocument(source: serialized).blocks.map(\.kind) == [.table])
            #expect(try MarkdownTableGrid(parsing: serialized) == grid)
        }

        do {
            var document = MarkdownDocument(source: "A|B\n---|---\n1|2|3")
            let tableID = try #require(document.blocks.first?.id)
            var grid = try document.tableGrid(for: tableID)
            grid.addColumn(header: "D", defaultCell: "4", alignment: .right)
            let deletedColumn = grid.deleteColumn(at: grid.columnCount - 1)
            #expect(deletedColumn)
            try document.replaceTable(blockID: tableID, with: grid)

            #expect(document.blocks.map(\.kind) == [.table])
            #expect(try document.tableGrid(for: tableID) == grid)
            #expect(grid.columnCount == 3)
        }

        do {
            var document = MarkdownDocument(source: "A|B\n---|---\n1|2|3")
            let tableID = try #require(document.blocks.first?.id)
            var grid = try document.tableGrid(for: tableID)
            let deletedRow = grid.deleteRow(at: 0)
            #expect(deletedRow)
            try document.replaceTable(blockID: tableID, with: grid)

            #expect(document.blocks.map(\.kind) == [.table])
            let committed = try document.tableGrid(for: tableID)
            #expect(committed.header == grid.header)
            #expect(committed.rows == grid.rows)
            #expect(committed.alignments == grid.alignments)
            #expect(try MarkdownTableGrid(parsing: document.source) == grid)
            #expect(grid.columnCount == 3)
        }
    }

    @Test("row append deletion survives source and Codable reconstruction")
    func rowAppendDeletionSurvivesReconstruction() throws {
        let source = "A|B\n---|---\n1|2|3"

        var sourceGrid = try MarkdownTableGrid(parsing: source)
        sourceGrid.addRow(["4", "5", "6"])
        var reparsed = try MarkdownTableGrid(parsing: sourceGrid.serialized())
        let deletedReparsedRow = reparsed.deleteRow(at: reparsed.rows.count - 1)
        #expect(deletedReparsedRow)
        #expect(reparsed.serialized() == source)

        var codableGrid = try MarkdownTableGrid(parsing: source)
        codableGrid.addRow(["4", "5", "6"])
        let encoded = try JSONEncoder().encode(codableGrid)
        var decoded = try JSONDecoder().decode(MarkdownTableGrid.self, from: encoded)
        let deletedDecodedRow = decoded.deleteRow(at: decoded.rows.count - 1)
        #expect(deletedDecodedRow)
        #expect(decoded.serialized() == source)

        for terminatedSource in [
            "A|B\r\n---|---\r\n1|2|3\r",
            "A|B\n---|---\n1|2|3\r\n",
        ] {
            var grid = try MarkdownTableGrid(parsing: terminatedSource)
            grid.addRow(["4", "5", "6"])
            var reconstructed = try MarkdownTableGrid(parsing: grid.serialized())
            let deletedRow = reconstructed.deleteRow(at: reconstructed.rows.count - 1)
            #expect(deletedRow)
            #expect(reconstructed.serialized() == terminatedSource)
        }

        for deletionOrder in [[2, 1], [1, 1]] {
            var grid = try MarkdownTableGrid(parsing: source)
            grid.addRow(["4", "5", "6"])
            grid.addRow(["7", "8", "9"])
            var reconstructed = try MarkdownTableGrid(parsing: grid.serialized())
            for index in deletionOrder {
                let deletedRow = reconstructed.deleteRow(at: index)
                #expect(deletedRow)
            }
            #expect(reconstructed.serialized() == source)
        }
    }

    @Test("shared fence syntax handles long, tilde, mismatched, and unclosed fences")
    func sharedFenceSyntax() throws {
        let longFence = "````swift\nalpha\n```\nomega\n`````"
        let longDocument = MarkdownDocument(source: longFence)
        let longContent = try #require(MarkdownFenceSyntax.content(in: longFence))

        #expect(longDocument.blocks.map(\.kind) == [.code])
        #expect(longContent.language == "swift")
        #expect(longContent.code == "alpha\n```\nomega")

        let tilde = "~~~~ objc\nvalue\n~~~~~~"
        let tildeContent = try #require(MarkdownFenceSyntax.content(in: tilde))
        #expect(MarkdownDocument(source: tilde).blocks.map(\.kind) == [.code])
        #expect(tildeContent.language == "objc")
        #expect(tildeContent.code == "value")

        let unclosed = "````text\nbody\n~~~"
        let unclosedContent = try #require(MarkdownFenceSyntax.content(in: unclosed))
        #expect(MarkdownDocument(source: unclosed).blocks.map(\.kind) == [.code])
        #expect(unclosedContent.code == "body\n~~~")

        for ending in ["\n", "\r\n", "\r"] {
            let trailing = "````text" + ending + "body" + ending
            #expect(MarkdownFenceSyntax.content(in: trailing)?.code == "body" + ending)
        }
    }

    @Test("table operations maintain a rectangular grid and one-column minimum")
    func tableOperations() throws {
        var grid = MarkdownTableGrid(
            header: ["A", "B"],
            rows: [["1", "2"]],
            alignments: [.left, .right]
        )

        try grid.setHeader(column: 0, value: "Alpha")
        try grid.setCell(row: 0, column: 1, value: "two|parts")
        grid.addRow(["3"])
        grid.addColumn(header: "C", defaultCell: "default", alignment: .left)
        let cycled = try grid.cycleAlignment(at: 2)

        #expect(cycled == .center)
        #expect(grid.header == ["Alpha", "B", "C"])
        #expect(grid.rows == [
            ["1", "two|parts", "default"],
            ["3", "", "default"],
        ])
        #expect(grid.alignments == [.left, .right, .center])
        #expect(grid.serialized().contains("two\\|parts"))

        let deletedRow = grid.deleteRow(at: 0)
        let deletedSecondColumn = grid.deleteColumn(at: 1)
        #expect(deletedRow)
        #expect(deletedSecondColumn)
        #expect(grid.columnCount == 2)
        #expect(grid.rows.allSatisfy { $0.count == 2 })
        let deletedFirstColumn = grid.deleteColumn(at: 0)
        #expect(deletedFirstColumn)
        #expect(grid.columnCount == 1)
        let deletedLastColumn = grid.deleteColumn(at: 0)
        #expect(!deletedLastColumn)
        #expect(grid.columnCount == 1)

        let reparsed = try MarkdownTableGrid(parsing: grid.serialized())
        #expect(reparsed == grid)
    }

    @Test("table cell codec round trips backslash runs immediately before pipes")
    func tableBackslashPipeRoundTrip() throws {
        let values = [#"\|"#, #"\\|"#, #"\\\|"#]
        let grid = MarkdownTableGrid(
            header: ["One", "Two", "Three"],
            rows: [values]
        )

        let reparsed = try MarkdownTableGrid(parsing: grid.serialized())

        #expect(reparsed == grid)
        #expect(reparsed.rows == [values])
    }

    @Test("table serializer preserves outer-pipe style and final CR")
    func tableSurfaceSyntax() throws {
        let source = "Name | Value\r--- | :---:\rA | B\r"
        let grid = try MarkdownTableGrid(parsing: source)

        #expect(!grid.hasLeadingPipe)
        #expect(!grid.hasTrailingPipe)
        #expect(grid.lineEnding == "\r")
        #expect(grid.serialized() == source)
    }

    @Test("committing a grid keeps table and neighboring block IDs stable")
    func tableDocumentIntegration() throws {
        let source = "before\n\n| A | B |\n| --- | :---: |\n| 1 | 2 |\n\nafter"
        var document = MarkdownDocument(source: source)
        let beforeBlocks = document.blocks
        let tableID = beforeBlocks[1].id
        var grid = try document.tableGrid(for: tableID)

        try grid.setCell(row: 0, column: 1, value: "changed")
        grid.addRow(["3", "4"])
        try document.replaceTable(blockID: tableID, with: grid)

        #expect(document.blocks[0] == beforeBlocks[0])
        #expect(document.blocks[1].id == tableID)
        #expect(document.blocks[1].kind == .table)
        #expect(document.blocks[2] == beforeBlocks[2])
        #expect(document.source.hasPrefix("before\n\n"))
        #expect(document.source.hasSuffix("\n\nafter"))
        #expect(try document.tableGrid(for: tableID) == grid)
    }

    @Test("authoritative format fixture is a lossless document")
    func authoritativeFixtureRoundTrip() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repository = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = try String(
            contentsOf: repository.appendingPathComponent("ui/格式示例.md"),
            encoding: .utf8
        )
        let document = MarkdownDocument(source: fixture)

        #expect(fixture.utf8.count == 3470)
        #expect(fixture.components(separatedBy: "\n").count == 113)
        #expect(document.source == fixture)
        #expect(Array(document.source.utf8) == Array(fixture.utf8))
        #expect(Set(document.blocks.map(\.kind)) == Set(MarkdownBlockKind.allCases))
    }
}
