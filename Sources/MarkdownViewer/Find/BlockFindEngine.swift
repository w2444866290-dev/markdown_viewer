import Foundation

/// Search options for the lossless block document model.
struct BlockFindOptions: Equatable {
    var query: String
    var caseSensitive: Bool
    var wholeWord: Bool
    var useRegex: Bool
    var activeSourceBlockID: UUID?
    var activeTableBlockID: UUID?

    init(
        query: String,
        caseSensitive: Bool = false,
        wholeWord: Bool = false,
        useRegex: Bool = false,
        activeSourceBlockID: UUID? = nil,
        activeTableBlockID: UUID? = nil
    ) {
        self.query = query
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.useRegex = useRegex
        self.activeSourceBlockID = activeSourceBlockID
        self.activeTableBlockID = activeTableBlockID
    }
}

struct BlockFindTableCellMatch: Equatable {
    let row: Int
    let column: Int
    let range: NSRange
}

private struct BlockFindTableCellCoordinate: Equatable {
    let row: Int
    let column: Int
}

private enum BlockFindProjectionMode: Equatable {
    case rendered
    case source
    case tableGrid
}

enum BlockFindSearchError: Error, Equatable {
    case invalidRegularExpression
}

enum BlockFindMutationError: Error, Equatable {
    case blockNotFound(UUID)
    case staleMatch(UUID, NSRange)
    case unsafeVisibleReplacement(UUID, NSRange)
}

/// One visible-text projection of a block.
///
/// `text` contains only user-observable content. Searchable regions prevent a
/// match from crossing unrelated visual cells or rows. Every UTF-16 unit inside
/// a searchable region maps to an exact range in the block's source.
struct BlockVisibleTextProjection: Equatable {
    let blockID: UUID
    let text: String
    let searchableRanges: [NSRange]

    private let sourceRangesByUTF16Unit: [NSRange?]
    private let tableCellsBySearchableRange: [BlockFindTableCellCoordinate?]

    fileprivate init(
        blockID: UUID,
        text: String,
        searchableRanges: [NSRange],
        sourceRangesByUTF16Unit: [NSRange?],
        tableCellsBySearchableRange: [BlockFindTableCellCoordinate?]
    ) {
        self.blockID = blockID
        self.text = text
        self.searchableRanges = searchableRanges
        self.sourceRangesByUTF16Unit = sourceRangesByUTF16Unit
        self.tableCellsBySearchableRange = tableCellsBySearchableRange
    }

    /// Maps a visible UTF-16 range back to the source envelope it covers.
    /// Hidden syntax interleaved between the first and last visible unit is included.
    func sourceRange(forVisibleRange range: NSRange) -> NSRange? {
        guard let ranges = sourceRanges(forVisibleRange: range),
              let first = ranges.first,
              let last = ranges.last else {
            return nil
        }
        return NSRange(
            location: first.location,
            length: NSMaxRange(last) - first.location
        )
    }

    /// Returns the exact, ordered source spans contributing visible UTF-16 units.
    /// Hidden Markdown delimiters between spans are intentionally excluded.
    func sourceRanges(forVisibleRange range: NSRange) -> [NSRange]? {
        guard range.location >= 0,
              range.length > 0,
              NSMaxRange(range) <= sourceRangesByUTF16Unit.count,
              searchableRanges.contains(where: {
                  range.location >= $0.location && NSMaxRange(range) <= NSMaxRange($0)
              }) else {
            return nil
        }
        let slice = sourceRangesByUTF16Unit[range.location..<NSMaxRange(range)]
        guard slice.allSatisfy({ $0 != nil }) else { return nil }
        let mapped = slice.compactMap { $0 }
        guard !mapped.isEmpty else { return nil }

        var ranges: [NSRange] = []
        for next in mapped {
            guard next.length > 0 else { return nil }
            guard let last = ranges.last else {
                ranges.append(next)
                continue
            }
            guard next.location >= last.location else { return nil }
            if next.location <= NSMaxRange(last) {
                ranges[ranges.count - 1] = NSRange(
                    location: last.location,
                    length: max(NSMaxRange(last), NSMaxRange(next)) - last.location
                )
            } else {
                ranges.append(next)
            }
        }
        return ranges
    }

    fileprivate func tableCell(
        forSearchableRangeAt index: Int,
        visibleRange: NSRange
    ) -> BlockFindTableCellMatch? {
        guard searchableRanges.indices.contains(index),
              tableCellsBySearchableRange.indices.contains(index),
              let cell = tableCellsBySearchableRange[index] else {
            return nil
        }
        let region = searchableRanges[index]
        guard visibleRange.location >= region.location,
              NSMaxRange(visibleRange) <= NSMaxRange(region) else {
            return nil
        }
        return BlockFindTableCellMatch(
            row: cell.row,
            column: cell.column,
            range: NSRange(
                location: visibleRange.location - region.location,
                length: visibleRange.length
            )
        )
    }
}

struct BlockFindMatch: Equatable {
    let blockID: UUID
    let blockIndex: Int
    let visibleRange: NSRange
    let sourceRange: NSRange
    let visibleText: String
    let tableCell: BlockFindTableCellMatch?

    fileprivate let sourceRanges: [NSRange]
    fileprivate let blockSourceSnapshot: String
    fileprivate let captures: [String?]
    fileprivate let usesRegex: Bool
    fileprivate let projectionMode: BlockFindProjectionMode

