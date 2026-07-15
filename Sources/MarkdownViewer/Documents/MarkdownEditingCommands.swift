import Foundation

/// Source-editing commands handled before an active Markdown block is reparsed.
enum MarkdownEditingCommand: Equatable {
    case enter
    case shiftEnter
    case backspace
    case arrowUp
    case arrowDown
    case tab
    case shiftTab
    case bold
    case italic
    case inlineCode
}

/// A document-level transition that the block host must perform after applying
/// `replacementSource`.
enum MarkdownEditingBoundaryAction: Equatable {
    case splitBlock
    case exitList
    case exitQuote
    case mergeWithPrevious
    case navigateToPreviousBlock
    case navigateToNextBlock
}

/// The complete source and selection produced by one editing command.
///
/// `selection` is always a UTF-16 `NSRange`, matching `NSTextView`. For navigation
/// and merge intents the host resolves the final position in the destination block.
struct MarkdownEditingResult: Equatable {
    let replacementSource: String
    let selection: NSRange
    let boundaryAction: MarkdownEditingBoundaryAction?
}

enum MarkdownEditingCommandError: Error, Equatable {
    case invalidSelection(NSRange)
}

/// Pure Markdown block-source editing operations.
///
/// The engine has no AppKit state and performs no I/O. Every accepted selection is
/// checked against UTF-16 bounds and composed-character boundaries before editing.
enum MarkdownEditingCommands {
    private static let listPrefixRegex = try! NSRegularExpression(
        pattern: "^([\\t ]*)([-+*]|(?:[0-9]+|[A-Za-z]+)[.)])([\\t ]+)(?:\\[([ xX])\\]([\\t ]+))?"
    )
    private static let quotePrefixRegex = try! NSRegularExpression(
        pattern: "^([\\t ]*(?:>[\\t ]?)+)"
    )

    static func apply(
        _ command: MarkdownEditingCommand,
        to source: String,
        selection: NSRange,
        blockKind: MarkdownBlockKind
    ) throws -> MarkdownEditingResult {
        guard isValid(selection: selection, in: source) else {
            throw MarkdownEditingCommandError.invalidSelection(selection)
        }

        switch command {
        case .enter:
            return applyEnter(to: source, selection: selection, blockKind: blockKind)
        case .shiftEnter:
            return applyShiftEnter(
                to: source,
                selection: selection,
                blockKind: blockKind
            )
        case .backspace:
            return applyBackspace(to: source, selection: selection)
        case .arrowUp:
            return applyVerticalNavigation(
                upward: true,
                to: source,
                selection: selection
            )
        case .arrowDown:
            return applyVerticalNavigation(
                upward: false,
                to: source,
                selection: selection
            )
        case .tab:
            return applyTab(
                to: source,
                selection: selection,
                blockKind: blockKind
            )
        case .shiftTab:
            return applyIndent(to: source, selection: selection, outdent: true)
        case .bold:
            return wrap(source, selection: selection, marker: "**")
        case .italic:
            return wrap(source, selection: selection, marker: "*")
        case .inlineCode:
            return wrap(source, selection: selection, marker: "`")
        }
    }

    // MARK: - Enter

    private static func applyEnter(
        to source: String,
        selection: NSRange,
        blockKind: MarkdownBlockKind
    ) -> MarkdownEditingResult {
        let lineEnding = preferredLineEnding(in: source, near: selection.location)
        let collapsed = replacing(source, range: selection, with: "")
        let caret = selection.location
        let lines = sourceLines(collapsed)
        let lineIndex = indexOfLine(containing: caret, in: lines)
        let line = lines[lineIndex]
        let lineSource = (collapsed as NSString).substring(
            with: NSRange(
                location: line.start,
                length: line.contentEnd - line.start
            )
        )
        let caretInLine = caret - line.start
        let quotePrefix = parseQuotePrefix(in: lineSource)

        if blockKind == .list || blockKind == .quote,
           let listPrefix = parseListPrefix(
               in: lineSource,
               startingAt: quotePrefix?.contentStart ?? 0
           ) {
            return applyListEnter(
                to: collapsed,
                caret: caret,
                line: line,
                lineSource: lineSource,
                caretInLine: caretInLine,
                quotePrefix: quotePrefix,
                listPrefix: listPrefix,
                lineEnding: lineEnding
            )
        }

        if blockKind == .quote, let quotePrefix {
            return applyQuoteEnter(
                to: collapsed,
                caret: caret,
                line: line,
                lineSource: lineSource,
                caretInLine: caretInLine,
                prefix: quotePrefix,
                lineEnding: lineEnding
            )
        }

        if blockKind == .code || blockKind == .table {
            return inserting(
                lineEnding,
                at: caret,
                in: collapsed,
                boundaryAction: nil
            )
        }

        return inserting(
            lineEnding + lineEnding,
            at: caret,
            in: collapsed,
            boundaryAction: .splitBlock
        )
    }

