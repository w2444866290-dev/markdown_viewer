import Foundation

/// The durable block categories understood by the native document model.
enum MarkdownBlockKind: String, Codable, CaseIterable, Sendable {
    case heading
    case paragraph
    case quote
    case list
    case code
    case table
    case image
    case horizontalRule
    case footnotes
}

/// One lossless source block.
///
/// `source` excludes trivia between this block and the preceding block.
/// `leadingTrivia` owns that exact inter-block text, including its original line
/// terminators and whitespace-only lines. The document owns the trivia after the
/// final block. This division lets an untouched document serialize exactly while
/// a block replacement can leave every unrelated source slice unchanged.
struct MarkdownBlock: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let kind: MarkdownBlockKind
    let source: String
    let leadingTrivia: String

    fileprivate func replacingLeadingTrivia(_ trivia: String) -> MarkdownBlock {
        MarkdownBlock(id: id, kind: kind, source: source, leadingTrivia: trivia)
    }
}

enum MarkdownDocumentError: Error, Equatable {
    case blockNotFound(UUID)
    case cannotMerge(UUID)
    case invalidUTF16Offset(Int)
    case notTableBlock(UUID)
    case taskNotFound(UUID, Int)
}

/// A lossless Markdown document made of stable-ID source blocks.
///
/// Parsing never normalizes line endings, blank lines, indentation, fences, or a
/// final newline. Mutations reparse only the source slice explicitly replaced.
struct MarkdownDocument: Codable, Equatable, Sendable {
    private(set) var blocks: [MarkdownBlock]
    private(set) var trailingTrivia: String

    init(source: String) {
        let parsed = Self.parse(source)
        var used = Set<UUID>()
        blocks = parsed.blocks.map { block in
            var id = UUID()
            while used.contains(id) { id = UUID() }
            used.insert(id)
            return MarkdownBlock(
                id: id,
                kind: block.kind,
                source: block.source,
                leadingTrivia: block.leadingTrivia
            )
        }
        trailingTrivia = parsed.trailingTrivia
    }

    /// Exact source reconstruction. For an untouched document this is byte-for-byte
    /// identical after UTF-8 encoding to the string passed to `init(source:)`.
    var source: String {
        var pieces: [String] = []
        pieces.reserveCapacity(blocks.count * 2 + 1)
        for block in blocks {
            pieces.append(block.leadingTrivia)
            pieces.append(block.source)
        }
        pieces.append(trailingTrivia)
        return pieces.joined()
    }

    /// Re-detects the semantic kind of one live source-editor draft.
    ///
    /// A block may change type before it is committed, such as when a paragraph
    /// draft becomes `- item`. Keyboard commands must follow that current source
    /// instead of the kind captured when editing began.
    static func inferredBlockKind(forDraft source: String) -> MarkdownBlockKind {
        standaloneKind(of: source)
    }

    /// The first line terminator present in the document, or LF for a single-line
    /// document. Editing primitives use this when no explicit separator is supplied.
    var preferredLineEnding: String {
        losslessLines(source).first(where: { !$0.terminator.isEmpty })?.terminator ?? "\n"
    }

    func block(id: UUID) -> MarkdownBlock? {
        blocks.first { $0.id == id }
    }

    /// Replace and locally reparse exactly one block source.
    ///
    /// The original ID is assigned to the first replacement block. Additional
    /// replacement blocks receive fresh IDs, and every unrelated block keeps its ID.
    /// Leading/trailing trivia supplied in `newSource` is preserved in addition to
    /// the existing trivia outside the edited slice.
    @discardableResult
    mutating func replaceBlock(id: UUID, with newSource: String) throws -> [UUID] {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else {
            throw MarkdownDocumentError.blockNotFound(id)
        }
        return replaceBlockRange(index..<(index + 1), with: newSource, retaining: id)
    }