    /// Expands ICU-style `$0`, `$1`, and later capture references for regex results.
    /// Literal searches return the replacement template verbatim.
    func expandedReplacement(for template: String) -> String {
        guard usesRegex else { return template }
        var output = ""
        var cursor = template.startIndex
        while cursor < template.endIndex {
            let character = template[cursor]
            if character == "\\" {
                let next = template.index(after: cursor)
                if next < template.endIndex {
                    output.append(template[next])
                    cursor = template.index(after: next)
                } else {
                    output.append(character)
                    cursor = next
                }
                continue
            }
            guard character == "$" else {
                output.append(character)
                cursor = template.index(after: cursor)
                continue
            }

            var digitCursor = template.index(after: cursor)
            if digitCursor < template.endIndex, template[digitCursor] == "$" {
                output.append("$")
                cursor = template.index(after: digitCursor)
                continue
            }
            let digitsStart = digitCursor
            while digitCursor < template.endIndex, template[digitCursor].isNumber {
                digitCursor = template.index(after: digitCursor)
            }
            guard digitsStart != digitCursor,
                  let captureIndex = Int(template[digitsStart..<digitCursor]),
                  captures.indices.contains(captureIndex) else {
                output.append("$")
                cursor = template.index(after: cursor)
                continue
            }
            output.append(captures[captureIndex] ?? "")
            cursor = digitCursor
        }
        return output
    }
}

struct BlockFindResult: Equatable {
    let matches: [BlockFindMatch]
    let error: BlockFindSearchError?

    var isEmpty: Bool { matches.isEmpty }

    /// Returns an index after applying a delta with wraparound navigation.
    func wrappedIndex(from currentIndex: Int, delta: Int) -> Int? {
        guard !matches.isEmpty else { return nil }
        let count = matches.count
        let current = ((currentIndex % count) + count) % count
        return ((current + delta) % count + count) % count
    }
}

/// Visible-text projection, search, and local replacement for MarkdownDocument.
enum BlockFindEngine {
    /// Returns the user-visible text produced by one inline Markdown source run.
    /// This is shared by search projection and outline-title presentation so both
    /// surfaces hide the same delimiters, links, and supported inline HTML.
    static func visibleInlineText(in source: String) -> String {
        let source = source as NSString
        var run = MappedRun()
        appendInline(
            source,
            range: NSRange(location: 0, length: source.length),
            to: &run
        )
        return run.text
    }

    static func projection(
        for block: MarkdownBlock,
        sourceMode: Bool = false
    ) -> BlockVisibleTextProjection {
        projection(
            for: block,
            mode: sourceMode ? .source : .rendered
        )
    }

    private static func projection(
        for block: MarkdownBlock,
        mode: BlockFindProjectionMode
    ) -> BlockVisibleTextProjection {
        let source = block.source as NSString
        var builder = ProjectionBuilder(blockID: block.id)
        if mode == .source {
            var run = MappedRun()
            run.appendSource(source, range: NSRange(location: 0, length: source.length))
            builder.append(run)
            return builder.projection
        }

        switch block.kind {
        case .heading:
            projectHeading(source, into: &builder)
        case .paragraph:
            projectParagraph(source, into: &builder)
        case .quote:
            projectLineBlocks(source, prefixRegex: quotePrefixRegex, into: &builder)
        case .list:
            projectList(source, into: &builder)
        case .code:
            projectCode(source, into: &builder)
        case .table:
            projectTable(
                source,
                editableGrid: mode == .tableGrid,
                into: &builder
            )
        case .image:
            var run = MappedRun()
            appendInline(source, range: NSRange(location: 0, length: source.length), to: &run)
            builder.append(run)
        case .horizontalRule:
            break
        case .footnotes:
            projectLineBlocks(source, prefixRegex: footnotePrefixRegex, into: &builder)
        }
        return builder.projection
    }

    static func search(
        in document: MarkdownDocument,
        options: BlockFindOptions
    ) -> BlockFindResult {
        search(in: document.blocks, options: options)
    }

    /// Searches a caller-supplied block snapshot.
    ///
    /// The editor uses this overload while a source block has an uncommitted draft,
    /// so visible source can be searched without reparsing or publishing the document.
    static func search(
        in blocks: [MarkdownBlock],
        options: BlockFindOptions
    ) -> BlockFindResult {
        guard !options.query.isEmpty else {
            return BlockFindResult(matches: [], error: nil)
        }

        let regex: NSRegularExpression
        do {
            regex = try makeRegex(options)
        } catch {
            return BlockFindResult(matches: [], error: .invalidRegularExpression)
        }

        var matches: [BlockFindMatch] = []
        for (blockIndex, block) in blocks.enumerated() {
            let mode: BlockFindProjectionMode
            if block.id == options.activeSourceBlockID {
                mode = .source
            } else if block.id == options.activeTableBlockID, block.kind == .table {
                mode = .tableGrid
            } else {
                mode = .rendered
            }
            let projected = projection(
                for: block,
                mode: mode
            )
            let projectedText = projected.text as NSString
            for (searchableIndex, searchableRange) in projected.searchableRanges.enumerated() {
                let regionText = projectedText.substring(with: searchableRange)
                let region = regionText as NSString
                let regionRange = NSRange(location: 0, length: region.length)
                for result in regex.matches(in: regionText, range: regionRange)
                where result.range.length > 0 {
                    let visibleRange = NSRange(
                        location: searchableRange.location + result.range.location,
                        length: result.range.length
                    )
                    guard let sourceRanges = projected.sourceRanges(
                        forVisibleRange: visibleRange
                    ),
                    let firstSourceRange = sourceRanges.first,
                    let lastSourceRange = sourceRanges.last else {
                        continue
                    }
                    let sourceRange = NSRange(
                        location: firstSourceRange.location,
                        length: NSMaxRange(lastSourceRange) - firstSourceRange.location
                    )
                    let blockSource = block.source as NSString
                    guard NSMaxRange(sourceRange) <= blockSource.length else { continue }
                    let captures = (0..<result.numberOfRanges).map { index -> String? in
                        let range = result.range(at: index)
                        guard range.location != NSNotFound else { return nil }
                        return region.substring(with: range)
                    }
                    matches.append(BlockFindMatch(
                        blockID: block.id,
                        blockIndex: blockIndex,
                        visibleRange: visibleRange,
                        sourceRange: sourceRange,
                        visibleText: region.substring(with: result.range),
                        tableCell: projected.tableCell(
                            forSearchableRangeAt: searchableIndex,
                            visibleRange: visibleRange
                        ),
                        sourceRanges: sourceRanges,
                        blockSourceSnapshot: block.source,
                        captures: captures,
                        usesRegex: options.useRegex,
                        projectionMode: mode
                    ))
                }
            }
        }
        return BlockFindResult(matches: matches, error: nil)
    }