    private static func applyShiftEnter(
        to source: String,
        selection: NSRange,
        blockKind: MarkdownBlockKind
    ) -> MarkdownEditingResult {
        let lineEnding = preferredLineEnding(in: source, near: selection.location)
        let collapsed = replacing(source, range: selection, with: "")
        let caret = selection.location

        if blockKind == .list || blockKind == .code || blockKind == .table {
            return inserting(
                lineEnding,
                at: caret,
                in: collapsed,
                boundaryAction: nil
            )
        }

        if blockKind == .quote {
            let lines = sourceLines(collapsed)
            let line = lines[indexOfLine(containing: caret, in: lines)]
            let lineSource = (collapsed as NSString).substring(
                with: NSRange(
                    location: line.start,
                    length: line.contentEnd - line.start
                )
            )
            let caretInLine = caret - line.start
            let sourceBeforeCaret = (lineSource as NSString).substring(
                to: caretInLine
            )
            if let prefix = parseQuotePrefix(in: sourceBeforeCaret) {
                return inserting(
                    lineEnding + prefix.source,
                    at: caret,
                    in: collapsed,
                    boundaryAction: nil
                )
            }
            return inserting(
                lineEnding,
                at: caret,
                in: collapsed,
                boundaryAction: nil
            )
        }

        return inserting(
            lineEnding + lineEnding,
            at: caret,
            in: collapsed,
            boundaryAction: .splitBlock
        )
    }

    private static func applyListEnter(
        to source: String,
        caret: Int,
        line: SourceLine,
        lineSource: String,
        caretInLine: Int,
        quotePrefix: QuotePrefix?,
        listPrefix: ListPrefix,
        lineEnding: String
    ) -> MarkdownEditingResult {
        let nsLine = lineSource as NSString
        let contentLength = nsLine.length - listPrefix.contentStart
        let content = nsLine.substring(
            with: NSRange(location: listPrefix.contentStart, length: contentLength)
        )

        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let removal = NSRange(
                location: line.start + listPrefix.start,
                length: nsLine.length - listPrefix.start
            )
            let replacement = replacing(source, range: removal, with: "")
            return MarkdownEditingResult(
                replacementSource: replacement,
                selection: NSRange(location: removal.location, length: 0),
                boundaryAction: .exitList
            )
        }

        guard caretInLine >= listPrefix.contentStart else {
            return inserting(lineEnding, at: caret, in: source, boundaryAction: nil)
        }

