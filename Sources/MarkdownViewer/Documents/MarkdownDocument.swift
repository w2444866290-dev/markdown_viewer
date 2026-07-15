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

    /// Migrates the source-empty paragraph blocks written by the pre-boundary
    /// session model. Detection relies on the persisted virtual block itself, not
    /// on ordinary source whitespace, so historical blank lines are never inferred
    /// as an edit position. Existing IDs and all non-boundary source slices remain
    /// unchanged.
    func migratingLegacyContainerEmptyParagraphs() -> (
        document: MarkdownDocument,
        didMigrate: Bool
    ) {
        guard blocks.count > 1 else { return (self, false) }
        var migrated = self
        let ending = preferredLineEnding
        var didMigrate = false

        for index in migrated.blocks.indices.dropFirst() {
            let block = migrated.blocks[index]
            let previous = migrated.blocks[index - 1]
            guard block.kind == .paragraph,
                  block.source.isEmpty,
                  previous.kind == .list || previous.kind == .quote else {
                continue
            }

            let durableLeading = Self.lineTerminatorCount(in: block.leadingTrivia) >= 2
            if index == migrated.blocks.count - 1 {
                guard !durableLeading else { continue }
                migrated.blocks[index] = block.replacingLeadingTrivia(
                    Self.ensureBlankLineBoundary(block.leadingTrivia, lineEnding: ending)
                )
                didMigrate = true
                continue
            }

            let following = migrated.blocks[index + 1]
            let durableFollowing = Self.lineTerminatorCount(
                in: following.leadingTrivia
            ) >= 2
            guard !durableLeading || !durableFollowing else { continue }
            if !durableLeading {
                migrated.blocks[index] = block.replacingLeadingTrivia(
                    Self.ensureBlankLineBoundary(block.leadingTrivia, lineEnding: ending)
                )
            }
            if !durableFollowing {
                migrated.blocks[index + 1] = following.replacingLeadingTrivia(
                    Self.ensureBlankLineBoundary(following.leadingTrivia, lineEnding: ending)
                )
            }
            didMigrate = true
        }
        return (migrated, didMigrate)
    }

    /// Re-detects the semantic kind of one live source-editor draft.
    ///
    /// A block may change type before it is committed, such as when a paragraph
    /// draft becomes `- item`. Keyboard commands must follow that current source
    /// instead of the kind captured when editing began.
    static func inferredBlockKind(forDraft source: String) -> MarkdownBlockKind {
        standaloneKind(of: source)
    }

    /// Re-detects the semantic kind at one caret inside a multi-block draft.
    /// This is intentionally source-position based: a paste can temporarily put
    /// several Markdown blocks inside one native text editor before commit.
    static func inferredBlockKind(
        forDraft source: String,
        atUTF16Offset offset: Int
    ) -> MarkdownBlockKind {
        let parsed = parse(source)
        guard !parsed.blocks.isEmpty else { return .paragraph }
        let clamped = min(max(0, offset), (source as NSString).length)
        var cursor = 0
        var nearest = parsed.blocks[0].kind
        for block in parsed.blocks {
            let leadingEnd = cursor + (block.leadingTrivia as NSString).length
            let sourceEnd = leadingEnd + (block.source as NSString).length
            if clamped < leadingEnd {
                return block.kind
            }
            if clamped <= sourceEnd {
                return block.kind
            }
            nearest = block.kind
            cursor = sourceEnd
        }
        return nearest
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
        let ending = preferredLineEnding
        if blocks.indices.contains(insertionIndex) {
            // Add one minimal boundary for the new block. The following block
            // keeps ownership of its exact pre-existing trivia, including unusual
            // whitespace and extra blank lines.
            leadingTrivia = ending + ending
        } else {
            leadingTrivia = Self.ensureBlankLineBoundary(
                trailingTrivia,
                lineEnding: ending
            )
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
        return materializingContainerBoundaries(
            in: parsed,
            trailingTrivia: trailingPieces.joined()
        )
    }

    /// Empty paragraphs produced by exiting a list or quote use an explicit,
    /// source-stable blank-line boundary. Between blocks, two ordinary blank-line
    /// boundaries are required so typing into the empty paragraph still leaves a
    /// normal separator on both sides. At EOF one blank-line boundary is enough.
    private static func materializingContainerBoundaries(
        in parsed: [ParsedBlock],
        trailingTrivia: String
    ) -> ParsedDocument {
        var blocks: [ParsedBlock] = []
        blocks.reserveCapacity(parsed.count + 1)
        for block in parsed {
            if let previous = blocks.last,
               previous.kind == .list || previous.kind == .quote,
               lineTerminatorCount(in: block.leadingTrivia) >= 4,
               let boundary = splitTrivia(
                   block.leadingTrivia,
                   afterLineTerminators: 2
               ) {
                blocks.append(ParsedBlock(
                    kind: .paragraph,
                    source: "",
                    leadingTrivia: boundary.prefix
                ))
                blocks.append(ParsedBlock(
                    kind: block.kind,
                    source: block.source,
                    leadingTrivia: boundary.suffix
                ))
            } else {
                blocks.append(block)
            }
        }

        if let final = blocks.last,
           final.kind == .list || final.kind == .quote,
           lineTerminatorCount(in: trailingTrivia) >= 2 {
            blocks.append(ParsedBlock(
                kind: .paragraph,
                source: "",
                leadingTrivia: trailingTrivia
            ))
            return ParsedDocument(blocks: blocks, trailingTrivia: "")
        }
        return ParsedDocument(blocks: blocks, trailingTrivia: trailingTrivia)
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
        if MarkdownFenceSyntax.openingFence(in: line) != nil { return .code }
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
        guard let opening = MarkdownFenceSyntax.openingFence(in: lines[index].content) else {
            return index + 1
        }
        var cursor = index + 1
        while cursor < lines.count {
            if MarkdownFenceSyntax.isClosingFence(lines[cursor].content, matching: opening) {
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

    private static func isHorizontalRule(_ line: String) -> Bool {
        let compact = line.filter { $0 != " " && $0 != "\t" }
        guard compact.count >= 3, let marker = compact.first,
              marker == "-" || marker == "*" || marker == "_" else { return false }
        return compact.allSatisfy { $0 == marker }
    }

    private static func ensureBlankLineBoundary(
        _ trivia: String,
        lineEnding: String
    ) -> String {
        var result = trivia
        while lineTerminatorCount(in: result) < 2 {
            result += lineEnding
        }
        return result
    }

    private static func lineTerminatorCount(in source: String) -> Int {
        losslessLines(source).reduce(0) { count, line in
            count + (line.terminator.isEmpty ? 0 : 1)
        }
    }

    private static func splitTrivia(
        _ source: String,
        afterLineTerminators count: Int
    ) -> (prefix: String, suffix: String)? {
        guard count > 0 else { return ("", source) }
        let text = source as NSString
        var cursor = 0
        var found = 0
        while cursor < text.length {
            let character = text.character(at: cursor)
            if character == 0x0D {
                cursor += 1
                if cursor < text.length, text.character(at: cursor) == 0x0A {
                    cursor += 1
                }
                found += 1
            } else if character == 0x0A {
                cursor += 1
                found += 1
            } else {
                cursor += 1
            }
            if found == count {
                return (
                    text.substring(to: cursor),
                    text.substring(from: cursor)
                )
            }
        }
        return nil
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
/// Semantic cell values and their source lexemes deliberately coexist. Editing a
/// cell replaces only that cell's escaped content; row padding, outer pipes,
/// separator spelling, and every row terminator remain untouched. Structural edits
/// rebuild only the rows or columns whose shape necessarily changes.
struct MarkdownTableGrid: Codable, Equatable, Sendable {
    private(set) var header: [String]
    private(set) var rows: [[String]]
    private(set) var alignments: [MarkdownTableAlignment]
    private(set) var lineEnding: String
    private(set) var hasLeadingPipe: Bool
    private(set) var hasTrailingPipe: Bool
    private(set) var finalLineEnding: String
    private var headerLexeme: MarkdownTableRowLexeme
    private var separatorLexeme: MarkdownTableRowLexeme
    private var rowLexemes: [MarkdownTableRowLexeme]
    private var leftAlignmentUsesColon: [Bool]

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
        let forceOuterPipes = count == 1
        let leading = hasLeadingPipe || forceOuterPipes
        let trailing = hasTrailingPipe || forceOuterPipes
        headerLexeme = Self.canonicalRow(
            values: self.header,
            leading: leading,
            trailing: trailing,
            terminator: self.lineEnding
        )
        leftAlignmentUsesColon = Array(repeating: false, count: count)
        separatorLexeme = Self.canonicalRow(
            values: self.alignments.map(Self.separatorSource),
            leading: leading,
            trailing: trailing,
            terminator: self.rows.isEmpty ? finalLineEnding : self.lineEnding
        )
        let semanticRows = self.rows
        let preferredEnding = self.lineEnding
        rowLexemes = semanticRows.enumerated().map { index, row in
            Self.canonicalRow(
                values: row,
                leading: leading,
                trailing: trailing,
                terminator: index == semanticRows.count - 1
                    ? finalLineEnding
                    : preferredEnding
            )
        }
        self.hasLeadingPipe = headerLexeme.hasLeadingPipe
        self.hasTrailingPipe = headerLexeme.hasTrailingPipe
    }

    init(parsing source: String) throws {
        let lines = losslessLines(source)
        guard lines.count >= 2,
              lines.allSatisfy({ !$0.content.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw MarkdownTableError.invalidTable
        }
        let parsedHeader = MarkdownTableSyntax.parseLexicalRow(lines[0])
        let parsedSeparator = MarkdownTableSyntax.parseLexicalRow(lines[1])
        let headerValues = parsedHeader.values
        let separatorValues = parsedSeparator.values
        guard !headerValues.isEmpty,
              separatorValues.allSatisfy({ MarkdownTableSyntax.alignment(for: $0) != nil }) else {
            throw MarkdownTableError.invalidTable
        }

        let parsedBody = lines.dropFirst(2).map(MarkdownTableSyntax.parseLexicalRow)
        let body = parsedBody.map(\.values)
        let count = max(
            1,
            headerValues.count,
            separatorValues.count,
            body.map(\.count).max() ?? 0
        )
        header = Self.padded(headerValues, to: count)
        rows = body.map { Self.padded($0, to: count) }
        alignments = Self.paddedAlignments(
            separatorValues.compactMap(MarkdownTableSyntax.alignment(for:)),
            to: count
        )
        lineEnding = lines.first(where: { !$0.terminator.isEmpty })?.terminator ?? "\n"
        hasLeadingPipe = parsedHeader.hasLeadingPipe
        hasTrailingPipe = parsedHeader.hasTrailingPipe
        finalLineEnding = lines.last?.terminator ?? ""
        headerLexeme = parsedHeader
        separatorLexeme = parsedSeparator
        rowLexemes = parsedBody
        leftAlignmentUsesColon = separatorValues.map { value in
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return trimmed.first == ":"
                && MarkdownTableSyntax.alignment(for: value) == .left
        }
        leftAlignmentUsesColon = Self.padded(
            leftAlignmentUsesColon,
            to: count,
            with: false
        )
    }

    mutating func setHeader(column: Int, value: String) throws {
        guard header.indices.contains(column) else {
            throw MarkdownTableError.columnOutOfBounds(column)
        }
        if column >= headerLexeme.cells.count || column >= separatorLexeme.cells.count {
            extendHeaderRuleShape(to: column + 1)
        }
        header[column] = value
        headerLexeme.setValue(value, at: column)
        reconcileHeaderRuleEdges()
    }

    mutating func setCell(row: Int, column: Int, value: String) throws {
        guard rows.indices.contains(row) else {
            throw MarkdownTableError.rowOutOfBounds(row)
        }
        guard header.indices.contains(column) else {
            throw MarkdownTableError.columnOutOfBounds(column)
        }
        if column >= rowLexemes[row].cells.count {
            rowLexemes[row].ensureValueCount(column + 1)
        }
        rows[row][column] = value
        rowLexemes[row].setValue(value, at: column)
        rowLexemes[row].ensureLocallyUnambiguousEmptyEdgeCells()
    }

    mutating func addRow(_ values: [String] = []) {
        let row = Self.padded(values, to: columnCount)
        let previousFinal = finalLineEnding
        setLastRowTerminator(lineEnding)
        let template = rowLexemes.last ?? headerLexeme
        var lexeme = template.styledCopy(values: row)
        lexeme.terminator = previousFinal
        lexeme.ensureUnambiguousEmptyEdgeCells()
        rows.append(row)
        rowLexemes.append(lexeme)
        finalLineEnding = lexeme.terminator
    }

    @discardableResult
    mutating func deleteRow(at index: Int) -> Bool {
        guard rows.indices.contains(index) else { return false }
        let deletingFinal = index == rows.count - 1
        let removed = rowLexemes.remove(at: index)
        rows.remove(at: index)
        if deletingFinal {
            setLastRowTerminator(removed.terminator)
            finalLineEnding = removed.terminator
        }
        if !rowLexemes.contains(where: { $0.cells.count >= columnCount }) {
            ensureHeaderRuleShape(to: columnCount)
        }
        return true
    }

    mutating func addColumn(
        header headerValue: String = "",
        defaultCell: String = "",
        alignment: MarkdownTableAlignment = .left
    ) {
        let existingCount = columnCount
        normalizeLexemeShape(to: existingCount)
        header.append(headerValue)
        alignments.append(alignment)
        leftAlignmentUsesColon.append(false)
        headerLexeme.appendValue(headerValue)
        separatorLexeme.appendValue(Self.separatorSource(alignment))
        for index in rows.indices {
            rows[index].append(defaultCell)
            rowLexemes[index].appendValue(defaultCell)
        }
        ensureUnambiguousLexemeShape()
    }

    /// Delete a column while enforcing the invariant that a table always has one.
    @discardableResult
    mutating func deleteColumn(at index: Int) -> Bool {
        guard columnCount > 1, header.indices.contains(index) else { return false }
        normalizeLexemeShape(to: columnCount)
        header.remove(at: index)
        alignments.remove(at: index)
        leftAlignmentUsesColon.remove(at: index)
        headerLexeme.removeValue(at: index)
        separatorLexeme.removeValue(at: index)
        for row in rows.indices {
            rows[row].remove(at: index)
            rowLexemes[row].removeValue(at: index)
        }
        if columnCount == 1 {
            headerLexeme.ensureOuterPipes()
            separatorLexeme.ensureOuterPipes()
            for row in rowLexemes.indices { rowLexemes[row].ensureOuterPipes() }
            hasLeadingPipe = true
            hasTrailingPipe = true
        }
        ensureUnambiguousLexemeShape()
        return true
    }

    @discardableResult
    mutating func cycleAlignment(at column: Int) throws -> MarkdownTableAlignment {
        guard alignments.indices.contains(column) else {
            throw MarkdownTableError.columnOutOfBounds(column)
        }
        if column >= headerLexeme.cells.count || column >= separatorLexeme.cells.count {
            ensureHeaderRuleShape(to: column + 1)
        }
        alignments[column] = alignments[column].next
        separatorLexeme.setSeparator(
            alignment: alignments[column],
            at: column,
            leftUsesColon: leftAlignmentUsesColon[column]
        )
        return alignments[column]
    }

    func serialized() -> String {
        ([headerLexeme, separatorLexeme] + rowLexemes)
            .map(\.serialized)
            .joined()
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

    private static func padded<T>(
        _ values: [T],
        to count: Int,
        with value: T
    ) -> [T] {
        if values.count >= count { return Array(values.prefix(count)) }
        return values + Array(repeating: value, count: count - values.count)
    }

    private static func canonicalRow(
        values: [String],
        leading: Bool,
        trailing: Bool,
        terminator: String
    ) -> MarkdownTableRowLexeme {
        MarkdownTableRowLexeme(
            leadingOuterWhitespace: "",
            hasLeadingPipe: leading,
            cells: values.enumerated().map { index, value in
                MarkdownTableCellLexeme(
                    leadingWhitespace: leading || index > 0 ? " " : "",
                    rawContent: MarkdownTableSyntax.escapeCell(value),
                    trailingWhitespace: trailing || index + 1 < values.count ? " " : ""
                )
            },
            hasTrailingPipe: trailing,
            trailingOuterWhitespace: "",
            terminator: terminator
        )
    }

    private static func separatorSource(_ alignment: MarkdownTableAlignment) -> String {
        switch alignment {
        case .left: return "---"
        case .center: return ":---:"
        case .right: return "---:"
        }
    }

    private mutating func setLastRowTerminator(_ terminator: String) {
        if rowLexemes.isEmpty {
            separatorLexeme.terminator = terminator
        } else {
            rowLexemes[rowLexemes.count - 1].terminator = terminator
        }
    }

    private mutating func normalizeLexemeShape(to count: Int) {
        ensureHeaderRuleShape(to: count)
        for row in rowLexemes.indices {
            rowLexemes[row].ensureValueCount(count)
        }
        ensureUnambiguousLexemeShape()
    }

    private mutating func ensureHeaderRuleShape(to count: Int) {
        extendHeaderRuleShape(to: count)
        reconcileHeaderRuleEdges()
    }

    private mutating func extendHeaderRuleShape(to count: Int) {
        headerLexeme.ensureValueCount(count)
        while separatorLexeme.cells.count < count {
            let column = separatorLexeme.cells.count
            separatorLexeme.appendValue(Self.separatorSource(alignments[column]))
        }
    }

    private mutating func reconcileHeaderRuleEdges() {
        headerLexeme.ensureLocallyUnambiguousEmptyEdgeCells()
        separatorLexeme.ensureLocallyUnambiguousEmptyEdgeCells()
        hasLeadingPipe = headerLexeme.hasLeadingPipe
        hasTrailingPipe = headerLexeme.hasTrailingPipe
    }

    private mutating func ensureUnambiguousLexemeShape() {
        headerLexeme.ensureUnambiguousEmptyEdgeCells()
        separatorLexeme.ensureUnambiguousEmptyEdgeCells()
        for row in rowLexemes.indices {
            rowLexemes[row].ensureUnambiguousEmptyEdgeCells()
        }
        hasLeadingPipe = headerLexeme.hasLeadingPipe
        hasTrailingPipe = headerLexeme.hasTrailingPipe
    }
}

private struct MarkdownTableCellLexeme: Codable, Equatable, Sendable {
    var leadingWhitespace: String
    var rawContent: String
    var trailingWhitespace: String

    var value: String { MarkdownTableSyntax.unescapeCell(rawContent) }
    var serialized: String { leadingWhitespace + rawContent + trailingWhitespace }

    init(rawSegment: String) {
        leadingWhitespace = String(rawSegment.prefix(while: { $0 == " " || $0 == "\t" }))
        let afterLeading = rawSegment.dropFirst(leadingWhitespace.count)
        if afterLeading.isEmpty {
            rawContent = ""
            trailingWhitespace = ""
        } else {
            trailingWhitespace = String(
                afterLeading.reversed()
                    .prefix(while: { $0 == " " || $0 == "\t" })
                    .reversed()
            )
            rawContent = String(afterLeading.dropLast(trailingWhitespace.count))
        }
    }

    init(leadingWhitespace: String, rawContent: String, trailingWhitespace: String) {
        self.leadingWhitespace = leadingWhitespace
        self.rawContent = rawContent
        self.trailingWhitespace = trailingWhitespace
    }
}

private struct MarkdownTableRowLexeme: Codable, Equatable, Sendable {
    var leadingOuterWhitespace: String
    var hasLeadingPipe: Bool
    var cells: [MarkdownTableCellLexeme]
    var hasTrailingPipe: Bool
    var trailingOuterWhitespace: String
    var terminator: String

    var values: [String] { cells.map(\.value) }
    var serialized: String {
        leadingOuterWhitespace
            + (hasLeadingPipe ? "|" : "")
            + cells.map(\.serialized).joined(separator: "|")
            + (hasTrailingPipe ? "|" : "")
            + trailingOuterWhitespace
            + terminator
    }

    mutating func setValue(_ value: String, at column: Int) {
        while cells.count <= column { appendValue("") }
        cells[column].rawContent = MarkdownTableSyntax.escapeCell(value)
    }

    mutating func appendValue(_ value: String) {
        let style = cells.last ?? MarkdownTableCellLexeme(
            leadingWhitespace: hasLeadingPipe ? " " : "",
            rawContent: "",
            trailingWhitespace: hasTrailingPipe ? " " : ""
        )
        cells.append(MarkdownTableCellLexeme(
            leadingWhitespace: style.leadingWhitespace,
            rawContent: MarkdownTableSyntax.escapeCell(value),
            trailingWhitespace: style.trailingWhitespace
        ))
    }

    mutating func ensureValueCount(_ count: Int, defaultValue: String = "") {
        while cells.count < count { appendValue(defaultValue) }
    }

    mutating func removeValue(at column: Int) {
        guard cells.indices.contains(column) else { return }
        cells.remove(at: column)
    }

    mutating func ensureOuterPipes() {
        hasLeadingPipe = true
        hasTrailingPipe = true
    }

    mutating func ensureUnambiguousEmptyEdgeCells() {
        guard let first = cells.first, let last = cells.last else { return }
        if first.value.isEmpty || last.value.isEmpty {
            ensureOuterPipes()
        }
    }

    mutating func ensureLocallyUnambiguousEmptyEdgeCells() {
        guard let first = cells.first, let last = cells.last else { return }
        if first.value.isEmpty { hasLeadingPipe = true }
        if last.value.isEmpty { hasTrailingPipe = true }
    }

    func styledCopy(values: [String]) -> MarkdownTableRowLexeme {
        var copy = self
        copy.cells = values.enumerated().map { index, value in
            let style = cells.indices.contains(index)
                ? cells[index]
                : cells.last ?? MarkdownTableCellLexeme(
                    leadingWhitespace: hasLeadingPipe ? " " : "",
                    rawContent: "",
                    trailingWhitespace: hasTrailingPipe ? " " : ""
                )
            return MarkdownTableCellLexeme(
                leadingWhitespace: style.leadingWhitespace,
                rawContent: MarkdownTableSyntax.escapeCell(value),
                trailingWhitespace: style.trailingWhitespace
            )
        }
        return copy
    }

    mutating func setSeparator(
        alignment: MarkdownTableAlignment,
        at column: Int,
        leftUsesColon: Bool
    ) {
        while cells.count <= column { appendValue("---") }
        let dashCount = max(3, cells[column].rawContent.filter { $0 == "-" }.count)
        let dashes = String(repeating: "-", count: dashCount)
        switch alignment {
        case .left:
            cells[column].rawContent = (leftUsesColon ? ":" : "") + dashes
        case .center:
            cells[column].rawContent = ":" + dashes + ":"
        case .right:
            cells[column].rawContent = dashes + ":"
        }
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
        let parsed = parseLexicalRow(LosslessSourceLine(content: line, terminator: ""))
        return ParsedRow(
            cells: parsed.values,
            hasLeadingPipe: parsed.hasLeadingPipe,
            hasTrailingPipe: parsed.hasTrailingPipe
        )
    }

    static func parseLexicalRow(_ line: LosslessSourceLine) -> MarkdownTableRowLexeme {
        let source = line.content
        let unescapedPipes = unescapedPipeIndices(in: source)
        let firstNonWhitespace = source.firstIndex(where: { $0 != " " && $0 != "\t" })
        let lastNonWhitespace = source.lastIndex(where: { $0 != " " && $0 != "\t" })
        let leadingPipe = firstNonWhitespace.flatMap { first in
            unescapedPipes.first == first ? first : nil
        }
        let candidateTrailingPipe = lastNonWhitespace.flatMap { last in
            unescapedPipes.last == last ? last : nil
        }
        let trailingPipe = candidateTrailingPipe == leadingPipe ? nil : candidateTrailingPipe
        let hasLeadingPipe = leadingPipe != nil
        let hasTrailingPipe = trailingPipe != nil
        let contentStart = leadingPipe.map { source.index(after: $0) } ?? source.startIndex
        let contentEnd = trailingPipe ?? source.endIndex
        let internalPipes = unescapedPipes.filter {
            $0 >= contentStart && $0 < contentEnd
        }

        var segments: [String] = []
        var start = contentStart
        for pipe in internalPipes {
            segments.append(String(source[start..<pipe]))
            start = source.index(after: pipe)
        }
        segments.append(String(source[start..<contentEnd]))
        if segments.isEmpty { segments = [""] }

        return MarkdownTableRowLexeme(
            leadingOuterWhitespace: leadingPipe.map { String(source[..<$0]) } ?? "",
            hasLeadingPipe: hasLeadingPipe,
            cells: segments.map(MarkdownTableCellLexeme.init(rawSegment:)),
            hasTrailingPipe: hasTrailingPipe,
            trailingOuterWhitespace: trailingPipe.map {
                String(source[source.index(after: $0)...])
            } ?? "",
            terminator: line.terminator
        )
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

    static func unescapeCell(_ source: String) -> String {
        var output = ""
        var iterator = source.makeIterator()
        while let character = iterator.next() {
            if character == "\\", let next = iterator.next() {
                if next == "|" || next == "\\" {
                    output.append(next)
                } else {
                    output.append("\\")
                    output.append(next)
                }
            } else {
                output.append(character)
            }
        }
        return output
    }

    private static func unescapedPipeIndices(in source: String) -> [String.Index] {
        var result: [String.Index] = []
        var slashCount = 0
        for index in source.indices {
            let character = source[index]
            if character == "|" {
                if slashCount.isMultiple(of: 2) { result.append(index) }
                slashCount = 0
            } else if character == "\\" {
                slashCount += 1
            } else {
                slashCount = 0
            }
        }
        return result
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