    @discardableResult
    static func replace(
        _ match: BlockFindMatch,
        with template: String,
        in document: inout MarkdownDocument
    ) throws -> [UUID] {
        guard let block = document.block(id: match.blockID) else {
            throw BlockFindMutationError.blockNotFound(match.blockID)
        }
        let replacementSource = try applying(
            [match],
            template: template,
            to: block
        )
        return try document.replaceBlock(id: block.id, with: replacementSource)
    }

    /// Replaces all matches from the same search snapshot, editing later blocks first.
    @discardableResult
    static func replaceAll(
        _ result: BlockFindResult,
        with template: String,
        in document: inout MarkdownDocument
    ) throws -> Int {
        guard result.error == nil else { return 0 }
        let grouped = Dictionary(grouping: result.matches, by: \.blockID)
        let orderedGroups = grouped.values.sorted {
            ($0.first?.blockIndex ?? 0) > ($1.first?.blockIndex ?? 0)
        }
        var count = 0
        for group in orderedGroups {
            guard let blockID = group.first?.blockID,
                  let block = document.block(id: blockID) else {
                if let blockID = group.first?.blockID {
                    throw BlockFindMutationError.blockNotFound(blockID)
                }
                continue
            }
            let replacementSource = try applying(group, template: template, to: block)
            _ = try document.replaceBlock(id: block.id, with: replacementSource)
            count += group.count
        }
        return count
    }

    /// Applies a stable find snapshot to one caller-owned block source.
    ///
    /// The block editor uses this before reparsing an active source draft so a
    /// source-only match cannot disappear at the commit boundary.
    static func replacementSource(
        for matches: [BlockFindMatch],
        with template: String,
        in block: MarkdownBlock
    ) throws -> String {
        try applying(matches, template: template, to: block)
    }

    // MARK: - Search and replacement helpers

    private static func makeRegex(_ options: BlockFindOptions) throws -> NSRegularExpression {
        var pattern = options.useRegex
            ? options.query
            : NSRegularExpression.escapedPattern(for: options.query)
        if options.wholeWord {
            pattern = "(?<![\\p{L}\\p{N}_])(?:\(pattern))(?![\\p{L}\\p{N}_])"
        }
        var regexOptions: NSRegularExpression.Options = [.useUnicodeWordBoundaries]
        if !options.caseSensitive { regexOptions.insert(.caseInsensitive) }
        return try NSRegularExpression(pattern: pattern, options: regexOptions)
    }

    private static func applying(
        _ matches: [BlockFindMatch],
        template: String,
        to block: MarkdownBlock
    ) throws -> String {
        guard matches.allSatisfy({
            $0.blockID == block.id && $0.blockSourceSnapshot == block.source
        }) else {
            let range = matches.first?.sourceRange ?? NSRange(location: 0, length: 0)
            throw BlockFindMutationError.staleMatch(block.id, range)
        }

        var source = block.source
        let sorted = matches.sorted { $0.sourceRange.location > $1.sourceRange.location }
        var previousStart = (source as NSString).length
        for match in sorted {
            let currentLength = (source as NSString).length
            guard match.sourceRange.location >= 0,
                  NSMaxRange(match.sourceRange) <= currentLength,
                  NSMaxRange(match.sourceRange) <= previousStart,
                  match.sourceRanges.allSatisfy({
                      $0.location >= 0 && NSMaxRange($0) <= currentLength
                  }) else {
                throw BlockFindMutationError.staleMatch(block.id, match.sourceRange)
            }
            source = try applying(
                match,
                replacement: match.expandedReplacement(for: template),
                to: source,
                block: block
            )
            previousStart = match.sourceRange.location
        }
        return source
    }