        let quote = quotePrefix?.source ?? ""
        let marker = listPrefix.isOrdered
            ? nextOrderedMarker(
                listPrefix.marker,
                indentation: listPrefix.indentation
            )
            : listPrefix.marker
        let task = listPrefix.isTask ? "[ ] " : ""
        let continuation = quote
            + listPrefix.indentation
            + marker
            + listPrefix.markerSpacing
            + task
        return inserting(
            lineEnding + continuation,
            at: caret,
            in: source,
            boundaryAction: nil
        )
    }

    private static func applyQuoteEnter(
        to source: String,
        caret: Int,
        line: SourceLine,
        lineSource: String,
        caretInLine: Int,
        prefix: QuotePrefix,
        lineEnding: String
    ) -> MarkdownEditingResult {
        let nsLine = lineSource as NSString
        let content = nsLine.substring(
            with: NSRange(
                location: prefix.contentStart,
                length: nsLine.length - prefix.contentStart
            )
        )
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let removal = NSRange(location: line.start, length: nsLine.length)
            let replacement = replacing(source, range: removal, with: "")
            return MarkdownEditingResult(
                replacementSource: replacement,
                selection: NSRange(location: line.start, length: 0),
                boundaryAction: .exitQuote
            )
        }

        guard caretInLine >= prefix.contentStart else {
            return inserting(lineEnding, at: caret, in: source, boundaryAction: nil)
        }
        return inserting(
            lineEnding + prefix.source,
            at: caret,
            in: source,
            boundaryAction: nil
        )
    }

    // MARK: - Backspace and navigation

    private static func applyBackspace(
        to source: String,
        selection: NSRange
    ) -> MarkdownEditingResult {
        if selection.length > 0 {
            return MarkdownEditingResult(
                replacementSource: replacing(source, range: selection, with: ""),
                selection: NSRange(location: selection.location, length: 0),
                boundaryAction: nil
            )
        }

        if selection.location == 0 {
            return MarkdownEditingResult(
                replacementSource: source,
                selection: selection,
                boundaryAction: .mergeWithPrevious
            )
        }

        let nsSource = source as NSString
        let deletion = nsSource.rangeOfComposedCharacterSequence(
            at: selection.location - 1
        )
        return MarkdownEditingResult(
            replacementSource: replacing(source, range: deletion, with: ""),
            selection: NSRange(location: deletion.location, length: 0),
            boundaryAction: nil
        )
    }

    private static func applyVerticalNavigation(
        upward: Bool,
        to source: String,
        selection: NSRange
    ) -> MarkdownEditingResult {
        guard selection.length == 0 else {
            return MarkdownEditingResult(
                replacementSource: source,
                selection: selection,
                boundaryAction: nil
            )
        }
        let lines = sourceLines(source)
        let lineIndex = indexOfLine(containing: selection.location, in: lines)
        let action: MarkdownEditingBoundaryAction?
        if upward && lineIndex == 0 {
            action = .navigateToPreviousBlock
        } else if !upward && lineIndex == lines.count - 1 {
            action = .navigateToNextBlock
        } else {
            action = nil
        }
        return MarkdownEditingResult(
            replacementSource: source,
            selection: selection,
            boundaryAction: action
        )
    }

    // MARK: - Indent and outdent

    private static func applyTab(
        to source: String,
        selection: NSRange,
        blockKind: MarkdownBlockKind
    ) -> MarkdownEditingResult {
        if selection.length == 0,
           blockKind != .list,
           blockKind != .quote {
            let lines = sourceLines(source)
            let line = lines[indexOfLine(containing: selection.location, in: lines)]
            let lineText = (source as NSString).substring(
                with: NSRange(
                    location: line.start,
                    length: line.contentEnd - line.start
                )
            )
            let leadingWhitespaceEnd = line.start + leadingWhitespaceLength(in: lineText)
            if selection.location > leadingWhitespaceEnd {
                return inserting(
                    "  ",
                    at: selection.location,
                    in: source,
                    boundaryAction: nil
                )
            }
        }

        return applyIndent(to: source, selection: selection, outdent: false)
    }

    private static func applyIndent(
        to source: String,
        selection: NSRange,
        outdent: Bool
    ) -> MarkdownEditingResult {
        let lines = sourceLines(source)
        let indices = selectedLineIndices(for: selection, in: lines)
        let edits: [SourceEdit]
        if outdent {
            edits = indices.compactMap { index in
                let line = lines[index]
                let lineText = (source as NSString).substring(
                    with: NSRange(
                        location: line.start,
                        length: line.contentEnd - line.start
                    )
                )
                let length = outdentLength(for: lineText)
                guard length > 0 else { return nil }
                return SourceEdit(
                    range: NSRange(location: line.start, length: length),
                    replacement: ""
                )
            }
        } else {
            edits = indices.map { index in
                SourceEdit(
                    range: NSRange(location: lines[index].start, length: 0),
                    replacement: "  "
                )
            }
        }

        guard !edits.isEmpty else {
            return MarkdownEditingResult(
                replacementSource: source,
                selection: selection,
                boundaryAction: nil
            )
        }

        let sorted = edits.sorted { $0.range.location < $1.range.location }
        let start = mappedOffset(
            selection.location,
            through: sorted,
            moveAfterInsertionAtSameOffset: true
        )
        let end = mappedOffset(
            selection.location + selection.length,
            through: sorted,
            moveAfterInsertionAtSameOffset: true
        )
        return MarkdownEditingResult(
            replacementSource: applying(sorted, to: source),
            selection: NSRange(location: start, length: max(0, end - start)),
            boundaryAction: nil
        )
    }

    private static func outdentLength(for line: String) -> Int {
        let nsLine = line as NSString
        guard nsLine.length > 0 else { return 0 }
        if nsLine.character(at: 0) == 9 {
            return 1
        }

        var spaces = 0
        while spaces < nsLine.length,
              nsLine.character(at: spaces) == 32 {
            spaces += 1
        }
        guard spaces > 0 else { return 0 }

        let list = parseListPrefix(in: line, startingAt: 0)
        let orderedUnit = list?.isOrdered == true
            && spaces >= 3
            && spaces.isMultiple(of: 3)
        return min(spaces, orderedUnit ? 3 : 2)
    }

    private static func leadingWhitespaceLength(in line: String) -> Int {
        let nsLine = line as NSString
        var length = 0
        while length < nsLine.length {
            let character = nsLine.character(at: length)
            guard character == 32 || character == 9 else { break }
            length += 1
        }
        return length
    }

    // MARK: - Formatting

    private static func wrap(
        _ source: String,
        selection: NSRange,
        marker: String
    ) -> MarkdownEditingResult {
        let nsSource = source as NSString
        let selected = nsSource.substring(with: selection)
        let replacement = marker + selected + marker
        let markerLength = (marker as NSString).length
        return MarkdownEditingResult(
            replacementSource: replacing(
                source,
                range: selection,
                with: replacement
            ),
            selection: NSRange(
                location: selection.location + markerLength,
                length: selection.length
            ),
            boundaryAction: nil
        )
    }

    // MARK: - List markers

    private struct ListPrefix {
        let start: Int
        let indentation: String
        let marker: String
        let markerSpacing: String
        let isTask: Bool
        let contentStart: Int

        var isOrdered: Bool {
            !["-", "+", "*"].contains(marker)
        }
    }

    private struct QuotePrefix {
        let source: String
        let contentStart: Int
    }

    private static func parseListPrefix(
        in line: String,
        startingAt offset: Int
    ) -> ListPrefix? {
        let nsLine = line as NSString
        guard offset >= 0, offset <= nsLine.length else { return nil }
        let suffix = nsLine.substring(
            with: NSRange(location: offset, length: nsLine.length - offset)
        )
        let nsSuffix = suffix as NSString
        guard let match = listPrefixRegex.firstMatch(
            in: suffix,
            range: NSRange(location: 0, length: nsSuffix.length)
        ) else {
            return nil
        }

        return ListPrefix(
            start: offset,
            indentation: nsSuffix.substring(with: match.range(at: 1)),
            marker: nsSuffix.substring(with: match.range(at: 2)),
            markerSpacing: nsSuffix.substring(with: match.range(at: 3)),
            isTask: match.range(at: 4).location != NSNotFound,
            contentStart: offset + match.range.length
        )
    }

    private static func parseQuotePrefix(in line: String) -> QuotePrefix? {
        let nsLine = line as NSString
        guard let match = quotePrefixRegex.firstMatch(
            in: line,
            range: NSRange(location: 0, length: nsLine.length)
        ) else {
            return nil
        }
        return QuotePrefix(
            source: nsLine.substring(with: match.range(at: 1)),
            contentStart: match.range.length
        )
    }

    private static func nextOrderedMarker(
        _ marker: String,
        indentation: String
    ) -> String {
        let suffix = marker.last == ")" ? ")" : "."
        let body = String(marker.dropLast()).lowercased()
        let level = orderedLevel(indentation)
        let value: Int
        if let number = Int(body) {
            value = number
        } else if level % 3 == 2,
                  body.allSatisfy({ "ivxlcdm".contains($0) }) {
            value = romanValue(body)
        } else {
            value = alphaValue(body)
        }
        let incremented = value == Int.max ? value : value + 1
        return orderedMarker(incremented, level: level) + suffix
    }

    private static func orderedLevel(_ indentation: String) -> Int {
        let width = indentation.reduce(into: 0) { result, character in
            result += character == "\t" ? 2 : 1
        }
        if width > 0, width.isMultiple(of: 3) {
            return width / 3
        }
        return max(0, width / 2)
    }

    private static func orderedMarker(_ value: Int, level: Int) -> String {
        switch level % 3 {
        case 1:
            return alphaMarker(max(1, value))
        case 2:
            return romanMarker(min(3_999, max(1, value)))
        default:
            return String(max(1, value))
        }
    }

    private static func alphaValue(_ source: String) -> Int {
        var value = 0
        for scalar in source.unicodeScalars {
            let digit = Int(scalar.value) - 96
            guard (1...26).contains(digit) else { return 1 }
            let multiplied = value.multipliedReportingOverflow(by: 26)
            guard !multiplied.overflow else { return 1 }
            let added = multiplied.partialValue.addingReportingOverflow(digit)
            guard !added.overflow else { return 1 }
            value = added.partialValue
        }
        return max(1, value)
    }

    private static func alphaMarker(_ value: Int) -> String {
        var number = value
        var result = ""
        repeat {
            number -= 1
            let scalar = UnicodeScalar(97 + number % 26)!
            result.insert(Character(scalar), at: result.startIndex)
            number /= 26
        } while number > 0
        return result
    }

    private static func romanValue(_ source: String) -> Int {
        let values: [Character: Int] = [
            "i": 1, "v": 5, "x": 10, "l": 50,
            "c": 100, "d": 500, "m": 1_000,
        ]
        let characters = Array(source)
        var result = 0
        for index in characters.indices {
            let current = values[characters[index], default: 0]
            let nextIndex = characters.index(after: index)
            let next = nextIndex < characters.endIndex
                ? values[characters[nextIndex], default: 0]
                : 0
            let contribution = current < next ? -current : current
            let added = result.addingReportingOverflow(contribution)
            if added.overflow { return 3_999 }
            result = added.partialValue
        }
        return max(1, result)
    }

    private static func romanMarker(_ value: Int) -> String {
        let values: [(Int, String)] = [
            (1_000, "m"), (900, "cm"), (500, "d"), (400, "cd"),
            (100, "c"), (90, "xc"), (50, "l"), (40, "xl"),
            (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
        ]
        var remainder = value
        var result = ""
        for (number, marker) in values {
            while remainder >= number {
                result += marker
                remainder -= number
            }
        }
        return result
    }

    // MARK: - Source and selection helpers

    private struct SourceLine {
        let start: Int
        let contentEnd: Int
        let end: Int
        let terminator: String
    }

    private struct SourceEdit {
        let range: NSRange
        let replacement: String
    }

    private static func isValid(selection: NSRange, in source: String) -> Bool {
        let length = (source as NSString).length
        guard selection.location >= 0,
              selection.length >= 0,
              selection.location <= length,
              selection.length <= length - selection.location else {
            return false
        }
        return isComposedCharacterBoundary(selection.location, in: source)
            && isComposedCharacterBoundary(
                selection.location + selection.length,
                in: source
            )
    }

    private static func isComposedCharacterBoundary(
        _ offset: Int,
        in source: String
    ) -> Bool {
        let nsSource = source as NSString
        if offset == 0 || offset == nsSource.length {
            return true
        }
        return nsSource.rangeOfComposedCharacterSequence(at: offset).location == offset
    }

    private static func replacing(
        _ source: String,
        range: NSRange,
        with replacement: String
    ) -> String {
        let mutable = NSMutableString(string: source)
        mutable.replaceCharacters(in: range, with: replacement)
        return mutable as String
    }

    private static func inserting(
        _ text: String,
        at location: Int,
        in source: String,
        boundaryAction: MarkdownEditingBoundaryAction?
    ) -> MarkdownEditingResult {
        let length = (text as NSString).length
        return MarkdownEditingResult(
            replacementSource: replacing(
                source,
                range: NSRange(location: location, length: 0),
                with: text
            ),
            selection: NSRange(location: location + length, length: 0),
            boundaryAction: boundaryAction
        )
    }

    private static func sourceLines(_ source: String) -> [SourceLine] {
        let nsSource = source as NSString
        var result: [SourceLine] = []
        var start = 0

        while start < nsSource.length {
            var cursor = start
            while cursor < nsSource.length {
                let character = nsSource.character(at: cursor)
                if character == 10 || character == 13 { break }
                cursor += 1
            }
            let contentEnd = cursor
            let terminator: String
            if cursor < nsSource.length,
               nsSource.character(at: cursor) == 13,
               cursor + 1 < nsSource.length,
               nsSource.character(at: cursor + 1) == 10 {
                cursor += 2
                terminator = "\r\n"
            } else if cursor < nsSource.length {
                terminator = nsSource.character(at: cursor) == 13 ? "\r" : "\n"
                cursor += 1
            } else {
                terminator = ""
            }
            result.append(
                SourceLine(
                    start: start,
                    contentEnd: contentEnd,
                    end: cursor,
                    terminator: terminator
                )
            )
            start = cursor
        }

        let endsWithTerminator = result.last.map {
            $0.end == nsSource.length && !$0.terminator.isEmpty
        } ?? false
        if result.isEmpty || endsWithTerminator {
            result.append(
                SourceLine(
                    start: nsSource.length,
                    contentEnd: nsSource.length,
                    end: nsSource.length,
                    terminator: ""
                )
            )
        }
        return result
    }

    private static func indexOfLine(
        containing offset: Int,
        in lines: [SourceLine]
    ) -> Int {
        if let exact = lines.lastIndex(where: { $0.start == offset }) {
            return exact
        }
        return lines.firstIndex(where: { offset >= $0.start && offset <= $0.contentEnd })
            ?? max(0, lines.count - 1)
    }

    private static func preferredLineEnding(
        in source: String,
        near offset: Int
    ) -> String {
        let lines = sourceLines(source)
        let lineIndex = indexOfLine(containing: offset, in: lines)
        if !lines[lineIndex].terminator.isEmpty {
            return lines[lineIndex].terminator
        }
        if lineIndex > 0 {
            for index in stride(from: lineIndex - 1, through: 0, by: -1)
            where !lines[index].terminator.isEmpty {
                return lines[index].terminator
            }
        }
        for index in (lineIndex + 1)..<lines.count
        where !lines[index].terminator.isEmpty {
            return lines[index].terminator
        }
        return "\n"
    }

    private static func selectedLineIndices(
        for selection: NSRange,
        in lines: [SourceLine]
    ) -> [Int] {
        let first = indexOfLine(containing: selection.location, in: lines)
        guard selection.length > 0 else { return [first] }

        let end = selection.location + selection.length
        let last: Int
        if let exact = lines.firstIndex(where: { $0.start == end }), exact > first {
            last = exact - 1
        } else {
            last = indexOfLine(containing: end, in: lines)
        }
        return Array(first...max(first, last))
    }

    private static func applying(
        _ edits: [SourceEdit],
        to source: String
    ) -> String {
        let mutable = NSMutableString(string: source)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            mutable.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return mutable as String
    }

    private static func mappedOffset(
        _ offset: Int,
        through edits: [SourceEdit],
        moveAfterInsertionAtSameOffset: Bool
    ) -> Int {
        var delta = 0
        for edit in edits {
            let replacementLength = (edit.replacement as NSString).length
            let start = edit.range.location
            let end = start + edit.range.length

            if edit.range.length == 0 {
                if start < offset
                    || start == offset && moveAfterInsertionAtSameOffset {
                    delta += replacementLength
                }
                continue
            }

            if offset < start { break }
            if offset <= end {
                return start + delta + min(offset - start, replacementLength)
            }
            delta += replacementLength - edit.range.length
        }
        return offset + delta
    }
}