    /// Split one block at a UTF-16 offset, retaining the original ID on the left and
    /// assigning a fresh ID to the right. The explicit separator is inserted exactly.
    @discardableResult
    mutating func splitBlock(
        id: UUID,
        atUTF16Offset offset: Int,
        separator: String
    ) throws -> UUID {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else {
            throw MarkdownDocumentError.blockNotFound(id)
        }
        let original = blocks[index]
        let halves = try Self.split(original.source, atUTF16Offset: offset)
        let existingIDs = Set(blocks.map(\.id))
        var rightID = UUID()
        while existingIDs.contains(rightID) { rightID = UUID() }

        let left = MarkdownBlock(
            id: original.id,
            kind: Self.standaloneKind(of: halves.left),
            source: halves.left,
            leadingTrivia: original.leadingTrivia
        )
        let right = MarkdownBlock(
            id: rightID,
            kind: Self.standaloneKind(of: halves.right),
            source: halves.right,
            leadingTrivia: separator
        )
        blocks.replaceSubrange(index..<(index + 1), with: [left, right])
        return rightID
    }

    /// Split using a blank line written in the document's existing line-ending style.
    @discardableResult
    mutating func splitBlock(id: UUID, atUTF16Offset offset: Int) throws -> UUID {
        let ending = preferredLineEnding
        return try splitBlock(id: id, atUTF16Offset: offset, separator: ending + ending)
    }

    /// Merge the selected block into its predecessor. The predecessor keeps its ID.
    @discardableResult
    mutating func mergeBlockWithPrevious(id: UUID, separator: String = "") throws -> UUID {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else {
            throw MarkdownDocumentError.blockNotFound(id)
        }
        guard index > 0 else { throw MarkdownDocumentError.cannotMerge(id) }
        let retained = blocks[index - 1].id
        let combined = blocks[index - 1].source + separator + blocks[index].source
        _ = replaceBlockRange((index - 1)..<(index + 1), with: combined, retaining: retained)
        return retained
    }

    /// Merge the following block into the selected block. The selected block keeps
    /// its ID.
    @discardableResult
    mutating func mergeBlockWithNext(id: UUID, separator: String = "") throws -> UUID {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else {
            throw MarkdownDocumentError.blockNotFound(id)
        }
        guard index + 1 < blocks.count else { throw MarkdownDocumentError.cannotMerge(id) }
        let combined = blocks[index].source + separator + blocks[index + 1].source
        _ = replaceBlockRange(index..<(index + 2), with: combined, retaining: id)
        return id
    }

    /// Insert a source-empty paragraph immediately after a block while preserving
    /// the exact serialized bytes already separating the surrounding content.
    /// This represents the caret line created when an empty list or quote item exits
    /// its container, even though an empty paragraph has no source characters.
    @discardableResult
    mutating func insertEmptyParagraph(after id: UUID) throws -> UUID {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else {
            throw MarkdownDocumentError.blockNotFound(id)
        }
        let paragraphID = UUID()
        let insertionIndex = index + 1
        let leadingTrivia: String
        if blocks.indices.contains(insertionIndex) {
            let following = blocks[insertionIndex]
            leadingTrivia = following.leadingTrivia
            blocks[insertionIndex] = following.replacingLeadingTrivia("")
        } else {
            leadingTrivia = trailingTrivia
            trailingTrivia = ""
        }
        blocks.insert(
            MarkdownBlock(
                id: paragraphID,
                kind: .paragraph,
                source: "",
                leadingTrivia: leadingTrivia
            ),
            at: insertionIndex
        )
        return paragraphID
    }

    /// Toggle the Nth task marker in a list block. Blank markers become lowercase
    /// `x`; both lowercase and uppercase checked markers become blank.
    @discardableResult
    mutating func toggleTask(blockID: UUID, itemIndex: Int) throws -> Bool {
        guard let block = block(id: blockID) else {
            throw MarkdownDocumentError.blockNotFound(blockID)
        }
        guard block.kind == .list else {
            throw MarkdownDocumentError.taskNotFound(blockID, itemIndex)
        }
        let full = NSRange(location: 0, length: (block.source as NSString).length)
        let matches = Self.taskRegex.matches(in: block.source, range: full)
        guard matches.indices.contains(itemIndex) else {
            throw MarkdownDocumentError.taskNotFound(blockID, itemIndex)
        }
        let markerRange = matches[itemIndex].range(at: 1)
        let mutable = NSMutableString(string: block.source)
        let wasChecked = mutable.substring(with: markerRange).lowercased() == "x"
        mutable.replaceCharacters(in: markerRange, with: wasChecked ? " " : "x")
        _ = try replaceBlock(id: blockID, with: mutable as String)
        return !wasChecked
    }

