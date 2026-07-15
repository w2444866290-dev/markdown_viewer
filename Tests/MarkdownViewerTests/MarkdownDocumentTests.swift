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

        #expect(document.source == "- one\r\n\r\n- three")
        #expect(document.blocks.map(\.id) == [firstID, emptyID, followingID])
        #expect(document.blocks[1].kind == .paragraph)
        #expect(document.blocks[1].source.isEmpty)
        #expect(document.blocks[1].leadingTrivia == "\r\n\r\n")
        #expect(document.blocks[2].leadingTrivia.isEmpty)
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
        let fixture = try formatFixtureFromAuthoritativeUI()
        let document = MarkdownDocument(source: fixture)

        #expect(fixture.utf8.count == 3470)
        #expect(fixture.components(separatedBy: "\n").count == 113)
        #expect(document.source == fixture)
        #expect(Array(document.source.utf8) == Array(fixture.utf8))
        #expect(Set(document.blocks.map(\.kind)) == Set(MarkdownBlockKind.allCases))
    }

    // MARK: - Authoritative fixture extraction

    private func formatFixtureFromAuthoritativeUI() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repository = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let uiURL = repository.appendingPathComponent("ui/Markdown Viewer.dc.html")
        let html = try String(contentsOf: uiURL, encoding: .utf8)
        let marker = "    '格式示例.md': ["
        let terminator = "    ].join('\\n'),"
        let start = try #require(html.range(of: marker)?.upperBound)
        let tail = html[start...]
        let end = try #require(tail.range(of: terminator)?.lowerBound)
        let arrayBody = tail[..<end]
        let values = try arrayBody
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(decodeSingleQuotedJavaScriptLine)
        return values.joined(separator: "\n")
    }

    private func decodeSingleQuotedJavaScriptLine(_ line: String) throws -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("'"), trimmed.hasSuffix("',") else {
            throw FixtureExtractionError.invalidLine(line)
        }
        let literal = trimmed.dropFirst().dropLast(2)
        var output = ""
        var iterator = literal.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                output.append(character)
                continue
            }
            guard let escaped = iterator.next() else {
                throw FixtureExtractionError.invalidLine(line)
            }
            switch escaped {
            case "\\": output.append("\\")
            case "'": output.append("'")
            case "n": output.append("\n")
            case "r": output.append("\r")
            case "t": output.append("\t")
            default: output.append(escaped)
            }
        }
        return output
    }

    private enum FixtureExtractionError: Error {
        case invalidLine(String)
    }
}