    private static func applying(
        _ match: BlockFindMatch,
        replacement: String,
        to source: String,
        block: MarkdownBlock
    ) throws -> String {
        let currentBlock = MarkdownBlock(
            id: block.id,
            kind: block.kind,
            source: source,
            leadingTrivia: block.leadingTrivia
        )
        let currentProjection = projection(
            for: currentBlock,
            mode: match.projectionMode
        )
        let projected = currentProjection.text as NSString
        guard match.visibleRange.location >= 0,
              NSMaxRange(match.visibleRange) <= projected.length else {
            throw BlockFindMutationError.staleMatch(block.id, match.sourceRange)
        }

        let expected = NSMutableString(string: currentProjection.text)
        expected.replaceCharacters(
            in: match.visibleRange,
            with: visibleReplacement(replacement, mode: match.projectionMode)
        )

        let sourceReplacement = sourceReplacement(
            replacement,
            mode: match.projectionMode
        )

        var candidates: [(source: String, penalty: Int, order: Int)] = []
        var seen = Set<String>()
        for anchor in match.sourceRanges.indices {
            let candidate = replacingVisibleRanges(
                match.sourceRanges,
                anchor: anchor,
                replacement: sourceReplacement,
                in: source
            )
            guard seen.insert(candidate).inserted,
                  projectionText(
                    for: candidate,
                    basedOn: block,
                    mode: match.projectionMode
                  ) == expected as String else {
                continue
            }
            candidates.append((
                source: candidate,
                penalty: emptyInlineMarkupPenalty(candidate),
                order: anchor
            ))
        }

        let originalEmptyMarkupPenalty = emptyInlineMarkupPenalty(source)
        let candidateIntroducedEmptyMarkup = candidates
            .map(\.penalty)
            .min()
            .map { $0 > originalEmptyMarkupPenalty }
            ?? true
        if candidates.isEmpty || candidateIntroducedEmptyMarkup {
            for anchor in match.sourceRanges.indices {
                let rawCandidate = replacingVisibleRanges(
                    match.sourceRanges,
                    anchor: anchor,
                    replacement: sourceReplacement,
                    in: source
                )
                let candidate = removingNewEmptyInlineMarkup(
                    from: rawCandidate,
                    comparedTo: source,
                    near: match.sourceRange.location
                )
                guard candidate != rawCandidate,
                      seen.insert(candidate).inserted,
                      projectionText(
                        for: candidate,
                        basedOn: block,
                        mode: match.projectionMode
                      ) == expected as String else {
                    continue
                }
                candidates.append((
                    source: candidate,
                    penalty: emptyInlineMarkupPenalty(candidate),
                    order: anchor
                ))
            }
        }

        if let best = candidates.min(by: {
            if $0.penalty != $1.penalty { return $0.penalty < $1.penalty }
            return $0.order < $1.order
        }) {
            return best.source
        }

        let contiguous = NSMutableString(string: source)
        contiguous.replaceCharacters(in: match.sourceRange, with: sourceReplacement)
        let fallback = contiguous as String
        if projectionText(
            for: fallback,
            basedOn: block,
            mode: match.projectionMode
        ) == expected as String {
            return fallback
        }
        throw BlockFindMutationError.unsafeVisibleReplacement(block.id, match.sourceRange)
    }

    private static func replacingVisibleRanges(
        _ ranges: [NSRange],
        anchor: Int,
        replacement: String,
        in source: String
    ) -> String {
        let mutable = NSMutableString(string: source)
        for index in ranges.indices.reversed() {
            mutable.replaceCharacters(
                in: ranges[index],
                with: index == anchor ? replacement : ""
            )
        }
        return mutable as String
    }

    private static func projectionText(
        for source: String,
        basedOn block: MarkdownBlock,
        mode: BlockFindProjectionMode
    ) -> String {
        projection(
            for: MarkdownBlock(
                id: block.id,
                kind: block.kind,
                source: source,
                leadingTrivia: block.leadingTrivia
            ),
            mode: mode
        ).text
    }

    private static func visibleReplacement(
        _ replacement: String,
        mode: BlockFindProjectionMode
    ) -> String {
        switch mode {
        case .rendered:
            return visibleInlineText(in: replacement)
        case .source, .tableGrid:
            return replacement
        }
    }

    private static func sourceReplacement(
        _ replacement: String,
        mode: BlockFindProjectionMode
    ) -> String {
        guard mode == .tableGrid else { return replacement }
        return replacement
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
    }