    func tableGrid(for blockID: UUID) throws -> MarkdownTableGrid {
        guard let block = block(id: blockID) else {
            throw MarkdownDocumentError.blockNotFound(blockID)
        }
        guard block.kind == .table else {
            throw MarkdownDocumentError.notTableBlock(blockID)
        }
        return try MarkdownTableGrid(parsing: block.source)
    }

    /// Commit an edited table grid through the same local replacement path.
    mutating func replaceTable(blockID: UUID, with grid: MarkdownTableGrid) throws {
        _ = try replaceBlock(id: blockID, with: grid.serialized())
    }

    // MARK: - Local replacement

    @discardableResult
    private mutating func replaceBlockRange(
        _ range: Range<Int>,
        with newSource: String,
        retaining retainedID: UUID
    ) -> [UUID] {
        let fragment = Self.parse(newSource)
        let originalLeading = blocks[range.lowerBound].leadingTrivia
        var usedIDs = Set(blocks.map(\.id))
        usedIDs.subtract(blocks[range].map(\.id))
        usedIDs.insert(retainedID)

        var replacements: [MarkdownBlock] = []
        replacements.reserveCapacity(fragment.blocks.count)
        for (offset, parsed) in fragment.blocks.enumerated() {
            let id: UUID
            if offset == 0 {
                id = retainedID
            } else {
                var candidate = UUID()
                while usedIDs.contains(candidate) { candidate = UUID() }
                usedIDs.insert(candidate)
                id = candidate
            }
            replacements.append(MarkdownBlock(
                id: id,
                kind: parsed.kind,
                source: parsed.source,
                leadingTrivia: offset == 0
                    ? originalLeading + parsed.leadingTrivia
                    : parsed.leadingTrivia
            ))
        }

        if range.upperBound < blocks.count {
            let suffix = blocks[range.upperBound]
            blocks[range.upperBound] = suffix.replacingLeadingTrivia(
                fragment.trailingTrivia + suffix.leadingTrivia
            )
        } else {
            trailingTrivia = fragment.trailingTrivia + trailingTrivia
        }

        blocks.replaceSubrange(range, with: replacements)
        return replacements.map(\.id)
    }

    // MARK: - Lossless parsing

    private struct ParsedBlock {
        let kind: MarkdownBlockKind
        let source: String
        let leadingTrivia: String
    }

    private struct ParsedDocument {
        let blocks: [ParsedBlock]
        let trailingTrivia: String
    }

    private struct BlockRange {
        let kind: MarkdownBlockKind
        let lines: Range<Int>
    }

    private static let headingRegex = try! NSRegularExpression(
        pattern: "^[ \\t]{0,3}#{1,6}(?:[ \\t]+|$)"
    )
    private static let listRegex = try! NSRegularExpression(
        pattern: "^[ \\t]{0,12}(?:[-+*]|(?:[0-9]+|[A-Za-z]+)[.)])[ \\t]+"
    )
    private static let footnoteRegex = try! NSRegularExpression(
        pattern: "^[ \\t]*\\[\\^[^\\]]+\\]:"
    )
    private static let imageRegex = try! NSRegularExpression(
        pattern: "^[ \\t]*!\\[[^\\]]*\\]\\([^\\r\\n]+\\)[ \\t]*$"
    )
    private static let taskRegex = try! NSRegularExpression(
        pattern: "^[ \\t]*(?:[-+*]|(?:[0-9]+|[A-Za-z]+)[.)])[ \\t]+\\[([ xX])\\]",
        options: [.anchorsMatchLines]
    )

    private static func parse(_ source: String) -> ParsedDocument {
        let lines = losslessLines(source)
        let ranges = blockRanges(in: lines)

        // A blank document still exposes one editable paragraph block. Its complete
        // text is leading trivia, so exact serialization remains possible.
        guard !ranges.isEmpty else {
            return ParsedDocument(
                blocks: [ParsedBlock(kind: .paragraph, source: "", leadingTrivia: source)],
                trailingTrivia: ""
            )
        }

        var parsed: [ParsedBlock] = []
        parsed.reserveCapacity(ranges.count)
        var previousEnd: Int?
        for blockRange in ranges {
            let leading: String
            if let previousEnd {
                var pieces: [String] = [lines[previousEnd - 1].terminator]
                for index in previousEnd..<blockRange.lines.lowerBound {
                    pieces.append(lines[index].raw)
                }
                leading = pieces.joined()
            } else {
                leading = lines[..<blockRange.lines.lowerBound].map(\.raw).joined()
            }

            var sourcePieces: [String] = []
            sourcePieces.reserveCapacity(blockRange.lines.count * 2)
            for index in blockRange.lines {
                sourcePieces.append(lines[index].content)
                if index < blockRange.lines.upperBound - 1 {
                    sourcePieces.append(lines[index].terminator)
                }
            }
            parsed.append(ParsedBlock(
                kind: blockRange.kind,
                source: sourcePieces.joined(),
                leadingTrivia: leading
            ))
            previousEnd = blockRange.lines.upperBound
        }

        let lastEnd = ranges[ranges.count - 1].lines.upperBound
        var trailingPieces: [String] = [lines[lastEnd - 1].terminator]
        for index in lastEnd..<lines.count {
            trailingPieces.append(lines[index].raw)
        }
        return ParsedDocument(blocks: parsed, trailingTrivia: trailingPieces.joined())
    }

    private static func blockRanges(in lines: [LosslessSourceLine]) -> [BlockRange] {
        var result: [BlockRange] = []
        var index = 0
        while index < lines.count {
            if isBlank(lines[index].content) {
                index += 1
                continue
            }

            let kind = startingKind(at: index, in: lines) ?? .paragraph
            let end: Int
            switch kind {
            case .heading, .image, .horizontalRule:
                end = index + 1
            case .code:
                end = codeBlockEnd(startingAt: index, in: lines)
            case .table:
                var cursor = index + 2
                while cursor < lines.count,
                      !isBlank(lines[cursor].content),
                      MarkdownTableSyntax.containsUnescapedPipe(lines[cursor].content) {
                    cursor += 1
                }
                end = cursor
            case .quote:
                var cursor = index + 1
                while cursor < lines.count,
                      !isBlank(lines[cursor].content),
                      isQuote(lines[cursor].content) {
                    cursor += 1
                }
                end = cursor
            case .footnotes:
                var cursor = index + 1
                while cursor < lines.count, !isBlank(lines[cursor].content) {
                    if isFootnote(lines[cursor].content)
                        || leadingWhitespaceWidth(lines[cursor].content) >= 2 {
                        cursor += 1
                    } else {
                        break
                    }
                }
                end = cursor
            case .list:
                var cursor = index + 1
                while cursor < lines.count, !isBlank(lines[cursor].content) {
                    if isList(lines[cursor].content)
                        || leadingWhitespaceWidth(lines[cursor].content) > 0 {
                        cursor += 1
                        continue
                    }
                    if startingKind(at: cursor, in: lines) != nil { break }
                    // CommonMark permits a lazy, non-indented continuation line.
                    cursor += 1
                }
                end = cursor
            case .paragraph:
                var cursor = index + 1
                while cursor < lines.count,
                      !isBlank(lines[cursor].content),
                      startingKind(at: cursor, in: lines) == nil {
                    cursor += 1
                }
                end = cursor
            }
            result.append(BlockRange(kind: kind, lines: index..<end))
            index = end
        }
        return result
    }

    private static func startingKind(
        at index: Int,
        in lines: [LosslessSourceLine]
    ) -> MarkdownBlockKind? {
        let line = lines[index].content
        if openingFence(in: line) != nil { return .code }
        if isHorizontalRule(line) { return .horizontalRule }
        if matches(headingRegex, line) { return .heading }
        if index + 1 < lines.count,
           MarkdownTableSyntax.isHeader(line, separator: lines[index + 1].content) {
            return .table
        }
        if isFootnote(line) { return .footnotes }
        if isQuote(line) { return .quote }
        if isList(line) { return .list }
        if matches(imageRegex, line) { return .image }
        return nil
    }

    private static func codeBlockEnd(
        startingAt index: Int,
        in lines: [LosslessSourceLine]
    ) -> Int {
        guard let opening = openingFence(in: lines[index].content) else { return index + 1 }
        var cursor = index + 1
        while cursor < lines.count {
            if isClosingFence(lines[cursor].content, matching: opening) {
                return cursor + 1
            }
            cursor += 1
        }
        return lines.count
    }