    private static func emptyInlineMarkupPenalty(_ source: String) -> Int {
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        return emptyInlineMarkupPatterns.reduce(0) { count, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return count }
            return count + regex.numberOfMatches(in: source, range: fullRange)
        }
    }

    private static func removingNewEmptyInlineMarkup(
        from candidate: String,
        comparedTo original: String,
        near sourceLocation: Int
    ) -> String {
        var result = candidate
        for pattern in emptyInlineMarkupPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let originalNSString = original as NSString
            let originalRange = NSRange(location: 0, length: originalNSString.length)
            let originalCounts = Dictionary(
                grouping: regex.matches(in: original, range: originalRange).map {
                    originalNSString.substring(with: $0.range)
                },
                by: { $0 }
            ).mapValues(\.count)

            let resultNSString = result as NSString
            let resultRange = NSRange(location: 0, length: resultNSString.length)
            let matches = regex.matches(in: result, range: resultRange)
            let grouped = Dictionary(grouping: matches) {
                resultNSString.substring(with: $0.range)
            }
            var removals: [NSRange] = []
            for (text, occurrences) in grouped {
                let surplus = occurrences.count - originalCounts[text, default: 0]
                guard surplus > 0 else { continue }
                let nearest = occurrences.sorted {
                    abs($0.range.location - sourceLocation)
                        < abs($1.range.location - sourceLocation)
                }
                removals.append(contentsOf: nearest.prefix(surplus).map(\.range))
            }
            guard !removals.isEmpty else { continue }
            let mutable = NSMutableString(string: result)
            for range in removals.sorted(by: { $0.location > $1.location }) {
                mutable.deleteCharacters(in: range)
            }
            result = mutable as String
        }
        return result
    }

    private static let emptyInlineMarkupPatterns = [
        #"!?\[\]\([^\r\n)]*\)"#,
        #"<(u|sup|sub|mark)>[ \t]*</\1>"#,
        #"\[\^\]"#,
        #"(\*{1,3}|_{1,3}|~~|`+)\1"#,
    ]

    // MARK: - Block projection

    private static func projectHeading(
        _ source: NSString,
        into builder: inout ProjectionBuilder
    ) {
        guard let line = sourceLines(source).first else { return }
        var range = line.contentRange
        if let prefix = headingPrefix(source, range: range) {
            range.location = NSMaxRange(prefix)
            range.length = NSMaxRange(line.contentRange) - range.location
        }
        range = headingContentRange(source, range: range)
        var run = MappedRun()
        appendInline(source, range: range, to: &run)
        builder.append(run)
    }

    private static func projectParagraph(
        _ source: NSString,
        into builder: inout ProjectionBuilder
    ) {
        let lines = sourceLines(source)
        var run = MappedRun()
        for (index, line) in lines.enumerated() {
            appendInline(source, range: line.contentRange, to: &run)
            if index + 1 < lines.count, line.terminatorRange.length > 0 {
                run.append(" ", sourceRange: line.terminatorRange)
            }
        }
        builder.append(run)
    }

    private static func projectLineBlocks(
        _ source: NSString,
        prefixRegex: NSRegularExpression?,
        into builder: inout ProjectionBuilder
    ) {
        for line in sourceLines(source) {
            var content = line.contentRange
            if let prefix = firstMatch(prefixRegex, in: source, range: content) {
                content.location = NSMaxRange(prefix)
                content.length = NSMaxRange(line.contentRange) - content.location
            } else {
                content = trimmingLeadingWhitespace(source, range: content)
            }
            var run = MappedRun()
            appendInline(source, range: content, to: &run)
            builder.append(run)
        }
    }

    private static func projectList(
        _ source: NSString,
        into builder: inout ProjectionBuilder
    ) {
        var activeFence: Fence?
        for line in sourceLines(source) {
            var content = line.contentRange
            if activeFence != nil {
                content = trimmingLeadingWhitespace(source, range: content)
                if let fence = activeFence, isClosingFence(source, range: content, fence: fence) {
                    activeFence = nil
                    continue
                }
                var run = MappedRun()
                run.appendSource(source, range: content)
                builder.append(run)
                continue
            }

            if let prefix = firstMatch(listPrefixRegex, in: source, range: content) {
                content.location = NSMaxRange(prefix)
                content.length = NSMaxRange(line.contentRange) - content.location
                if let task = firstMatch(taskPrefixRegex, in: source, range: content) {
                    content.location = NSMaxRange(task)
                    content.length = NSMaxRange(line.contentRange) - content.location
                }
            } else {
                content = trimmingLeadingWhitespace(source, range: content)
            }

            if let fence = openingFence(source, range: content) {
                activeFence = fence
                continue
            }
            var run = MappedRun()
            appendInline(source, range: content, to: &run)
            builder.append(run)
        }
    }

    private static func projectCode(
        _ source: NSString,
        into builder: inout ProjectionBuilder
    ) {
        let lines = sourceLines(source)
        guard !lines.isEmpty,
              let fence = openingFence(source, range: lines[0].contentRange) else {
            var run = MappedRun()
            run.appendSource(source, range: NSRange(location: 0, length: source.length))
            builder.append(run)
            return
        }
        let closingIndex = lines.indices.dropFirst().last(where: {
            isClosingFence(source, range: lines[$0].contentRange, fence: fence)
        })
        let end = closingIndex ?? lines.count
        guard end > 1 else { return }

        var run = MappedRun()
        for index in 1..<end {
            run.appendSource(source, range: lines[index].contentRange)
            if index + 1 < end {
                run.appendSource(source, range: lines[index].terminatorRange)
            }
        }
        builder.append(run)
    }

    private static func projectTable(
        _ source: NSString,
        editableGrid: Bool,
        into builder: inout ProjectionBuilder
    ) {
        for (lineIndex, line) in sourceLines(source).enumerated() where lineIndex != 1 {
            let row = lineIndex == 0 ? -1 : lineIndex - 2
            for (column, cellRange) in tableCellRanges(
                source,
                lineRange: line.contentRange
            ).enumerated() {
                var run = MappedRun()
                if editableGrid {
                    appendEditableTableCell(source, range: cellRange, to: &run)
                } else {
                    appendInline(source, range: cellRange, to: &run)
                }
                builder.append(
                    run,
                    tableCell: BlockFindTableCellCoordinate(row: row, column: column)
                )
            }
        }
    }

    /// Mirrors the table-grid parser's cell value while retaining an exact source map.
    /// Escaped pipes and backslashes are one visible UTF-16 unit in the native field.
    private static func appendEditableTableCell(
        _ source: NSString,
        range: NSRange,
        to run: inout MappedRun
    ) {
        let end = NSMaxRange(range)
        var cursor = range.location
        while cursor < end {
            let length = utf16CharacterLength(source, at: cursor, limit: end)
            guard source.character(at: cursor) == ascii("\\"),
                  cursor + length < end else {
                run.appendSource(
                    source,
                    range: NSRange(location: cursor, length: length)
                )
                cursor += length
                continue
            }

            let escapedLocation = cursor + length
            let escapedLength = utf16CharacterLength(
                source,
                at: escapedLocation,
                limit: end
            )
            let escaped = source.character(at: escapedLocation)
            if escaped == ascii("|") || escaped == ascii("\\") {
                run.append(
                    source.substring(with: NSRange(
                        location: escapedLocation,
                        length: escapedLength
                    )),
                    sourceRange: NSRange(
                        location: cursor,
                        length: length + escapedLength
                    )
                )
            } else {
                run.appendSource(
                    source,
                    range: NSRange(location: cursor, length: length + escapedLength)
                )
            }
            cursor += length + escapedLength
        }
    }

    // MARK: - Inline projection

    private static func appendInline(
        _ source: NSString,
        range: NSRange,
        to run: inout MappedRun
    ) {
        guard range.length > 0 else { return }
        let end = NSMaxRange(range)
        var cursor = range.location
        while cursor < end {
            let character = source.character(at: cursor)

            if character == ascii("\\"), cursor + 1 < end {
                let length = utf16CharacterLength(source, at: cursor + 1, limit: end)
                run.appendSource(source, range: NSRange(location: cursor + 1, length: length))
                cursor += 1 + length
                continue
            }

            if character == ascii("`") {
                let markerLength = repeatedCount(source, at: cursor, value: character, limit: end)
                let marker = source.substring(
                    with: NSRange(location: cursor, length: markerLength)
                )
                let searchRange = NSRange(
                    location: cursor + markerLength,
                    length: end - cursor - markerLength
                )
                let closing = source.range(of: marker, options: [], range: searchRange)
                if closing.location != NSNotFound {
                    run.appendSource(source, range: NSRange(
                        location: cursor + markerLength,
                        length: closing.location - cursor - markerLength
                    ))
                    cursor = NSMaxRange(closing)
                    continue
                }
            }

            if character == ascii("["), cursor + 2 < end,
               source.character(at: cursor + 1) == ascii("^") {
                let closing = source.range(
                    of: "]",
                    options: [],
                    range: NSRange(location: cursor + 2, length: end - cursor - 2)
                )
                if closing.location != NSNotFound {
                    run.appendSource(source, range: NSRange(
                        location: cursor + 2,
                        length: closing.location - cursor - 2
                    ))
                    cursor = NSMaxRange(closing)
                    continue
                }
            }

            let isImage = character == ascii("!")
                && cursor + 1 < end
                && source.character(at: cursor + 1) == ascii("[")
            if character == ascii("[") || isImage {
                let bracket = isImage ? cursor + 1 : cursor
                if let link = linkParts(source, openingBracket: bracket, limit: end) {
                    appendInline(source, range: link.labelRange, to: &run)
                    cursor = link.end
                    continue
                }
            }

            if character == ascii("<"),
               let tag = recognizedHTMLTag(source, at: cursor, limit: end) {
                if tag.isBreak { run.append(" ", sourceRange: tag.range) }
                cursor = NSMaxRange(tag.range)
                continue
            }

            if let delimiter = emphasisDelimiter(source, at: cursor, limit: end),
               let closing = closingDelimiter(
                delimiter,
                source: source,
                after: cursor + delimiter.utf16.count,
                limit: end
               ) {
                let delimiterLength = delimiter.utf16.count
                appendInline(source, range: NSRange(
                    location: cursor + delimiterLength,
                    length: closing - cursor - delimiterLength
                ), to: &run)
                cursor = closing + delimiterLength
                continue
            }

            let length = utf16CharacterLength(source, at: cursor, limit: end)
            run.appendSource(source, range: NSRange(location: cursor, length: length))
            cursor += length
        }
    }

    private static func linkParts(
        _ source: NSString,
        openingBracket: Int,
        limit: Int
    ) -> (labelRange: NSRange, end: Int)? {
        var cursor = openingBracket + 1
        while cursor + 1 < limit {
            if source.character(at: cursor) == ascii("\\") {
                cursor += min(2, limit - cursor)
                continue
            }
            if source.character(at: cursor) == ascii("]"),
               source.character(at: cursor + 1) == ascii("(") {
                let label = NSRange(
                    location: openingBracket + 1,
                    length: cursor - openingBracket - 1
                )
                var depth = 1
                var destination = cursor + 2
                while destination < limit {
                    let value = source.character(at: destination)
                    if value == ascii("\\") {
                        destination += min(2, limit - destination)
                        continue
                    }
                    if value == ascii("(") { depth += 1 }
                    if value == ascii(")") {
                        depth -= 1
                        if depth == 0 { return (label, destination + 1) }
                    }
                    destination += 1
                }
                return nil
            }
            cursor += utf16CharacterLength(source, at: cursor, limit: limit)
        }
        return nil
    }

    private static func emphasisDelimiter(
        _ source: NSString,
        at location: Int,
        limit: Int
    ) -> String? {
        for delimiter in ["***", "___", "**", "__", "~~", "*", "_"] {
            let length = delimiter.utf16.count
            guard location + length <= limit,
                  source.substring(with: NSRange(location: location, length: length)) == delimiter,
                  location + length < limit,
                  !isWhitespace(source.character(at: location + length)) else {
                continue
            }
            return delimiter
        }
        return nil
    }

    private static func closingDelimiter(
        _ delimiter: String,
        source: NSString,
        after location: Int,
        limit: Int
    ) -> Int? {
        var search = NSRange(location: location, length: limit - location)
        while search.length > 0 {
            let candidate = source.range(of: delimiter, options: [], range: search)
            guard candidate.location != NSNotFound else { return nil }
            if candidate.location > location,
               !isWhitespace(source.character(at: candidate.location - 1)) {
                return candidate.location
            }
            let next = candidate.location + 1
            search = NSRange(location: next, length: limit - next)
        }
        return nil
    }

    // MARK: - Source scanners

    private struct SourceLine {
        let contentRange: NSRange
        let terminatorRange: NSRange
    }

    private struct Fence: Equatable {
        let marker: unichar
        let count: Int
    }

    private static let listPrefixRegex = try? NSRegularExpression(
        pattern: #"^[ \t]{0,12}(?:[-+*]|(?:[0-9]+|[A-Za-z]+)[.)])[ \t]+"#
    )
    private static let taskPrefixRegex = try? NSRegularExpression(
        pattern: #"^\[[ xX]\][ \t]+"#
    )
    private static let quotePrefixRegex = try? NSRegularExpression(
        pattern: #"^[ \t]*(?:>[ \t]?)+"#
    )
    private static let footnotePrefixRegex = try? NSRegularExpression(
        pattern: #"^[ \t]*\[\^[^\]]+\]:[ \t]*"#
    )

    private static func sourceLines(_ source: NSString) -> [SourceLine] {
        guard source.length > 0 else { return [] }
        var lines: [SourceLine] = []
        var lineStart = 0
        var cursor = 0
        while cursor < source.length {
            let value = source.character(at: cursor)
            guard value == 0x0A || value == 0x0D else {
                cursor += 1
                continue
            }
            let terminatorLength = value == 0x0D
                && cursor + 1 < source.length
                && source.character(at: cursor + 1) == 0x0A ? 2 : 1
            lines.append(SourceLine(
                contentRange: NSRange(location: lineStart, length: cursor - lineStart),
                terminatorRange: NSRange(location: cursor, length: terminatorLength)
            ))
            cursor += terminatorLength
            lineStart = cursor
        }
        if lineStart < source.length {
            lines.append(SourceLine(
                contentRange: NSRange(location: lineStart, length: source.length - lineStart),
                terminatorRange: NSRange(location: source.length, length: 0)
            ))
        }
        return lines
    }

    private static func headingPrefix(_ source: NSString, range: NSRange) -> NSRange? {
        var cursor = range.location
        let end = NSMaxRange(range)
        var indentation = 0
        while cursor < end, indentation < 3 {
            let value = source.character(at: cursor)
            guard value == ascii(" ") || value == ascii("\t") else { break }
            indentation += 1
            cursor += 1
        }
        let markerStart = cursor
        while cursor < end, source.character(at: cursor) == ascii("#") { cursor += 1 }
        let markerCount = cursor - markerStart
        guard (1...6).contains(markerCount),
              cursor == end || isWhitespace(source.character(at: cursor)) else {
            return nil
        }
        while cursor < end, isWhitespace(source.character(at: cursor)) { cursor += 1 }
        return NSRange(location: range.location, length: cursor - range.location)
    }

    private static func headingContentRange(_ source: NSString, range: NSRange) -> NSRange {
        var end = NSMaxRange(range)
        while end > range.location, isWhitespace(source.character(at: end - 1)) { end -= 1 }
        let hashEnd = end
        while end > range.location, source.character(at: end - 1) == ascii("#") { end -= 1 }
        if end < hashEnd,
           end > range.location,
           isWhitespace(source.character(at: end - 1)) {
            while end > range.location, isWhitespace(source.character(at: end - 1)) { end -= 1 }
        } else {
            end = hashEnd
        }
        return NSRange(location: range.location, length: max(0, end - range.location))
    }

    private static func firstMatch(
        _ regex: NSRegularExpression?,
        in source: NSString,
        range: NSRange
    ) -> NSRange? {
        guard let regex,
              let result = regex.firstMatch(in: source as String, range: range),
              result.range.location == range.location else {
            return nil
        }
        return result.range
    }

    private static func trimmingLeadingWhitespace(
        _ source: NSString,
        range: NSRange
    ) -> NSRange {
        var cursor = range.location
        let end = NSMaxRange(range)
        while cursor < end, isWhitespace(source.character(at: cursor)) { cursor += 1 }
        return NSRange(location: cursor, length: end - cursor)
    }

    private static func tableCellRanges(
        _ source: NSString,
        lineRange: NSRange
    ) -> [NSRange] {
        let end = NSMaxRange(lineRange)
        var delimiters: [Int] = []
        var cursor = lineRange.location
        while cursor < end {
            if source.character(at: cursor) == ascii("|"),
               !isEscaped(source, at: cursor, lowerBound: lineRange.location) {
                delimiters.append(cursor)
            }
            cursor += 1
        }

        var ranges: [NSRange] = []
        var start = lineRange.location
        for delimiter in delimiters {
            ranges.append(NSRange(location: start, length: delimiter - start))
            start = delimiter + 1
        }
        ranges.append(NSRange(location: start, length: end - start))

        let trimmedLine = trimmingWhitespace(source, range: lineRange)
        if trimmedLine.length > 0,
           source.character(at: trimmedLine.location) == ascii("|"),
           !ranges.isEmpty {
            ranges.removeFirst()
        }
        if trimmedLine.length > 0,
           source.character(at: NSMaxRange(trimmedLine) - 1) == ascii("|"),
           !ranges.isEmpty {
            ranges.removeLast()
        }
        return ranges.map { trimmingWhitespace(source, range: $0) }
    }

    private static func trimmingWhitespace(_ source: NSString, range: NSRange) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        while start < end, isWhitespace(source.character(at: start)) { start += 1 }
        while end > start, isWhitespace(source.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func isEscaped(
        _ source: NSString,
        at location: Int,
        lowerBound: Int
    ) -> Bool {
        var slashCount = 0
        var cursor = location
        while cursor > lowerBound, source.character(at: cursor - 1) == ascii("\\") {
            slashCount += 1
            cursor -= 1
        }
        return slashCount % 2 == 1
    }

    private static func openingFence(_ source: NSString, range: NSRange) -> Fence? {
        let trimmed = trimmingLeadingWhitespace(source, range: range)
        guard trimmed.length >= 3 else { return nil }
        let marker = source.character(at: trimmed.location)
        guard marker == ascii("`") || marker == ascii("~") else { return nil }
        let count = repeatedCount(
            source,
            at: trimmed.location,
            value: marker,
            limit: NSMaxRange(trimmed)
        )
        return count >= 3 ? Fence(marker: marker, count: count) : nil
    }

    private static func isClosingFence(
        _ source: NSString,
        range: NSRange,
        fence: Fence
    ) -> Bool {
        let trimmed = trimmingLeadingWhitespace(source, range: range)
        let count = repeatedCount(
            source,
            at: trimmed.location,
            value: fence.marker,
            limit: NSMaxRange(trimmed)
        )
        guard count >= fence.count else { return false }
        var cursor = trimmed.location + count
        while cursor < NSMaxRange(trimmed) {
            guard isWhitespace(source.character(at: cursor)) else { return false }
            cursor += 1
        }
        return true
    }

    private static func recognizedHTMLTag(
        _ source: NSString,
        at location: Int,
        limit: Int
    ) -> (range: NSRange, isBreak: Bool)? {
        let closing = source.range(
            of: ">",
            options: [],
            range: NSRange(location: location + 1, length: limit - location - 1)
        )
        guard closing.location != NSNotFound else { return nil }
        let range = NSRange(location: location, length: NSMaxRange(closing) - location)
        var contents = source.substring(with: NSRange(
            location: location + 1,
            length: closing.location - location - 1
        )).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if contents.hasPrefix("/") { contents.removeFirst() }
        if contents.hasSuffix("/") { contents.removeLast() }
        let name = contents.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        guard ["u", "sup", "sub", "mark", "br"].contains(name) else { return nil }
        return (range, name == "br")
    }

    private static func repeatedCount(
        _ source: NSString,
        at location: Int,
        value: unichar,
        limit: Int
    ) -> Int {
        var cursor = location
        while cursor < limit, source.character(at: cursor) == value { cursor += 1 }
        return cursor - location
    }

    private static func utf16CharacterLength(
        _ source: NSString,
        at location: Int,
        limit: Int
    ) -> Int {
        guard location < limit else { return 0 }
        let first = source.character(at: location)
        if (0xD800...0xDBFF).contains(first),
           location + 1 < limit,
           (0xDC00...0xDFFF).contains(source.character(at: location + 1)) {
            return 2
        }
        return 1
    }

    private static func isWhitespace(_ value: unichar) -> Bool {
        value == 0x20 || value == 0x09 || value == 0x0A || value == 0x0D
    }

    private static func ascii(_ character: Character) -> unichar {
        guard let value = character.unicodeScalars.first?.value,
              value <= UInt16.max else {
            return 0
        }
        return unichar(value)
    }
}