    private static func standaloneKind(of source: String) -> MarkdownBlockKind {
        parse(source).blocks.first?.kind ?? .paragraph
    }

    private static func split(
        _ source: String,
        atUTF16Offset offset: Int
    ) throws -> (left: String, right: String) {
        guard offset >= 0,
              let utf16Index = source.utf16.index(
                source.utf16.startIndex,
                offsetBy: offset,
                limitedBy: source.utf16.endIndex
              ),
              let stringIndex = String.Index(utf16Index, within: source) else {
            throw MarkdownDocumentError.invalidUTF16Offset(offset)
        }
        return (
            String(source[..<stringIndex]),
            String(source[stringIndex...])
        )
    }

    private static func matches(_ regex: NSRegularExpression, _ source: String) -> Bool {
        regex.firstMatch(
            in: source,
            range: NSRange(location: 0, length: (source as NSString).length)
        ) != nil
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func isFootnote(_ line: String) -> Bool {
        matches(footnoteRegex, line)
    }

    private static func isQuote(_ line: String) -> Bool {
        line.drop(while: { $0 == " " || $0 == "\t" }).first == ">"
    }

    private static func isList(_ line: String) -> Bool {
        matches(listRegex, line)
    }

    private static func leadingWhitespaceWidth(_ line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " { width += 1 }
            else if character == "\t" { width += 4 }
            else { break }
        }
        return width
    }

    private struct Fence: Equatable {
        let marker: Character
        let count: Int
    }

    private static func openingFence(in line: String) -> Fence? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let count = trimmed.prefix(while: { $0 == first }).count
        guard count >= 3 else { return nil }
        return Fence(marker: first, count: count)
    }

    private static func isClosingFence(_ line: String, matching fence: Fence) -> Bool {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        let markerCount = trimmed.prefix(while: { $0 == fence.marker }).count
        guard markerCount >= fence.count else { return false }
        return trimmed.dropFirst(markerCount).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let compact = line.filter { $0 != " " && $0 != "\t" }
        guard compact.count >= 3, let marker = compact.first,
              marker == "-" || marker == "*" || marker == "_" else { return false }
        return compact.allSatisfy { $0 == marker }
    }
}

// MARK: - Table grid

enum MarkdownTableAlignment: String, Codable, CaseIterable, Sendable {
    case left
    case center
    case right

    var next: MarkdownTableAlignment {
        switch self {
        case .left: return .center
        case .center: return .right
        case .right: return .left
        }
    }
}

enum MarkdownTableError: Error, Equatable {
    case invalidTable
    case rowOutOfBounds(Int)
    case columnOutOfBounds(Int)
}

/// A native two-dimensional editing model for one Markdown table block.
///
/// The original block source remains untouched until this grid is committed. Once
/// edited, `serialized()` emits stable, conventional Markdown while preserving the
/// table's line-ending style, outer-pipe style, and final-newline state.
struct MarkdownTableGrid: Codable, Equatable, Sendable {
    private(set) var header: [String]
    private(set) var rows: [[String]]
    private(set) var alignments: [MarkdownTableAlignment]
    private(set) var lineEnding: String
    private(set) var hasLeadingPipe: Bool
    private(set) var hasTrailingPipe: Bool
    private(set) var finalLineEnding: String

    var columnCount: Int { header.count }

    init(
        header: [String],
        rows: [[String]] = [],
        alignments: [MarkdownTableAlignment] = [],
        lineEnding: String = "\n",
        hasLeadingPipe: Bool = true,
        hasTrailingPipe: Bool = true,
        finalLineEnding: String = ""
    ) {
        let count = max(1, header.count, alignments.count, rows.map(\.count).max() ?? 0)
        self.header = Self.padded(header, to: count)
        self.rows = rows.map { Self.padded($0, to: count) }
        self.alignments = Self.paddedAlignments(alignments, to: count)
        self.lineEnding = lineEnding.isEmpty ? "\n" : lineEnding
        self.hasLeadingPipe = hasLeadingPipe
        self.hasTrailingPipe = hasTrailingPipe
        self.finalLineEnding = finalLineEnding
    }

    init(parsing source: String) throws {
        let lines = losslessLines(source)
        guard lines.count >= 2,
              lines.allSatisfy({ !$0.content.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw MarkdownTableError.invalidTable
        }
        let parsedHeader = MarkdownTableSyntax.parseRow(lines[0].content)
        let parsedSeparator = MarkdownTableSyntax.parseRow(lines[1].content)
        guard !parsedHeader.cells.isEmpty,
              parsedSeparator.cells.allSatisfy({ MarkdownTableSyntax.alignment(for: $0) != nil }) else {
            throw MarkdownTableError.invalidTable
        }

        let body = lines.dropFirst(2).map { MarkdownTableSyntax.parseRow($0.content).cells }
        let count = max(
            1,
            parsedHeader.cells.count,
            parsedSeparator.cells.count,
            body.map(\.count).max() ?? 0
        )
        header = Self.padded(parsedHeader.cells, to: count)
        rows = body.map { Self.padded($0, to: count) }
        alignments = Self.paddedAlignments(
            parsedSeparator.cells.compactMap(MarkdownTableSyntax.alignment(for:)),
            to: count
        )
        lineEnding = lines.first(where: { !$0.terminator.isEmpty })?.terminator ?? "\n"
        hasLeadingPipe = parsedHeader.hasLeadingPipe
        hasTrailingPipe = parsedHeader.hasTrailingPipe
        finalLineEnding = lines.last?.terminator ?? ""
    }

    mutating func setHeader(column: Int, value: String) throws {
        guard header.indices.contains(column) else {
            throw MarkdownTableError.columnOutOfBounds(column)
        }
        header[column] = value
    }

    mutating func setCell(row: Int, column: Int, value: String) throws {
        guard rows.indices.contains(row) else {
            throw MarkdownTableError.rowOutOfBounds(row)
        }
        guard header.indices.contains(column) else {
            throw MarkdownTableError.columnOutOfBounds(column)
        }
        rows[row][column] = value
    }

    mutating func addRow(_ values: [String] = []) {
        rows.append(Self.padded(values, to: columnCount))
    }

    @discardableResult
    mutating func deleteRow(at index: Int) -> Bool {
        guard rows.indices.contains(index) else { return false }
        rows.remove(at: index)
        return true
    }

    mutating func addColumn(
        header headerValue: String = "",
        defaultCell: String = "",
        alignment: MarkdownTableAlignment = .left
    ) {
        header.append(headerValue)
        alignments.append(alignment)
        for index in rows.indices { rows[index].append(defaultCell) }
    }

    /// Delete a column while enforcing the invariant that a table always has one.
    @discardableResult
    mutating func deleteColumn(at index: Int) -> Bool {
        guard columnCount > 1, header.indices.contains(index) else { return false }
        header.remove(at: index)
        alignments.remove(at: index)
        for row in rows.indices { rows[row].remove(at: index) }
        return true
    }

    @discardableResult
    mutating func cycleAlignment(at column: Int) throws -> MarkdownTableAlignment {
        guard alignments.indices.contains(column) else {
            throw MarkdownTableError.columnOutOfBounds(column)
        }
        alignments[column] = alignments[column].next
        return alignments[column]
    }

    func serialized() -> String {
        let forceOuterPipes = columnCount == 1
        let leading = hasLeadingPipe || forceOuterPipes
        let trailing = hasTrailingPipe || forceOuterPipes
        var output: [String] = []
        output.reserveCapacity(rows.count + 2)
        output.append(Self.renderRow(header, leading: leading, trailing: trailing))
        output.append(Self.renderRow(
            alignments.map { alignment in
                switch alignment {
                case .left: return "---"
                case .center: return ":---:"
                case .right: return "---:"
                }
            },
            leading: leading,
            trailing: trailing
        ))
        for row in rows {
            output.append(Self.renderRow(row, leading: leading, trailing: trailing))
        }
        return output.joined(separator: lineEnding) + finalLineEnding
    }

    private static func padded(_ values: [String], to count: Int) -> [String] {
        if values.count >= count { return Array(values.prefix(count)) }
        return values + Array(repeating: "", count: count - values.count)
    }

    private static func paddedAlignments(
        _ values: [MarkdownTableAlignment],
        to count: Int
    ) -> [MarkdownTableAlignment] {
        if values.count >= count { return Array(values.prefix(count)) }
        return values + Array(repeating: .left, count: count - values.count)
    }

    private static func renderRow(
        _ cells: [String],
        leading: Bool,
        trailing: Bool
    ) -> String {
        let body = cells.map(MarkdownTableSyntax.escapeCell).joined(separator: " | ")
        return (leading ? "| " : "") + body + (trailing ? " |" : "")
    }
}

// MARK: - Lossless line scanning

fileprivate struct LosslessSourceLine {
    let content: String
    let terminator: String

    var raw: String { content + terminator }
}

/// Split a Swift string without normalizing CRLF, CR, LF, or a missing final newline.
fileprivate func losslessLines(_ source: String) -> [LosslessSourceLine] {
    let text = source as NSString
    guard text.length > 0 else { return [] }
    var result: [LosslessSourceLine] = []
    var lineStart = 0
    var cursor = 0
    while cursor < text.length {
        let character = text.character(at: cursor)
        guard character == 0x0A || character == 0x0D else {
            cursor += 1
            continue
        }
        let content = text.substring(
            with: NSRange(location: lineStart, length: cursor - lineStart)
        )
        let terminator: String
        if character == 0x0D,
           cursor + 1 < text.length,
           text.character(at: cursor + 1) == 0x0A {
            terminator = "\r\n"
            cursor += 2
        } else {
            terminator = character == 0x0D ? "\r" : "\n"
            cursor += 1
        }
        result.append(LosslessSourceLine(content: content, terminator: terminator))
        lineStart = cursor
    }
    if lineStart < text.length {
        result.append(LosslessSourceLine(
            content: text.substring(from: lineStart),
            terminator: ""
        ))
    }
    return result
}

// MARK: - Shared table syntax

fileprivate enum MarkdownTableSyntax {
    struct ParsedRow {
        let cells: [String]
        let hasLeadingPipe: Bool
        let hasTrailingPipe: Bool
    }

    static func isHeader(_ header: String, separator: String) -> Bool {
        guard containsUnescapedPipe(header) || containsUnescapedPipe(separator) else {
            return false
        }
        let headerCells = parseRow(header).cells
        let separatorCells = parseRow(separator).cells
        return !headerCells.isEmpty
            && headerCells.count == separatorCells.count
            && separatorCells.allSatisfy { alignment(for: $0) != nil }
    }

    static func alignment(for separatorCell: String) -> MarkdownTableAlignment? {
        let trimmed = separatorCell.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let leftColon = trimmed.first == ":"
        let rightColon = trimmed.last == ":"
        let core = trimmed.dropFirst(leftColon ? 1 : 0).dropLast(rightColon ? 1 : 0)
        guard core.count >= 3, core.allSatisfy({ $0 == "-" }) else { return nil }
        if leftColon && rightColon { return .center }
        if rightColon { return .right }
        return .left
    }

    static func parseRow(_ line: String) -> ParsedRow {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let leading = trimmed.first == "|"
        let trailing = endsWithUnescapedPipe(trimmed)
        var cells: [String] = []
        var current = ""
        var iterator = trimmed.makeIterator()
        while let character = iterator.next() {
            if character == "\\" {
                if let next = iterator.next() {
                    if next == "|" {
                        current.append("|")
                    } else if next == "\\" {
                        current.append("\\")
                    } else {
                        current.append("\\")
                        current.append(next)
                    }
                } else {
                    current.append("\\")
                }
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        if leading, !cells.isEmpty { cells.removeFirst() }
        if trailing, !cells.isEmpty { cells.removeLast() }
        if cells.isEmpty { cells = [""] }
        return ParsedRow(cells: cells, hasLeadingPipe: leading, hasTrailingPipe: trailing)
    }

    static func containsUnescapedPipe(_ line: String) -> Bool {
        var escaped = false
        for character in line {
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                return true
            }
        }
        return false
    }

    static func escapeCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
    }

    private static func endsWithUnescapedPipe(_ line: String) -> Bool {
        let text = line as NSString
        guard text.length > 0, text.character(at: text.length - 1) == 0x7C else { return false }
        var slashes = 0
        var cursor = text.length - 2
        while cursor >= 0, text.character(at: cursor) == 0x5C {
            slashes += 1
            cursor -= 1
        }
        return slashes.isMultiple(of: 2)
    }
}