private struct MappedRun {
    var text = ""
    var sourceRangesByUTF16Unit: [NSRange] = []

    mutating func appendSource(_ source: NSString, range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= source.length else { return }
        text += source.substring(with: range)
        for offset in 0..<range.length {
            sourceRangesByUTF16Unit.append(NSRange(location: range.location + offset, length: 1))
        }
    }

    mutating func append(_ visible: String, sourceRange: NSRange) {
        guard !visible.isEmpty else { return }
        text += visible
        sourceRangesByUTF16Unit.append(
            contentsOf: repeatElement(sourceRange, count: visible.utf16.count)
        )
    }
}

private struct ProjectionBuilder {
    let blockID: UUID
    var text = ""
    var searchableRanges: [NSRange] = []
    var sourceRangesByUTF16Unit: [NSRange?] = []
    var tableCellsBySearchableRange: [BlockFindTableCellCoordinate?] = []

    mutating func append(
        _ run: MappedRun,
        tableCell: BlockFindTableCellCoordinate? = nil
    ) {
        guard !run.text.isEmpty,
              run.text.utf16.count == run.sourceRangesByUTF16Unit.count else {
            return
        }
        if !text.isEmpty {
            text += "\n"
            sourceRangesByUTF16Unit.append(nil)
        }
        let start = text.utf16.count
        text += run.text
        searchableRanges.append(NSRange(location: start, length: run.text.utf16.count))
        tableCellsBySearchableRange.append(tableCell)
        sourceRangesByUTF16Unit.append(contentsOf: run.sourceRangesByUTF16Unit.map(Optional.some))
    }

    var projection: BlockVisibleTextProjection {
        BlockVisibleTextProjection(
            blockID: blockID,
            text: text,
            searchableRanges: searchableRanges,
            sourceRangesByUTF16Unit: sourceRangesByUTF16Unit,
            tableCellsBySearchableRange: tableCellsBySearchableRange
        )
    }
}
